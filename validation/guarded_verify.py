#!/usr/bin/env python3
"""Check explicit health admission against the existing independent CLI paths.

The host reference stages old --health and --analyze checkpoints separately.
It interrupts motion through a public empty frame, never by calling the new
guard implementation. Existing NumPy landmark and gate references remain the
numerical oracle; timestamps and durable counters remain exact Python integers.
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

import analysis_verify as analysis_reference
import camera_verify as camera_reference
import checkpoint_verify as checkpoints
import gates_verify as gates
import health_verify as health_reference
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
encode = gates.encode
lines = gates.lines


def run(binary, mode, records=(), status=0, count=None, payload=None, extra=()):
    return gates.execute(binary, mode, records, status=status, count=count, payload=payload, extra=extra)


def native(binary, mode, records=(), **kwargs):
    return run(binary, mode, records, **kwargs)[0]


def source(analysis, health):
    return {"analysis": analysis if isinstance(analysis, str) else encode(analysis),
        "health": health if isinstance(health, str) else encode(health)}


def wrapper(measurement, health):
    return {"measurement": measurement if isinstance(measurement, str) else encode(measurement),
        "health": health if isinstance(health, str) else encode(health)}


def combined(analysis, health):
    return {"format": "moonground.guarded", "checkpoint_version": "1", "analysis": analysis, "health": health}


def fixture(camera=None, name="guarded-reference", start=0, immediate=False):
    health, ideals = health_reference.configuration(name + "-landmarks", camera)
    if immediate:
        health["health"].update(min_observations=1, confirmation_us="0")
    measurement = {"session_id": name, "mode": "pixel", "diagnostics": True,
        "calibration": copy.deepcopy(health["calibration"]),
        "motion": {"max_tracks": 16, "max_gap_us": "500000", "min_observations": 2,
            "min_span_us": "100000", "gate": 1e9, "initial_velocity_std": 10, "q": 5}}
    if camera is not None:
        measurement["camera"] = copy.deepcopy(camera)
    if camera is None:
        counting = gates.configuration(name=name, gates=[gates.gate("horizontal", (-100, 2), (100, 2), 0.005)])
    else:
        center = health["landmarks"][0]["ground_m"][1]
        counting = gates.configuration(name=name, gates=[gates.gate("horizontal", (-100, center), (100, center), 0.005)])
    counting["max_tracks"] = 16
    analysis = analysis_reference.source(measurement, counting)
    times = [0, 100000, 300000, 400000, 500000, 600000, 700000, 900000,
        1000000, 1100000, 1200000, 1400000, 1500000, 1600000, 2100000, 2200000, 2400000, 2500000]
    records = []
    for index, offset in enumerate(times):
        landmark_offset = (4, 0) if camera is None else (12, -8)
        points = health_reference.observations(health, ideals, landmark_offset if 5 <= index <= 7 else (0, 0))
        if index == 8:
            points = []
        # Keep observation order different from output/suppression order.
        coordinate = [8, 8 if index % 2 == 0 else 24] if camera is None else [430, 235 if index % 2 == 0 else 275]
        objects = []
        for identity in [2, 1]:
            pixel = np.asarray(coordinate, dtype=float) + [identity - 1, 0]
            if camera is not None:
                pixel = camera_reference.distort_pixel(pixel, camera)
            objects.append(checkpoints.observation(identity, pixel, [0.04, 0.008, 0.09]))
        if index == 0:
            objects[0]["point"] = [3000, 3000]  # Valid structure, ignored while blocked.
        if index == 4:
            objects = []  # Filters remain active despite an empty output frame.
        lost = []
        if index == 12:
            objects[0]["point"] = [3000, 3000]  # Local projection rejection while admitted.
        if index == 13:
            objects = [item for item in objects if item["track_id"] != 2]
            lost = [2]
        timestamp = start + offset
        records.append(wrapper(checkpoints.frame(timestamp, objects, lost=lost), health_reference.frame(timestamp, points)))
    return source(analysis, health), health, records


def fixtures():
    values = [("healthy_drift_missing_gap_recovery",) + fixture()]
    for index, camera in enumerate(camera_reference.CAMERAS):
        values.append(("brown_{}".format(index),) + fixture(camera, "guarded-brown-{}".format(index)))
    values.append(("exact_time_above_2pow53",) + fixture(name="guarded-large-time", start=9007199254740993))
    values.append(("int64_maximum_time",) + fixture(name="guarded-max-time", start=9223372036854775807 - 2500000))
    values.append(("immediate_health",) + fixture(name="guarded-immediate", immediate=True))
    return values


def host_reference(binary, header, config, records):
    analysis_source = json.loads(header["analysis"])
    health_source = json.loads(header["health"])
    analysis = native(binary, "--analyze-checkpoint", [analysis_source], count=1)[0]
    health = native(binary, "--health-checkpoint", [health_source], count=1)[0]
    outputs = []
    oracle = health_reference.Oracle(config)
    gate_oracle = gates.Oracle(json.loads(analysis_source["counting"]))
    errors = {}
    for value in records:
        object_frame = json.loads(value["measurement"])
        landmark_frame = json.loads(value["health"])
        candidate_health = native(binary, "--health", [{"resume": health}, landmark_frame], count=1)[0]
        health_reference.compare_report(candidate_health, oracle.update(landmark_frame), errors)
        allowed = candidate_health["status"] == "healthy"
        effective = object_frame if allowed else checkpoints.frame(object_frame["timestamp_us"],
            removed=[item["track_id"] for item in analysis["measurement"]["motion"]["tracks"]])
        candidate_analysis = native(binary, "--analyze", [{"resume": analysis}, effective], count=1)[0]
        gates.tree_close(candidate_analysis["counting"], gate_oracle.update(candidate_analysis["measurement"]), errors)
        next_analysis = native(binary, "--analyze-checkpoint", [{"resume": analysis}, effective], count=1)[0]
        next_health = native(binary, "--health-checkpoint", [{"resume": health}, landmark_frame], count=1)[0]
        outputs.append({"schema_version": "0.1.0", "kind": "guarded_analysis_frame",
            "decision": "allowed" if allowed else "blocked",
            "suppressed_track_ids": [] if allowed else sorted(item["track_id"] for item in object_frame["observations"]),
            "health": candidate_health, "analysis": candidate_analysis})
        analysis, health = next_analysis, next_health
    return outputs, combined(analysis, health), errors


def reference_checks(binary):
    records, errors = [], {}
    total = cuts = allowed = blocked = closed = crossings = 0
    for name, header, config, frames in fixtures():
        expected, saved, numerical = host_reference(binary, header, config, frames)
        for key, value in numerical.items():
            errors[key] = max(errors.get(key, 0), value)
        actual = native(binary, "--guarded", [header] + frames)
        if actual != expected:
            raise AssertionError(name + ": admission differs from separate old CLI paths")
        if native(binary, "--guarded-checkpoint", [header] + frames, count=1)[0] != saved:
            raise AssertionError(name + ": nested checkpoint differs from host composition")
        for output in actual:
            is_allowed = output["decision"] == "allowed"
            allowed += int(is_allowed)
            blocked += int(not is_allowed)
            measurement = output["analysis"]["measurement"]
            if not is_allowed and measurement["tracks"]:
                raise AssertionError("blocked frame exposed object positions or zero speed")
            closed += len(measurement["closed_segment_ids"])
            crossings += len(output["analysis"]["counting"]["crossings"])
        for cut in range(len(frames) + 1):
            prefix = native(binary, "--guarded-checkpoint", [header] + frames[:cut], count=1)[0]
            for resume in [{"resume": prefix}, source({"resume": prefix["analysis"]}, {"resume": prefix["health"]})]:
                if native(binary, "--guarded", [resume] + frames[cut:]) != actual[cut:]:
                    raise AssertionError("{} cut {} changed continuation".format(name, cut))
                if native(binary, "--guarded-checkpoint", [resume] + frames[cut:], count=1)[0] != saved:
                    raise AssertionError("{} cut {} changed final state".format(name, cut))
            cuts += 1
        records.append({"name": name, "frames": len(frames), "checkpoint_sha256": hashlib.sha256(encode(saved).encode()).hexdigest()})
        total += len(frames)
    if not allowed or not blocked or not closed or not crossings:
        raise AssertionError("admission reference did not exercise all lifecycle branches")
    return {"cases": len(records), "frames": total, "allowed": allowed, "blocked": blocked,
        "closed_segments": closed, "crossings": crossings, "resume_cut_points": cuts,
        "resume_source_forms": 2, "maximum_absolute_oracle_errors": errors,
        "full_motion_covariance_paths_counters_and_anchors_equal": True, "records": records}


def rejection_checks(binary):
    header, config, frames = fixture()
    saved = native(binary, "--guarded-checkpoint", [header] + frames[:4], count=1)[0]
    blocked = native(binary, "--guarded-checkpoint", [header] + frames[:6], count=1)[0]
    prefix = native(binary, "--guarded", [header, frames[0]])
    cases = []

    def bad(name, values, expected=(), mode="--guarded", payload=None, extra=()):
        actual, evidence = run(binary, mode, values, status=2, payload=payload, extra=extra)
        if actual != list(expected):
            raise AssertionError(name + ": failure lost prefix or exposed a checkpoint")
        cases.append(dict(name=name, **evidence))

    for name, value in [("missing_health_source", {"analysis": header["analysis"]}),
        ("source_object_instead_raw_text", dict(header, analysis=json.loads(header["analysis"]))),
        ("unknown_source_key", dict(header, extra=True)),
        ("duplicate_source_key", '{"analysis":"bad",' + encode(header)[1:]),
        ("ground_mode_forbidden", source(analysis_reference.source({"session_id": "ground", "mode": "ground"}, gates.configuration(name="ground")), config))]:
        bad(name, [value])
    for name, mutate in [
        ("calibration_matrix_mismatch", lambda v: v["health"]["configuration"]["calibration"]["matrix"].__setitem__(2, 0.1)),
        ("calibration_roi_order_mismatch", lambda v: v["health"]["configuration"]["calibration"]["roi"].reverse()),
        ("calibration_noise_mismatch", lambda v: v["health"]["configuration"]["calibration"].update(ground_noise_floor_m=0.002)),
        ("calibration_maximum_scale_mismatch", lambda v: v["health"]["configuration"]["calibration"].update(max_meters_per_pixel=1)),
        ("watermark_mismatch", lambda v: v["health"]["state"].update(last_timestamp_us="400001")),
        ("wrong_guard_format", lambda v: v.update(format="other")),
        ("wrong_guard_version", lambda v: v.update(checkpoint_version="2")),
        ("unknown_guard_field", lambda v: v.update(extra=True)),
    ]:
        invalid = copy.deepcopy(saved)
        mutate(invalid)
        bad(name, [{"resume": invalid}])
    impossible = copy.deepcopy(saved)
    impossible["health"]["state"]["streak"] = None
    bad("nonhealthy_with_active_analysis", [{"resume": impossible}])
    predates = copy.deepcopy(saved)
    predates["health"]["state"]["streak"]["since_us"] = "100000"
    # The current report is still healthy (400000-100000==300000), but the
    # active segment began at 300000, before health could be confirmed.
    bad("active_segment_predates_health_confirmation", [{"resume": predates}])
    too_small = copy.deepcopy(header)
    analysis = json.loads(too_small["analysis"])
    counting = json.loads(analysis["counting"])
    counting["max_tracks"] = 15
    analysis["counting"] = encode(counting)
    too_small["analysis"] = encode(analysis)
    bad("gate_capacity_smaller_than_motion", [too_small])
    brown_header, _, brown_frames = fixture(camera_reference.CAMERAS[0], "guarded-brown-strict")
    brown_saved = native(binary, "--guarded-checkpoint", [brown_header] + brown_frames[:4], count=1)[0]
    brown_saved["health"]["configuration"]["camera"]["k1"] += 0.001
    bad("camera_parameters_mismatch", [{"resume": brown_saved}])
    bad("resume_override", [{"resume": saved, "health": header["health"]}])
    # Structural checks apply before admission, including on a Pending frame.
    for name, mutate in [
        ("blocked_duplicate_track", lambda v: v["observations"].append(copy.deepcopy(v["observations"][0]))),
        ("blocked_observation_lost_conflict", lambda v: v.update(lost=[1])),
        ("blocked_observation_removed_conflict", lambda v: v.update(removed=[2])),
        ("blocked_invalid_covariance", lambda v: v["observations"][0].update(covariance=[1, 2, 1])),
        ("blocked_unknown_measurement_field", lambda v: v.update(extra=True)),
        ("blocked_too_many_observations", lambda v: v.update(observations=[dict(copy.deepcopy(v["observations"][0]), track_id=i + 1) for i in range(17)])),
    ]:
        invalid = copy.deepcopy(frames[1])
        measurement = json.loads(invalid["measurement"])
        mutate(measurement)
        invalid["measurement"] = encode(measurement)
        bad(name, [header, frames[0], invalid], prefix)
    fractional = copy.deepcopy(frames[1])
    fractional["measurement"] = fractional["measurement"].replace('"track_id":2', '"track_id":2.0000000000000001')
    bad("blocked_fractional_track_token", [header, frames[0], fractional], prefix)
    mismatch = copy.deepcopy(frames[1])
    value = json.loads(mismatch["health"])
    value["timestamp_us"] = "100001"
    mismatch["health"] = encode(value)
    bad("inner_timestamp_mismatch", [header, frames[0], mismatch], prefix)
    bad("unknown_wrapper_field", [header, frames[0], dict(frames[1], extra=True)], prefix)
    bad("inner_object_instead_raw_text", [header, dict(frames[0], measurement=json.loads(frames[0]["measurement"]))])
    bad("duplicate_wrapper_key", [header, frames[0], '{"health":"bad",' + encode(frames[1])[1:]], prefix)
    bad("late_error_no_checkpoint", [header, frames[0], dict(frames[1], extra=True)], mode="--guarded-checkpoint")
    bad("invalid_utf8", [], prefix, payload=lines([header, frames[0]]).encode() + b"\xff\n")
    invalid_health = copy.deepcopy(frames[4])
    landmark_frame = json.loads(invalid_health["health"])
    landmark_frame["observations"][0]["landmark_id"] = "unknown"
    invalid_health["health"] = encode(landmark_frame)
    bad("admitted_fatal_landmark_identity", [{"resume": saved}, invalid_health])
    bad("admitted_fatal_landmark_no_checkpoint", [{"resume": saved}, invalid_health], mode="--guarded-checkpoint")
    # Sixteen individually valid new IDs exceed capacity only when combined
    # with the two existing active filters. This fails in measurement staging.
    capacity = copy.deepcopy(frames[4])
    capacity["measurement"] = encode(checkpoints.frame(500000,
        [checkpoints.observation(identity, [8, 8]) for identity in range(3, 19)]))
    bad("admitted_active_capacity_exhaustion", [{"resume": saved}, capacity])
    bad("admitted_capacity_no_checkpoint", [{"resume": saved}, capacity], mode="--guarded-checkpoint")
    # An old live counter can legitimately be saturated; the next admitted
    # crossing must not commit the candidate health watermark.
    saturated = copy.deepcopy(saved)
    for count in saturated["analysis"]["counting"]["state"]["counts"]:
        count.update(negative_to_positive="9223372036854775807", positive_to_negative="9223372036854775807")
    next_wrapper = copy.deepcopy(frames[4])
    measured = json.loads(frames[3]["measurement"])
    measured["timestamp_us"] = "500000"
    for item in measured["observations"]:
        item["point"][1] = -100
    next_wrapper["measurement"] = encode(measured)
    bad("admitted_counter_overflow", [{"resume": saturated}, next_wrapper])
    bad("admitted_counter_overflow_no_checkpoint", [{"resume": saturated}, next_wrapper], mode="--guarded-checkpoint")
    correction = copy.deepcopy(next_wrapper)
    correction["measurement"] = encode(checkpoints.frame(500000))
    corrected = native(binary, "--guarded-checkpoint", [{"resume": saturated}, correction], count=1)[0]
    if corrected["health"]["state"]["last_timestamp_us"] != "500000" or corrected["analysis"]["measurement"]["motion"]["last_timestamp_us"] != "500000":
        raise AssertionError("same-time correction failed to advance both watermarks")
    if corrected["analysis"]["counting"]["state"]["counts"] != saturated["analysis"]["counting"]["state"]["counts"]:
        raise AssertionError("saturated count changed on empty correction")
    if blocked["analysis"]["measurement"]["motion"]["tracks"] or blocked["analysis"]["counting"]["state"]["tracks"]:
        raise AssertionError("blocked checkpoint retained active state")
    retried = native(binary, "--guarded-checkpoint", [{"resume": saved}, frames[4]], count=1)[0]
    expected_retry = native(binary, "--guarded-checkpoint", [header] + frames[:5], count=1)[0]
    if retried != expected_retry:
        raise AssertionError("same-time correction after health/measurement errors changed state")
    return {"rejected_cases": len(cases), "cases": cases, "complete_prefix_preserved": True,
        "same_time_correction_from_saturated_checkpoint": "passed",
        "same_time_correction_from_saved_health_and_measurement_failure": "passed"}


def transport_checks(binary):
    header, _, frames = fixture()
    expected = native(binary, "--guarded", [header] + frames[:2])
    for ending in [b"\n", b"\r\n"]:
        if run(binary, "--guarded", payload=ending.join(encode(v).encode() for v in [header] + frames[:2]))[0] != expected:
            raise AssertionError("line ending or unterminated EOF changed results")
    exact = max(len(encode(v).encode()) for v in [header] + frames[:2])
    if native(binary, "--guarded", [header] + frames[:2], extra=["--max-line-bytes", str(exact)]) != expected:
        raise AssertionError("exact physical line boundary rejected")
    saved = native(binary, "--guarded-checkpoint", [header], count=1)[0]
    padded = encode({"resume": saved}).ljust(8388619)
    if native(binary, "--guarded-checkpoint", [padded], count=1, extra=["--max-line-bytes", "16777216"])[0] != saved:
        raise AssertionError("exact source UTF-16 boundary changed state")
    _, failure = run(binary, "--guarded-checkpoint", [padded + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    return {"crlf_and_unterminated_eof": "passed", "exact_physical_line_bytes": exact,
        "exact_source_utf16_units": 8388619, "source_one_unit_overflow": failure}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/guarded.test.mjs"]
    completed = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=300)
    if completed.returncode:
        raise AssertionError("Node guarded verification failed:\n" + completed.stdout[-18000:] + completed.stderr[-2000:])
    summary, directions = {}, None
    for value in completed.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", value)
        if match:
            summary[match.group(1)] = int(match.group(2))
        if value.startswith('# {"cut_points":'):
            directions = json.loads(value[2:])
    if not summary.get("tests") or summary.get("pass") != summary["tests"] or summary.get("fail") or directions is None:
        raise AssertionError("incomplete Node summary/runtime directions")
    return {"status": "passed", "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "command": " ".join(command), "summary": summary, "cross_runtime": directions,
        "test_script_sha256": hashlib.sha256((ROOT / "web/guarded.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(), "stderr": completed.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/guarded-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "fixtures": "deterministic", "command": " ".join(shlex.quote(v) for v in [sys.executable] + sys.argv),
        "python": platform.python_version(), "numpy": np.__version__, "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "health_reference_sha256": hashlib.sha256(Path(health_reference.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["independent_host_composition"] = reference_checks(binary)
    result["strict_transport"] = rejection_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    result["status"] = "passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "output": str(args.output),
        "cases": result["independent_host_composition"]["cases"], "frames": result["independent_host_composition"]["frames"],
        "resume_cut_points": result["independent_host_composition"]["resume_cut_points"],
        "strict_rejections": result["strict_transport"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
