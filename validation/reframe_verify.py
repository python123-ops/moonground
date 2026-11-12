#!/usr/bin/env python3
"""Independent pixel-coordinate reframing verification for MoonGround v0.5.

NumPy matrix algebra and the existing independent Newton camera reference are
the numerical oracle. Production comparisons execute the supplied native CLI.
The optional Node suite checks the separately built JavaScript bridge.
"""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import sys
import time

import numpy as np

import verify as reference
import camera_verify as camera_reference


ROOT = Path(__file__).resolve().parents[1]
SEED = 20261115
TOLERANCE = 3.0e-8
TRANSFORMS = [
    {},
    {"scale_x": 0.5, "scale_y": 0.75, "offset_x": -40.0, "offset_y": 16.0},
    {"scale_x": 2.0, "scale_y": 0.4, "offset_x": 231.25, "offset_y": -81.5},
    {"scale_x": 0.125, "scale_y": 3.25, "offset_x": -73.2, "offset_y": 19.75},
]


def encode(value):
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), allow_nan=False)


def lines(records):
    return "\n".join(item if isinstance(item, str) else encode(item) for item in records) + "\n"


def execute(binary, mode, records=(), status=0, count=None, extra=(), payload=None):
    if payload is None:
        payload = lines(records).encode("utf-8")
    result = subprocess.run([str(binary), mode] + list(extra), input=payload,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=str(ROOT), timeout=120)
    stderr = result.stderr.decode("utf-8")
    if result.returncode != status:
        raise AssertionError("{}: exit {}, expected {}: {}".format(mode, result.returncode, status, stderr[:1600]))
    if result.stdout and not result.stdout.endswith(b"\n"):
        raise AssertionError("{} emitted an incomplete output line".format(mode))
    values = [json.loads(line) for line in result.stdout.splitlines()]
    if count is not None and len(values) != count:
        raise AssertionError("{}: {} output lines, expected {}".format(mode, len(values), count))
    if not status and stderr:
        raise AssertionError("successful request emitted stderr: " + stderr)
    return values, {"exit_code": result.returncode, "complete_output_lines": len(values),
        "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
        "stdout_bytes": len(result.stdout), "stderr": stderr.strip()}


def native(binary, mode, records, **kwargs):
    return execute(binary, mode, records, **kwargs)[0]


def reframe(binary, records, transform):
    return native(binary, "--reframe", [{"source": records[0], "transform": transform}] + records[1:])


def checkpoint(binary, records):
    return native(binary, "--checkpoint", records, count=1)[0]


def compare(actual, expected, label, errors):
    reference.compare(actual, expected, label, errors, tolerance=TOLERANCE)


def tree_close(actual, expected, errors, location="$"):
    if isinstance(expected, dict):
        if set(actual) != set(expected):
            raise AssertionError("{}: field names changed".format(location))
        for key in expected:
            tree_close(actual[key], expected[key], errors, location + "." + key)
    elif isinstance(expected, list):
        if len(actual) != len(expected):
            raise AssertionError("{}: array length changed".format(location))
        for index, value in enumerate(expected):
            tree_close(actual[index], value, errors, location + "[{}]".format(index))
    elif isinstance(expected, (int, float)) and not isinstance(expected, bool):
        if isinstance(expected, int):
            if actual != expected:
                raise AssertionError("{}: integer changed".format(location))
        else:
            # Aggregate by the final semantic field rather than frame index.
            label = re.sub(r"\[\d+\]", "[]", location)
            compare(actual, expected, label, errors)
    elif actual != expected:
        raise AssertionError("{}: {!r} != {!r}".format(location, actual, expected))


def matrix(transform):
    return np.array([[transform.get("scale_x", 1.0), 0.0, transform.get("offset_x", 0.0)],
        [0.0, transform.get("scale_y", 1.0), transform.get("offset_y", 0.0)], [0.0, 0.0, 1.0]])


def observation(identity, point, covariance=None):
    value = {"track_id": identity, "point": np.asarray(point).tolist()}
    if covariance is not None:
        value["covariance"] = list(covariance)
    return value


