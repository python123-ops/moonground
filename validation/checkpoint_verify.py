#!/usr/bin/env python3
"""Verify complete MoonGround session continuation through the native CLI.

This entry point checks process restarts, strict checkpoint rejection, bounded
transport, and a hand-authored state against the independent NumPy reference.
Run web/checkpoint.test.mjs separately for native/JavaScript interchange.
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
SEED = 20261113
MAX_INT64 = 9223372036854775807
TOLERANCE = 2.0e-8


def encode(value):
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), allow_nan=False)


def run(binary, mode, records, expected_exit=0, expected_lines=None, line_limit=None):
    command = [str(binary), mode]
    if line_limit is not None:
        command += ["--max-line-bytes", str(line_limit)]
    payload = "\n".join(item if isinstance(item, str) else encode(item) for item in records) + "\n"
    # Keep the physical protocol bytes exact on Windows too: text-mode stdin
    # would translate LF into CRLF and add one unit at the size boundary.
    process = subprocess.run(command, input=payload.encode("utf-8"),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             cwd=str(ROOT), timeout=120)
    stdout = process.stdout.decode("utf-8")
    stderr = process.stderr.decode("utf-8")
    if process.returncode != expected_exit:
        raise AssertionError("{}: exit {}, expected {}: {}".format(
            mode, process.returncode, expected_exit, stderr[:1600]))
    if stdout and not stdout.endswith("\n"):
        raise AssertionError("native output ended with an incomplete JSON line")
    if expected_exit and mode == "--checkpoint" and stdout:
        raise AssertionError("a failed checkpoint command emitted a partial checkpoint")
    if not expected_exit and stderr:
        raise AssertionError("successful request emitted stderr: " + stderr[:1600])
    outputs = [json.loads(line) for line in stdout.splitlines()]
    if expected_lines is not None and len(outputs) != expected_lines:
        raise AssertionError("{} returned {} lines instead of {}".format(mode, len(outputs), expected_lines))
    return outputs, {"exit_code": process.returncode,
                     "stdout_bytes": len(process.stdout),
                     "stdout_sha256": hashlib.sha256(process.stdout).hexdigest(),
                     "stderr": stderr.strip()}


def checkpoint(binary, records, **kwargs):
    return run(binary, "--checkpoint", records, expected_lines=1, **kwargs)[0][0]


def observation(identity, point, covariance=(0.01, 0.002, 0.02)):
    return {"track_id": identity, "point": list(point), "covariance": list(covariance)}


def frame(timestamp, observations=(), lost=(), removed=()):
    return {"timestamp_us": str(timestamp), "observations": list(observations),
            "lost": list(lost), "removed": list(removed)}


def config(session="checkpoint-native", **overrides):
    value = {"session_id": session, "mode": "ground", "diagnostics": True,
             "motion": {"max_gap_us": "500000", "min_observations": 3,
                        "min_span_us": "300000", "q": 0.15,
                        "initial_velocity_std": 5.0, "gate": 9.21034,
                        "max_tracks": 10, "max_position_std_m": 0.15,
                        "max_velocity_std_mps": 0.4}}
    value.update(overrides)
    return value


def fixtures(rng):
    ground = [
        frame(0, [observation(1, [0.0, 0.0]), observation(2, [2.0, 1.0])]),
        frame(100000, [observation(1, [0.1, 0.0])]),
        frame(300000, [observation(1, [0.3, 0.0]), observation(2, [2.0, 1.1])]),
        frame(400000, [observation(1, [100.0, 100.0])]),
        frame(499999),
        frame(500000, [observation(1, [0.5, 0.0])], lost=[2]),
        frame(600000, removed=[1]),
        frame(700000, [observation(1, [0.7, 0.0])]),
        frame(1199999),
        frame(1200000, [observation(1, [1.2, 0.0])]),
        frame(1300000, [observation(3, [5.0, 2.0])]),
    ]
    camera = camera_reference.CAMERAS[0]
    raw_config = config("checkpoint-camera", mode="pixel", camera=camera,
                        calibration=camera_reference.calibration())
    raw = []
    covariance = np.array([[4.0, 0.7], [0.7, 6.0]])
    for index in range(10):
        ideal = [580.0 + index * 1.2, 330.0 + index * 0.3]
        pixel = camera_reference.distort_pixel(ideal, camera)
        pixel += rng.multivariate_normal([0, 0], covariance)
        if index == 5:
            pixel = np.array([3000.0, 3000.0])  # Rejected projection, no filter mutation.
        raw.append(frame(index * 100000, [observation(1, pixel,
            reference.compact_covariance(covariance))]))
    big = 9007199254740993
    large_time = [frame(big + offset, [observation(1, [offset / 1e6, 1.0])])
                  for offset in (0, 100000, 300000, 400000)]
    default = {"session_id": "checkpoint-defaults", "mode": "ground", "diagnostics": True}
    extreme_config = config("checkpoint-extreme-scale")
    extreme_config["motion"].update(q=0, initial_velocity_std=1e106, max_gap_us="2000000")
    extreme = [frame(500000, [observation(1, [0, 0],
        [1e-32, -9.999999999990001e-33, 1e-32])]),
        frame(500001, [observation(1, [0, 0], [1e186, 0, 1e186])])]
    return [("identity_path_lifecycle", config(), ground),
            ("raw_camera_projection_rejection", raw_config, raw),
            ("exact_int64_time", config("checkpoint-big-time"), large_time),
            ("effective_defaults", default, ground[:4]),
            ("extreme_scale_failure_retains_restorable_state", extreme_config, extreme)]


def validate_export(value):
    if set(value) != {"format", "checkpoint_version", "configuration", "motion"}:
        raise AssertionError("checkpoint envelope fields differ from the locked wire format")
    if value["format"] != "moonground.session" or value["checkpoint_version"] != "1":
        raise AssertionError("checkpoint format/version missing")
    state = value["motion"]
    if set(state) != {"last_timestamp_us", "next_segment_id", "tracks"}:
        raise AssertionError("motion checkpoint has unexpected fields")
    next_segment = int(state["next_segment_id"])
    if str(next_segment) != state["next_segment_id"] or next_segment < 1:
        raise AssertionError("segment counter is not a positive canonical Int64 string")
    previous_id = 0
    for track in state["tracks"]:
        if track["track_id"] <= previous_id:
            raise AssertionError("exported tracks are not sorted and unique")
        previous_id = track["track_id"]
        if np.asarray(track["state"]).shape != (4,) or np.asarray(track["covariance"]).shape != (16,):
            raise AssertionError("state/covariance checkpoint shape is wrong")
        p = np.asarray(track["covariance"]).reshape(4, 4)
        if not np.isfinite(p).all() or not np.allclose(p, p.T, rtol=1e-12, atol=1e-15):
            raise AssertionError("checkpoint covariance is non-finite or asymmetric")
        if np.linalg.eigvalsh(p / np.max(np.abs(p)))[0] < -1e-9:
            raise AssertionError("checkpoint covariance is not positive semidefinite")
        if track["last_filtered"] != track["state"][:2]:
            raise AssertionError("last filtered point is detached from the saved state")
        if int(track["segment_id"]) >= next_segment:
            raise AssertionError("restored segment counter would reuse an identity")


def restart_checks(binary, rng):
    cases = []
    restarts = 0
    for name, configuration, frames in fixtures(rng):
        expected, _ = run(binary, "--stream", [configuration] + frames, expected_lines=len(frames))
        final = checkpoint(binary, [configuration] + frames)
        validate_export(final)
        observed_statuses = sorted({track["status"] for item in expected for track in item["tracks"]})
        for cut in range(len(frames) + 1):
            saved = checkpoint(binary, [configuration] + frames[:cut])
            validate_export(saved)
            resumed, _ = run(binary, "--stream", [{"resume": saved}] + frames[cut:],
                             expected_lines=len(frames) - cut)
            if resumed != expected[cut:]:
                raise AssertionError("{}: output changed after restart at {}".format(name, cut))
            continued = checkpoint(binary, [{"resume": saved}] + frames[cut:])
            if continued != final:
                raise AssertionError("{}: final state changed after restart at {}".format(name, cut))
            restarts += 1
        if name == "effective_defaults":
            motion = final["configuration"]["motion"]
            if motion["gate"] != 9.21034 or motion["q"] != 1.0:
                raise AssertionError("wire defaults were not explicitly preserved")
        if name == "extreme_scale_failure_retains_restorable_state":
            rejected = expected[-1]["tracks"][0]
            if rejected["status"] != "numerical_failure" or rejected["accepted_count"] != 1:
                raise AssertionError("extreme-scale invalid candidate was committed")
            if rejected["last_accepted_timestamp_us"] != "500000":
                raise AssertionError("numerical failure changed the accepted-observation clock")
        cases.append({"name": name, "frames": len(frames), "cut_points": len(frames) + 1,
                      "statuses": observed_statuses,
                      "same_runtime_outputs_and_final_state_exact": True})
    return {"restart_points": restarts, "cases": cases}


def authored_checkpoint():
    # Neither this state nor its covariance originates in MoonBit output.
    a = np.array([[0.1, 0.0, 0.0, 0.0], [0.02, 0.14, 0.0, 0.0],
                  [0.03, 0.01, 0.25, 0.0], [0.0, 0.04, 0.02, 0.3]])
    p = a @ a.T
    return {"format": "moonground.session", "checkpoint_version": "1",
            "configuration": config("checkpoint-authored"),
            "motion": {"last_timestamp_us": "1400000", "next_segment_id": "8",
                "tracks": [{"track_id": 1, "segment_id": "7",
                    "first_timestamp_us": "1000000", "last_timestamp_us": "1300000",
                    "accepted_count": 4, "state": [1.0, 2.0, 0.3, -0.2],
                    "covariance": p.ravel().tolist(), "first_filtered": [0.5, 2.5],
                    "last_filtered": [1.0, 2.0], "observed_path_length_m": 1.5}]}}


def independent_reference_checks(binary):
    saved = authored_checkpoint()
    track = saved["motion"]["tracks"][0]
    oracle = reference.KalmanReference(track["state"][:2], [0.01, 0, 0.02],
        track["last_timestamp_us"], q=0.15)
    oracle.state = np.asarray(track["state"])
    oracle.covariance = np.asarray(track["covariance"]).reshape(4, 4)
    oracle.first_timestamp_us = int(track["first_timestamp_us"])
    oracle.accepted_count = track["accepted_count"]
    oracle.first_position = np.asarray(track["first_filtered"])
    oracle.last_observed = np.asarray(track["last_filtered"])
    oracle.path_length = track["observed_path_length_m"]
    item = observation(1, [1.07, 1.95])
    if not oracle.update(item["point"], item["covariance"], "1500000")[0]:
        raise AssertionError("authored reference fixture rejected its valid observation")
    actual = run(binary, "--stream", [{"resume": saved}, frame(1500000, [item])], expected_lines=1)[0][0]["tracks"][0]
    errors = {}
    for key, expected in (("filter_state", oracle.state),
                          ("filter_covariance", oracle.covariance.ravel()),
                          ("observed_path_length_m", oracle.path_length),
                          ("net_displacement_m", np.linalg.norm(oracle.state[:2] - oracle.first_position))):
        reference.compare(actual[key], expected, key, errors, tolerance=TOLERANCE)
    if actual["segment_id"] != "7" or actual["accepted_count"] != 5:
        raise AssertionError("authored checkpoint lost segment identity or accepted count")
    return {"authored_without_implementation_output": True, "seed": SEED,
            "maximum_absolute_errors": errors,
            "interpretation": "Joseph-form NumPy update from a manually authored full session state, including historical path anchors."}


def counter_and_time_checks(binary):
    saved = authored_checkpoint()
    saved["motion"]["next_segment_id"] = str(MAX_INT64 - 1)
    next_frame = frame(1500000, [observation(2, [3, 4])], removed=[1])
    result = run(binary, "--stream", [{"resume": saved}, next_frame], expected_lines=1)[0][0]
    if result["tracks"][0]["segment_id"] != str(MAX_INT64 - 1):
        raise AssertionError("large Int64 segment counter lost precision")
    continued = checkpoint(binary, [{"resume": saved}, next_frame])
    if continued["motion"]["next_segment_id"] != str(MAX_INT64):
        raise AssertionError("next segment counter did not advance exactly")
    _, exhausted = run(binary, "--checkpoint", [{"resume": continued},
        frame(1600000, [observation(3, [1, 2])])], expected_exit=2, expected_lines=0)
    same_time = frame(1400000, [observation(1, [1, 2])])
    _, old_time = run(binary, "--checkpoint", [{"resume": authored_checkpoint()}, same_time],
                      expected_exit=2, expected_lines=0)
    return {"next_segment_near_int64_limit": continued["motion"]["next_segment_id"],
            "counter_exhaustion_rejected_atomically": exhausted,
            "global_frame_time_preserved": old_time}


def corruption_checks(binary):
    original = authored_checkpoint()
    mutations = []
    def altered(name, transform):
        item = copy.deepcopy(original)
        transform(item)
        mutations.append((name, item))
    def track(item):
        return item["motion"]["tracks"][0]
    altered("unknown_checkpoint_version", lambda x: x.update(checkpoint_version="2"))
    altered("numeric_checkpoint_version", lambda x: x.update(checkpoint_version=1))
    altered("wrong_format", lambda x: x.update(format="kalman.generic"))
    altered("unknown_envelope_field", lambda x: x.update(ignored=True))
    altered("unknown_motion_field", lambda x: x["motion"].update(ignored=True))
    altered("unknown_track_field", lambda x: track(x).update(ignored=True))
    altered("duplicate_identity", lambda x: x["motion"]["tracks"].append(copy.deepcopy(track(x))))
    altered("duplicate_segment", lambda x: x["motion"]["tracks"].append(dict(copy.deepcopy(track(x)), track_id=2)))
    altered("counter_not_after_segment", lambda x: x["motion"].update(next_segment_id="7"))
    altered("counter_overflow", lambda x: x["motion"].update(next_segment_id=str(MAX_INT64 + 1)))
    altered("noncanonical_timestamp", lambda x: track(x).update(last_timestamp_us="01300000"))
    altered("numeric_timestamp", lambda x: track(x).update(last_timestamp_us=1300000))
    altered("first_time_after_last", lambda x: track(x).update(first_timestamp_us="1350000"))
    altered("track_time_after_global", lambda x: track(x).update(last_timestamp_us="1450000"))
    altered("expired_track", lambda x: x["motion"].update(last_timestamp_us="1800000"))
    altered("null_global_with_tracks", lambda x: x["motion"].update(last_timestamp_us=None))
    altered("wrong_state_shape", lambda x: track(x).update(state=[1, 2, 0]))
    altered("wrong_covariance_shape", lambda x: track(x).update(covariance=[1] * 15))
    altered("asymmetric_covariance", lambda x: track(x)["covariance"].__setitem__(1, 0.5))
    altered("indefinite_covariance", lambda x: track(x)["covariance"].__setitem__(0, -1))
    altered("zero_covariance", lambda x: track(x).update(covariance=[0] * 16))
    altered("path_negative", lambda x: track(x).update(observed_path_length_m=-1))
    altered("path_less_than_displacement", lambda x: track(x).update(observed_path_length_m=0.1))
    altered("detached_last_filtered", lambda x: track(x).update(last_filtered=[1.1, 2]))
    altered("accepted_count_zero", lambda x: track(x).update(accepted_count=0))
    altered("accepted_count_overflow", lambda x: track(x).update(accepted_count=2147483648))
    altered("inconsistent_single_accept", lambda x: track(x).update(accepted_count=1))
    altered("invalid_configuration_gate", lambda x: x["configuration"]["motion"].update(gate=0))
    altered("missing_effective_gate", lambda x: x["configuration"]["motion"].pop("gate"))
    altered("missing_effective_q", lambda x: x["configuration"]["motion"].pop("q"))
    altered("missing_effective_diagnostics", lambda x: x["configuration"].pop("diagnostics"))
    altered("ground_camera_conflict", lambda x: x["configuration"].update(camera=camera_reference.CAMERAS[0]))
    altered("missing_configuration", lambda x: x.pop("configuration"))
    results = []
    for name, item in mutations:
        _, result = run(binary, "--checkpoint", [{"resume": item}], expected_exit=2, expected_lines=0)
        results.append({"name": name, **result})
    valid = encode(original)
    sources = [("duplicate_json_key", '{"resume":' + valid[:-1] + ',"format":"moonground.session"}}'),
               ("truncated_checkpoint", '{"resume":' + valid[:-2]),
               ("nonfinite_covariance", encode({"resume": original}).replace('0.010000000000000002', '1e999', 1))]
    if "1e999" not in sources[-1][1]:
        sources[-1] = ("nonfinite_covariance", encode({"resume": original}).replace('"state":[1.0', '"state":[1e999', 1))
    for name, source in sources:
        _, result = run(binary, "--checkpoint", [source], expected_exit=2, expected_lines=0)
        results.append({"name": name, **result})
    _, extra = run(binary, "--checkpoint", [{"resume": original, "diagnostics": False}],
                   expected_exit=2, expected_lines=0)
    results.append({"name": "resume_configuration_override", **extra})
    # A valid prefix must not escape as a checkpoint if a later frame is bad.
    _, failed_prefix = run(binary, "--checkpoint", [config(), frame(0, [observation(1, [0, 0])]),
        {"timestamp_us": "100000", "observations": [], "typo": True}],
        expected_exit=2, expected_lines=0)
    results.append({"name": "no_checkpoint_after_invalid_frame", **failed_prefix})
    return {"rejected_cases": len(results), "cases": results}


def integer_token_checks(binary):
    saved = authored_checkpoint()
    raw = encode({"resume": saved})
    def token(source, name, replacement):
        pattern = r'("' + re.escape(name) + r'":)(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)'
        result, count = re.subn(pattern, lambda match: match.group(1) + replacement, source, count=1)
        if count != 1:
            raise AssertionError("integer token fixture is missing " + name)
        return result
    rejected = []
    for field, number in (("accepted_count", "4"), ("track_id", "1"), ("max_tracks", "10")):
        fractional = number + ".0000000000000000001"
        _, result = run(binary, "--checkpoint", [token(raw, field, fractional)],
                        expected_exit=2, expected_lines=0)
        rejected.append({"name": "checkpoint_" + field + "_rounded_fraction", "token": fractional, **result})
    bad_frame = token(encode(frame(0, [observation(1, [0, 0])])), "track_id", "1.0000000000000000001")
    _, result = run(binary, "--checkpoint", [config(), bad_frame], expected_exit=2, expected_lines=0)
    rejected.append({"name": "ordinary_frame_rounded_track_identity", **result})
    bad_config = token(encode(config()), "max_tracks", "10.0000000000000000001")
    _, result = run(binary, "--checkpoint", [bad_config], expected_exit=2, expected_lines=0)
    rejected.append({"name": "ordinary_configuration_rounded_max_tracks", **result})
    accepted = []
    forms = {"accepted_count": ["4.0", "4e0", "40e-1"],
             "track_id": ["1.0", "1e0", "10e-1"],
             "max_tracks": ["10.0", "1e1", "100e-1"]}
    for field, representations in forms.items():
        for representation in representations:
            actual = checkpoint(binary, [token(raw, field, representation)])
            if actual["motion"]["tracks"][0]["accepted_count"] != 4:
                raise AssertionError("mathematically integral token changed accepted_count")
            if actual["motion"]["tracks"][0]["track_id"] != 1:
                raise AssertionError("mathematically integral token changed track identity")
            if actual["configuration"]["motion"]["max_tracks"] != 10:
                raise AssertionError("mathematically integral token changed target capacity")
            accepted.append({"field": field, "token": representation})
    return {"rounded_fraction_rejections": rejected,
            "mathematical_integer_forms_accepted": accepted,
            "validation_uses_raw_numeric_tokens": True}


def transport_checks(binary):
    count = 3000
    configuration = config("checkpoint-large")
    configuration["motion"]["max_tracks"] = count
    frames = [frame(index * 100000, [observation(identity,
        [identity * 0.001 + index * 0.03, identity * 0.002 - index * 0.01],
        [0.013, 0.0013, 0.028]) for identity in range(1, count + 1)]) for index in range(3)]
    saved = checkpoint(binary, [configuration] + frames, line_limit=16777216)
    source = encode({"resume": saved})
    size = len(source.encode("utf-8"))
    if size <= 1048576 or size >= 8 * 1024 * 1024:
        raise AssertionError("large resume fixture does not exercise the intended transport range: {}".format(size))
    _, default_limit = run(binary, "--checkpoint", [source], expected_exit=2, expected_lines=0)
    restored = checkpoint(binary, [source], line_limit=16777216)
    if restored != saved:
        raise AssertionError("large checkpoint changed after explicit-cap transport")
    exact_edge = checkpoint(binary, [config("checkpoint-text-edge")])
    exact_edge["configuration"]["session_id"] = ""
    payload_limit = 8 * 1024 * 1024
    exact_edge["configuration"]["session_id"] = "x" * (payload_limit - len(encode(exact_edge)))
    raw_edge = encode(exact_edge)
    if len(raw_edge) != payload_limit:
        raise AssertionError("checkpoint payload is not exactly on its UTF-16 text boundary")
    edge_bootstrap = '{"resume":' + raw_edge + '}'
    exact_restored = checkpoint(binary, [edge_bootstrap], line_limit=16777216)
    if exact_restored != exact_edge:
        raise AssertionError("a valid 8 Mi checkpoint changed or could not resume through its wrapper")
    exact_edge["configuration"]["session_id"] += "x"
    _, payload_overflow = run(binary, "--checkpoint", ['{"resume":' + encode(exact_edge) + '}'],
        expected_exit=2, expected_lines=0, line_limit=16777216)
    oversized = copy.deepcopy(authored_checkpoint())
    oversized["motion"]["tracks"] = [dict(oversized["motion"]["tracks"][0],
        track_id=index + 1, segment_id=str(index + 1)) for index in range(10001)]
    oversized["motion"]["next_segment_id"] = "10002"
    oversized["configuration"]["motion"]["max_tracks"] = 10001
    _, record_limit = run(binary, "--checkpoint", [{"resume": oversized}], expected_exit=2,
                          expected_lines=0, line_limit=16777216)
    over_text = encode({"resume": authored_checkpoint()})
    over_text += " " * (8 * 1024 * 1024 + 12 - len(over_text))
    _, text_limit = run(binary, "--checkpoint", [over_text], expected_exit=2,
                        expected_lines=0, line_limit=16777216)
    return {"tracks": count, "resume_line_utf8_bytes": size,
            "explicit_cli_line_limit_bytes": 16777216,
            "large_roundtrip_exact": True, "default_cli_limit_rejection": default_limit,
            "track_record_limit_rejection": record_limit,
            "bootstrap_text_limit_rejection": text_limit,
            "exact_checkpoint_payload_boundary": {
                "payload_utf16_units": len(raw_edge),
                "bootstrap_utf16_units": len(edge_bootstrap),
                "roundtrip_exact": True, "one_unit_payload_overflow_rejection": payload_overflow},
            "checkpoint_sha256": hashlib.sha256(encode(saved).encode("utf-8")).hexdigest()}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/checkpoint.test.mjs"]
    environment = dict(os.environ, MOONGROUND_CLI=str(binary))
    version = subprocess.run(["node", "--version"], stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, encoding="utf-8", check=True, timeout=15).stdout.strip()
    completed = subprocess.run(command, cwd=str(ROOT), env=environment,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=180)
    if completed.returncode:
        raise AssertionError("web checkpoint verification failed:\n" + completed.stdout[-10000:]
                             + completed.stderr[-2000:])
    summary = {}
    directions = None
    for line in completed.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", line)
        if match:
            summary[match.group(1)] = int(match.group(2))
        if line.startswith('# {"cut_points":'):
            directions = json.loads(line[2:])
    if not summary.get("tests") or summary.get("pass") != summary["tests"] or summary.get("fail") != 0:
        raise AssertionError("Node test summary is missing or incomplete: " + completed.stdout[-3000:])
    if directions is None or set(directions["directions"]) != {
            "native-native", "native-javascript", "javascript-native", "javascript-javascript"}:
        raise AssertionError("Node checkpoint run did not report all four runtime directions")
    return {"status": "passed", "node": version, "command": " ".join(command),
            "binary_environment": {"MOONGROUND_CLI": str(binary)},
            "test_script_sha256": hashlib.sha256((ROOT / "web/checkpoint.test.mjs").read_bytes()).hexdigest(),
            "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
            "summary": summary, "cross_runtime": directions,
            "stdout_sha256": hashlib.sha256(completed.stdout.encode("utf-8")).hexdigest(),
            "stderr": completed.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true", help="also run the four-direction Node checkpoint suite")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/checkpoint-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "seed": SEED, "tolerance": TOLERANCE,
              "command": " ".join(shlex.quote(value) for value in [sys.executable] + sys.argv),
              "python": platform.python_version(), "numpy": np.__version__,
              "toolchain": reference.toolchain_version(),
              "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "v01_reference_sha256": hashlib.sha256(Path(reference.__file__).read_bytes()).hexdigest(),
              "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["native_restarts"] = restart_checks(binary, np.random.default_rng(SEED))
    result["independent_authored_state"] = independent_reference_checks(binary)
    result["exact_counters_and_time"] = counter_and_time_checks(binary)
    result["strict_rejections"] = corruption_checks(binary)
    result["integer_tokens"] = integer_token_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    result["status"] = "passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(encode({"status": "passed", "output": str(args.output),
                  "native_restart_points": result["native_restarts"]["restart_points"],
                  "strict_rejections": result["strict_rejections"]["rejected_cases"],
                  "large_resume_bytes": result["bounded_transport"]["resume_line_utf8_bytes"]}))


if __name__ == "__main__":
    main()