def frame(timestamp, observations=(), lost=(), removed=()):
    return {"timestamp_us": str(timestamp), "observations": list(observations),
        "lost": list(lost), "removed": list(removed)}


def configuration(camera=None, name="reframe-reference"):
    value = {"session_id": name, "mode": "pixel", "diagnostics": True,
        "calibration": camera_reference.calibration(),
        "motion": {"q": 0.15, "initial_velocity_std": 5.0, "gate": 9.21034,
            "min_observations": 3, "min_span_us": "200000", "max_gap_us": "500000",
            "max_tracks": 30, "max_position_std_m": 0.5, "max_velocity_std_mps": 1.5}}
    if camera is not None:
        value["camera"] = copy.deepcopy(camera)
    return value


def fixtures(rng):
    results = []
    for index, camera in enumerate([None] + camera_reference.CAMERAS):
        config = configuration(camera, "reframe-lifecycle-{}".format(index))
        samples = []
        for step in range(9):
            ideal = np.array([570.0 + step * 2.0, 320.0 + step * 0.5])
            point = camera_reference.distort_pixel(ideal, camera) if camera else ideal
            point = point + rng.normal(0, 0.04, 2)
            samples.append(frame(step * 100000, [observation(1, point,
                None if step % 3 == 0 else [4.0, 0.7, 6.0])]))
        # Keep ROI/camera rejections, a gated outlier, missing frames, explicit
        # loss/removal, and an exact gap boundary in the actual observation flow.
        samples[3]["observations"].append(observation(2, [3000, 3000]))
        ideal = [900, 550]
        point = camera_reference.distort_pixel(ideal, camera) if camera else ideal
        samples[4]["observations"] = [observation(1, point, [0.2, 0.01, 0.3])]
        samples[5] = frame(500000)
        samples[6]["lost"] = [2]
        samples += [frame(900000, removed=[1]), frame(1000000, [observation(1, [580, 325])]),
            frame(1499999), frame(1500000, [observation(1, [581, 325])]),
            frame(1600000, [observation(3, [600, 330])])]
        results.append((config, samples))
    large = configuration(name="reframe-exact-time")
    results.append((large, [frame(9007199254740993 + step * 100000,
        [observation(1, [600 + step, 330])]) for step in range(5)]))
    return results


def check_configuration(actual, original, transform, errors):
    actual = actual.get("resume", actual)
    actual = actual.get("configuration", actual)
    source = original["calibration"]
    target = actual["calibration"]
    affine = matrix(transform)
    expected = np.asarray(source["matrix"]).reshape(3, 3) @ np.linalg.inv(affine)
    found = np.asarray(target["matrix"]).reshape(3, 3)
    compare(found / np.max(np.abs(found)), expected / np.max(np.abs(expected)), "homography", errors)
    roi = (affine @ np.c_[source["roi"], np.ones(len(source["roi"]))].T).T[:, :2]
    compare(target["roi"], roi, "corrected_roi", errors)
    compare(target["max_meters_per_pixel"], source["max_meters_per_pixel"] /
        min(affine[0, 0], affine[1, 1]), "maximum_meters_per_pixel", errors)
    if target["ground_noise_floor_m"] != source["ground_noise_floor_m"]:
        raise AssertionError("ground noise standard deviation changed")
    if original.get("camera"):
        camera = original["camera"]
        k = np.array([[camera["fx"], 0, camera["cx"]], [0, camera["fy"], camera["cy"]], [0, 0, 1]])
        transformed_k = affine @ k
        compare([actual["camera"][key] for key in ("fx", "fy", "cx", "cy")],
            [transformed_k[0, 0], transformed_k[1, 1], transformed_k[0, 2], transformed_k[1, 2]],
            "camera_intrinsics", errors)
        for key in ("k1", "k2", "k3", "p1", "p2", "max_normalized_radius"):
            if actual["camera"][key] != camera[key]:
                raise AssertionError("camera distortion/radius changed: " + key)
    elif "camera" in actual:
        raise AssertionError("reframing introduced a camera")
    return actual


def geometry_checks(binary, rng):
    errors, count = {}, 0
    for camera in [None] + camera_reference.CAMERAS:
        config = configuration(camera)
        ideals = rng.uniform([400, 240], [900, 510], (48, 2))
        original = []
        for index, ideal in enumerate(ideals):
            raw = camera_reference.distort_pixel(ideal, camera) if camera else ideal
            original.append(observation(index + 1, raw, None if index % 2 == 0 else [3.0, -0.65, 7.0]))
        config["motion"]["max_tracks"] = len(original)
        for transform in TRANSFORMS:
            converted = reframe(binary, [config, frame(0, original)], transform)
            target = check_configuration(converted[0], config, transform, errors)
            transformed = converted[1]["observations"]
            if len(transformed) != len(original):
                raise AssertionError("converter dropped observations")
            affine = matrix(transform)
            diagonal = affine[:2, :2]
            for old, new in zip(original, transformed):
                compare(new["point"], (affine @ np.r_[old["point"], 1])[:2], "pixel_point", errors)
                covariance = reference.covariance_matrix(old.get("covariance", [4, 0, 4]))
                compare(new["covariance"], reference.compact_covariance(diagonal @ covariance @ diagonal.T),
                    "pixel_covariance", errors)
            request = {"calibration": target["calibration"], "points": transformed}
            # --project accepts only point/covariance, not track identity.
            request["points"] = [{key: value for key, value in item.items() if key != "track_id"} for item in transformed]
            if camera:
                request["camera"] = target["camera"]
            projections = native(binary, "--project", [request], count=1)[0]["points"]
            for old, projected in zip(original, projections):
                cov = old.get("covariance", [4, 0, 4])
                if camera:
                    point, covariance, jacobian, _ = camera_reference.project_reference(old["point"], cov, camera)
                else:
                    point, covariance, jacobian = reference.project_reference(camera_reference.HOMOGRAPHY, old["point"], cov)
                compare(projected["position_m"], point, "projected_position_m", errors)
                compare(projected["covariance"], reference.compact_covariance(covariance), "projected_covariance", errors)
                compare(projected["jacobian"], (jacobian @ np.linalg.inv(diagonal)).ravel(), "projected_jacobian", errors)
                count += 1
    return {"source_cameras": 3, "transforms_per_camera": len(TRANSFORMS),
        "projected_points": count, "independent_reference": "NumPy homogeneous matrix algebra and Brown Newton inverse",
        "maximum_absolute_errors": errors}


def continuation_checks(binary, rng):
    errors, count, resumes, observations = {}, 0, 0, 0
    statuses = set()
    for config, frames in fixtures(rng):
        records = [config] + frames
        baseline = native(binary, "--stream", records, count=len(frames))
        original_checkpoint = checkpoint(binary, records)
        for result in baseline:
            statuses.update(item["status"] for item in result["tracks"])
        for transform in TRANSFORMS:
            converted = reframe(binary, records, transform)
            check_configuration(converted[0], config, transform, errors)
            actual = native(binary, "--stream", converted, count=len(frames))
            tree_close(actual, baseline, errors)
            tree_close(checkpoint(binary, converted)["motion"], original_checkpoint["motion"], errors)
            for old, new in zip(frames, converted[1:]):
                if (old["timestamp_us"], old.get("lost", []), old.get("removed", [])) != (
                        new["timestamp_us"], new["lost"], new["removed"]):
                    raise AssertionError("converter changed time/lifecycle")
                if [item["track_id"] for item in old["observations"]] != [item["track_id"] for item in new["observations"]]:
                    raise AssertionError("converter dropped/reordered track identities")
                observations += len(new["observations"])
            for cut in (0, min(6, len(frames)), len(frames)):
                saved = checkpoint(binary, [config] + frames[:cut])
                resumed = reframe(binary, [{"resume": saved}] + frames[cut:], transform)
                if resumed[0]["resume"]["motion"] != saved["motion"]:
                    raise AssertionError("coordinate reframing changed existing metre-space checkpoint values")
                tail = native(binary, "--stream", resumed, count=len(frames) - cut)
                tree_close(tail, baseline[cut:], errors)
                tree_close(checkpoint(binary, resumed)["motion"], original_checkpoint["motion"], errors)
                resumes += 1
            count += 1
        # A nonuniform transform followed by its matrix inverse must recover
        # the original stream's measurements, including the implicit prior.
        transform = TRANSFORMS[1]
        inverse = np.linalg.inv(matrix(transform))
        back = {"scale_x": float(inverse[0, 0]), "scale_y": float(inverse[1, 1]),
            "offset_x": float(inverse[0, 2]), "offset_y": float(inverse[1, 2])}
        recovered = reframe(binary, reframe(binary, records, transform), back)
        tree_close(native(binary, "--stream", recovered), baseline, errors)
        first, second = TRANSFORMS[1:3]
        combined = matrix(second) @ matrix(first)
        params = {"scale_x": float(combined[0, 0]), "scale_y": float(combined[1, 1]),
            "offset_x": float(combined[0, 2]), "offset_y": float(combined[1, 2])}
        direct = reframe(binary, records, params)
        successive = reframe(binary, reframe(binary, records, first), second)
        tree_close(native(binary, "--stream", successive), native(binary, "--stream", direct), errors)
    if not {"rejected_projection", "rejected_innovation", "ready"}.issubset(statuses):
        raise AssertionError("fixtures failed to exercise projection rejection, NIS gate, and readiness: " + repr(statuses))
    return {"full_stream_cases": count, "resume_cut_points": resumes, "preserved_observations": observations,
        "checkpoint_motion_preserved_exactly_at_reframe": True, "observed_statuses": sorted(statuses),
        "inverse_and_composition_cases": 8, "maximum_absolute_errors": errors}


def rejection_checks(binary):
    config = configuration()
    good = frame(0, [observation(1, [600, 330])])
    header = {"source": config, "transform": TRANSFORMS[1]}
    expected = reframe(binary, [config, good], TRANSFORMS[1])
    cases = []

    def bad(name, records, prefix=(), payload=None, extra=()):
        values, result = execute(binary, "--reframe", records, status=2, count=len(prefix), payload=payload, extra=extra)
        if values != list(prefix):
            raise AssertionError(name + ": preceding complete output changed")
        cases.append({"name": name, **result})

    bad("empty_input", [], payload=b"")
    bad("unknown_header_field", [dict(header, extra=1)])
    bad("unknown_transform_field", [{"source": config, "transform": {"rotation": 1}}])
    bad("missing_source", [{"transform": {}}])
    bad("missing_transform", [{"source": config}])
    bad("ground_mode", [{"source": {"session_id": "ground", "mode": "ground"}, "transform": {}}])
    for field in ("scale_x", "scale_y"):
        for value in (0, -1, None, "1"):
            bad("invalid_{}_{}".format(field, str(value)), [{"source": config, "transform": {field: value}}])
    for field in ("offset_x", "offset_y"):
        bad("invalid_" + field, [{"source": config, "transform": {field: "0"}}])
    raw = encode(header)
    bad("duplicate_transform_key", [raw.replace('"scale_x":0.5', '"scale_x":0.5,"scale_x":1')])
    bad("duplicate_source_key", [raw.replace('"session_id":', '"mode":"pixel","session_id":')])
    bad("nonfinite_scale_token", [raw.replace('"scale_x":0.5', '"scale_x":1e999')])
    bad("nonfinite_offset_token", [raw.replace('"offset_x":-40.0', '"offset_x":1e999')])
    bad_frames = {
        "late_bad_json": "{",
        "duplicate_frame_field": encode(frame(100000)).replace('"observations":[]', '"observations":[],"observations":[]'),
        "rounded_fraction_identity": encode(frame(100000, [observation(1, [600, 330])])).replace('"track_id":1', '"track_id":1.0000000000000000001'),
        "bad_second_observation_atomic": frame(100000, [observation(1, [600, 330]), observation(2, [1e308, 1e308])]),
        "duplicate_identity": frame(100000, [observation(1, [600, 330]), observation(1, [601, 330])]),
        "overlapping_lifecycle": frame(100000, [observation(1, [600, 330])], removed=[1]),
        "nonmonotonic_time": frame(0),
        "unknown_frame_field": dict(frame(100000), extra=1),
        "invalid_covariance": frame(100000, [observation(1, [600, 330], [1, 2, 1])]),
    }
    # A separate >1 transform forces output overflow after a valid first point.
    for name, value in bad_frames.items():
        if name == "bad_second_observation_atomic":
            overflow_transform = {"scale_x": 2, "scale_y": 2}
            overflow_header = {"source": config, "transform": overflow_transform}
            prefix = reframe(binary, [config, good], overflow_transform)
            bad(name, [overflow_header, good, value], prefix)
        else:
            bad(name, [header, good, value], expected)
    bad("invalid_utf8_after_complete_frame", [], expected,
        payload=lines([header, good]).encode() + b"\xff\n")
    bad("blank_line_after_complete_frame", [header, good, ""], expected)
    oversized = copy.deepcopy(header)
    oversized["source"]["session_id"] = "x" * 1048576
    bad("configuration_over_payload_limit", [oversized], extra=["--max-line-bytes", "16777216"])
    late = encode(frame(100000)) + " " * 1048576
    bad("frame_payload_limit", [header, good, late], expected, extra=["--max-line-bytes", "16777216"])
    bad("default_physical_line_limit", [encode(header) + " " * 1048576])
    # Bounded physical transport counts bytes before decoding, including UTF-8.
    byte_payload = lines([header, good]).encode()
    first_size = len(encode(header).encode())
    exact, _ = execute(binary, "--reframe", [], payload=byte_payload,
        extra=["--max-line-bytes", str(first_size)])
    if exact != expected:
        raise AssertionError("exact physical line boundary changed results")
    bad("one_byte_below_header_limit", [header, good], extra=["--max-line-bytes", str(first_size - 1)])
    eof_records = [header, good, frame(100000)]
    expected_eof = native(binary, "--reframe", eof_records)
    for newline in (b"\n", b"\r\n"):
        payload = newline.join(encode(item).encode() for item in eof_records)
        actual, _ = execute(binary, "--reframe", [], payload=payload)
        if actual != expected_eof:
            raise AssertionError("CRLF or missing final newline changed reframing")
    return {"rejected_cases": len(cases), "cases": cases,
        "complete_prefix_preserved": True, "crlf_and_unterminated_eof": "passed",
        "exact_physical_line_boundary_bytes": first_size}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/reframe.test.mjs"]
    environment = dict(os.environ, MOONGROUND_CLI=str(binary))
    version = subprocess.run(["node", "--version"], stdout=subprocess.PIPE,
        text=True, encoding="utf-8", check=True, timeout=15).stdout.strip()
    run = subprocess.run(command, cwd=str(ROOT), env=environment, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=180)
    if run.returncode:
        raise AssertionError("Node reframing verification failed:\n" + run.stdout[-10000:] + run.stderr[-2000:])
    summary = {}
    for line in run.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", line)
        if match:
            summary[match.group(1)] = int(match.group(2))
    if not summary.get("tests") or summary.get("pass") != summary["tests"] or summary.get("fail"):
        raise AssertionError("Node test summary is incomplete")
    return {"status": "passed", "node": version, "command": " ".join(command),
        "binary_environment": {"MOONGROUND_CLI": str(binary)}, "summary": summary,
        "test_script_sha256": hashlib.sha256((ROOT / "web/reframe.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(run.stdout.encode()).hexdigest(), "stderr": run.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/reframe-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "seed": SEED, "tolerance": TOLERANCE,
        "command": " ".join(shlex.quote(value) for value in [sys.executable] + sys.argv),
        "python": platform.python_version(), "numpy": np.__version__, "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "camera_reference_sha256": hashlib.sha256(Path(camera_reference.__file__).read_bytes()).hexdigest(),
        "v01_reference_sha256": hashlib.sha256(Path(reference.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    rng = np.random.default_rng(SEED)
    result["independent_geometry"] = geometry_checks(binary, rng)
    result["measurement_continuation"] = continuation_checks(binary, rng)
    result["strict_transport"] = rejection_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    result["status"] = "passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(encode({"status": "passed", "output": str(args.output),
        "projected_points": result["independent_geometry"]["projected_points"],
        "resume_cut_points": result["measurement_continuation"]["resume_cut_points"],
        "strict_rejections": result["strict_transport"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
