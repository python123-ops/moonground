#!/usr/bin/env python3
"""Check projection barriers through the pre-existing health/analysis paths.

The host interrupts analysis with an ordinary empty frame removing every live
filter, starts a fresh old health monitor at the barrier, and changes only the
canonical projection fields in the interrupted checkpoint. NumPy projection and
gate references check the admitted observations separately. No replacement API
is called by the host reference.
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
import guarded_verify as guarded
import health_verify as health_reference
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
encode = gates.encode
native = guarded.native
run = guarded.run


def projection(index=0):
    matrices = [[0.125, 0, 0, 0, 0.125, 0, 0, 0, 1],
        [0.25, 0.01, -1, 0, 0.2, 0.5, 0.0002, 0, 1],
        [0.2, 0, 0.5, -0.01, 0.25, -1, 0, -0.0001, 1]]
    return {"matrix": matrices[index % 3], "roi": [[-200, -200], [200, -200], [200, 200], [-200, 200]],
        "max_meters_per_pixel": 1, "ground_noise_floor_m": 0.001}


def camera(index=0):
    return {"fx": 400 + index * 170, "fy": 420 + index * 110, "cx": index * 10,
        "cy": index * 20, "k1": 0.08 - index * 0.12, "k2": -0.01, "k3": 0.001,
        "p1": 0.0002, "p2": -0.0003, "max_normalized_radius": 0.8}


def pixel(calibration, brown, point):
    homogeneous = np.linalg.solve(np.asarray(calibration["matrix"]).reshape(3, 3), list(point) + [1])
    ideal = homogeneous[:2] / homogeneous[2]
    return (camera_reference.distort_pixel(ideal, brown) if brown is not None else ideal).tolist()


def configuration(name="projection-reference", immediate=False):
    calibration = projection()
    health = {"monitor_id": name + "-landmarks", "calibration": copy.deepcopy(calibration),
        "landmarks": [{"landmark_id": identity, "ground_m": point} for identity, point in
            zip("ABCD", [[1, 1], [3, 1], [1, 3], [3, 3]])],
        "health": {"min_landmarks": 3, "rms_limit_m": 0.1, "max_error_m": 0.2,
            "confirmation_us": "0" if immediate else "200000", "min_observations": 1 if immediate else 3,
            "max_gap_us": "500000", "max_position_std_m": 0.3}}
    measurement = {"session_id": name, "mode": "pixel", "diagnostics": True,
        "calibration": copy.deepcopy(calibration), "motion": {"max_tracks": 8,
            "max_gap_us": "500000", "min_observations": 2, "min_span_us": "100000",
            "gate": 1e9, "initial_velocity_std": 10, "q": 5}}
    counting = gates.configuration(name=name, gates=[gates.gate("entry", (-100, 2), (100, 2), 0.005),
        gates.gate("exit", (-100, 6), (100, 6), 0.005)])
    counting["max_tracks"] = 8
    return guarded.source(analysis_reference.source(measurement, counting), health), health


def observation_frame(config, timestamp, y=1, hidden=False, drift=False):
    calibration, brown = config["calibration"], config.get("camera")
    fixed = [health_reference.observation(item["landmark_id"],
        pixel(calibration, brown, np.asarray(item["ground_m"]) + ([0.5, 0] if drift else [0, 0])),
        [0.04, 0.008, 0.09]) for item in config["landmarks"]]
    objects = [] if hidden else [checkpoints.observation(identity,
        pixel(calibration, brown, [1 + identity * 0.1, y]), [0.04, 0.008, 0.09]) for identity in [2, 1]]
    return guarded.wrapper(checkpoints.frame(timestamp, objects), health_reference.frame(timestamp, fixed))


def replacement(timestamp, calibration, brown):
    return {"replace_projection": encode({"timestamp_us": str(timestamp),
        "calibration": calibration, "camera": brown})}


def fixture(start=0, name="projection-reference"):
    header, config = configuration(name)
    current, records = copy.deepcopy(config), []
    # Last phase repeats the exact same projection: an explicit reset still
    # closes segments and restarts health confirmation.
    options = [(projection(1), camera(0)), (projection(2), camera(1)), (projection(0), None), (projection(0), None)]
    stamp = start
    for calibration, brown in options:
        for index in range(5):
            records.append(observation_frame(current, stamp, y=1 if index < 3 else 3, hidden=index == 4))
            stamp += 100000
        records.append(replacement(stamp, calibration, brown))
        stamp += 100000
        current["calibration"] = copy.deepcopy(calibration)
        if brown is None:
            current.pop("camera", None)
        else:
            current["camera"] = copy.deepcopy(brown)
    for index in range(5):
        records.append(observation_frame(current, stamp, y=1 if index < 3 else 3))
        stamp += 100000
    return header, config, records


def fixtures():
    values = [("camera_add_change_remove_equal",) + fixture()]
    values.append(("above_2pow53",) + fixture(9007199254740993, "projection-large-time"))
    values.append(("int64_final_timestamp",) + fixture(9223372036854775807 - 2800000, "projection-max-time"))
    header, config = configuration("projection-unstarted")
    values.append(("unstarted_and_pending_replacements", header, config,
        [replacement(0, projection(1), camera()),
         replacement(1, projection(), None), observation_frame(config, 2),
         replacement(3, projection(), None), observation_frame(config, 4)]))
    header, config = configuration("projection-drift", immediate=True)
    values.append(("drift_replacement_and_immediate_reconfirmation", header, config,
        [observation_frame(config, 0), observation_frame(config, 100000, y=3),
         observation_frame(config, 200000, drift=True), replacement(300000, projection(), None),
         observation_frame(config, 400000), observation_frame(config, 500000, y=3)]))
    return values


def change_projection(configuration, new_configuration):
    configuration["calibration"] = copy.deepcopy(new_configuration["calibration"])
    if "camera" in new_configuration:
        configuration["camera"] = copy.deepcopy(new_configuration["camera"])
    else:
        configuration.pop("camera", None)


def host_reference(binary, header, records):
    source = json.loads(header["analysis"])
    analysis = native(binary, "--analyze-checkpoint", [source], count=1)[0]
    health = native(binary, "--health-checkpoint", [json.loads(header["health"])], count=1)[0]
    oracle = health_reference.Oracle(health["configuration"])
    gate_oracle = gates.Oracle(json.loads(source["counting"]))
    outputs, snapshots, errors = [], [guarded.combined(analysis, health)], {}
    for wrapper in records:
        replacing = "replace_projection" in wrapper
        if replacing:
            control = json.loads(wrapper["replace_projection"])
            timestamp = control["timestamp_us"]
            health_config = copy.deepcopy(health["configuration"])
            change_projection(health_config, control if control["camera"] is not None else {"calibration": control["calibration"]})
            health_source = health_config
            health_frame = health_reference.frame(timestamp)
            oracle = health_reference.Oracle(health_config)
            object_frame = checkpoints.frame(timestamp)
        else:
            object_frame = json.loads(wrapper["measurement"])
            health_frame = json.loads(wrapper["health"])
            health_source = {"resume": health}
        report = native(binary, "--health", [health_source, health_frame], count=1)[0]
        health_reference.compare_report(report, oracle.update(health_frame), errors)
        allowed = not replacing and report["status"] == "healthy"
        effective = object_frame if allowed else checkpoints.frame(object_frame["timestamp_us"],
            removed=sorted(item["track_id"] for item in analysis["measurement"]["motion"]["tracks"]))
        measured = native(binary, "--analyze", [{"resume": analysis}, effective], count=1)[0]
        gates.tree_close(measured["counting"], gate_oracle.update(measured["measurement"]), errors)
        next_analysis = native(binary, "--analyze-checkpoint", [{"resume": analysis}, effective], count=1)[0]
        next_health = native(binary, "--health-checkpoint", [health_source, health_frame], count=1)[0]
        if replacing:
            change_projection(next_analysis["measurement"]["configuration"], next_health["configuration"])
        outputs.append({"schema_version": "0.1.0", "kind": "guarded_projection_replaced" if replacing else "guarded_analysis_frame",
            "decision": "allowed" if allowed else "blocked", "suppressed_track_ids": [] if allowed or replacing else
                sorted(item["track_id"] for item in object_frame["observations"]), "health": report, "analysis": measured})
        analysis, health = next_analysis, next_health
        snapshots.append(guarded.combined(analysis, health))
    return outputs, snapshots, errors


def reference_checks(binary):
    cases, errors = [], {}
    total = cuts = barriers = closed = crossings = allowed = 0
    for name, header, _, frames in fixtures():
        expected, snapshots, numerical = host_reference(binary, header, frames)
        actual = native(binary, "--guarded", [header] + frames)
        if actual != expected:
            for index, (a, b) in enumerate(zip(actual, expected)):
                if a != b:
                    raise AssertionError(name + " frame " + str(index) + " differs from old-path composition: " + encode(a)[:400])
            raise AssertionError(name + ": frame count differs")
        for key, value in numerical.items():
            errors[key] = max(errors.get(key, 0), value)
        for cut in range(len(frames) + 1):
            saved = native(binary, "--guarded-checkpoint", [header] + frames[:cut], count=1)[0]
            if saved != snapshots[cut]:
                raise AssertionError("{} cut {} canonical projection or state differs".format(name, cut))
            for resume in [{"resume": saved}, guarded.source({"resume": saved["analysis"]}, {"resume": saved["health"]})]:
                if native(binary, "--guarded", [resume] + frames[cut:]) != actual[cut:]:
                    raise AssertionError("{} cut {} continuation differs".format(name, cut))
                if native(binary, "--guarded-checkpoint", [resume] + frames[cut:], count=1)[0] != snapshots[-1]:
                    raise AssertionError("{} cut {} final checkpoint differs".format(name, cut))
            cuts += 1
        for index, output in enumerate(actual):
            barriers += output["kind"] == "guarded_projection_replaced"
            allowed += output["decision"] == "allowed"
            closed += len(output["analysis"]["measurement"]["closed_segment_ids"])
            crossings += len(output["analysis"]["counting"]["crossings"])
            if output["kind"] == "guarded_projection_replaced":
                before, after = snapshots[index], snapshots[index + 1]
                motion_before = before["analysis"]["measurement"]["motion"]
                motion_after = after["analysis"]["measurement"]["motion"]
                assert not motion_after["tracks"] and not after["analysis"]["counting"]["state"]["tracks"]
                assert motion_before["next_segment_id"] == motion_after["next_segment_id"]
                assert before["analysis"]["counting"]["state"]["counts"] == after["analysis"]["counting"]["state"]["counts"]
                assert after["health"]["state"]["streak"] is None
                assert output["decision"] == "blocked" and output["suppressed_track_ids"] == []
                assert output["analysis"]["measurement"]["tracks"] == []
        cases.append({"name": name, "frames": len(frames), "checkpoint_sha256": hashlib.sha256(encode(snapshots[-1]).encode()).hexdigest()})
        total += len(frames)
    assert barriers and closed and crossings and allowed
    return {"cases": len(cases), "frames": total, "replacement_barriers": barriers,
        "allowed_frames": allowed, "closed_segments": closed, "crossings": crossings,
        "resume_cut_points": cuts, "resume_source_forms": 2,
        "maximum_absolute_oracle_errors": errors,
        "full_motion_covariance_paths_counts_anchors_and_projection_caches_equal": True, "records": cases}


def strict_checks(binary):
    header, _, frames = fixture()
    prefix_frames = frames[:5]
    prefix = native(binary, "--guarded", [header] + prefix_frames)
    saved = native(binary, "--guarded-checkpoint", [header] + prefix_frames, count=1)[0]
    control = json.loads(frames[5]["replace_projection"])
    cases = []

    def bad(name, frame, checkpoint=False):
        mode = "--guarded-checkpoint" if checkpoint else "--guarded"
        actual, evidence = run(binary, mode, [header] + prefix_frames + [frame], status=2)
        if actual != ([] if checkpoint else prefix):
            raise AssertionError(name + ": partial output or checkpoint leaked")
        cases.append(dict(name=name, **evidence))

    for name, mutate in [
        ("missing_camera", lambda v: v.pop("camera")),
        ("missing_calibration", lambda v: v.pop("calibration")),
        ("missing_timestamp", lambda v: v.pop("timestamp_us")),
        ("unknown_inner_field", lambda v: v.update(same_ground_frame=True)),
        ("equal_timestamp", lambda v: v.update(timestamp_us="400000")),
        ("earlier_timestamp", lambda v: v.update(timestamp_us="399999")),
        ("negative_timestamp", lambda v: v.update(timestamp_us="-1")),
        ("numeric_timestamp", lambda v: v.update(timestamp_us=500000)),
        ("fractional_timestamp_string", lambda v: v.update(timestamp_us="500000.0")),
        ("timestamp_int64_overflow", lambda v: v.update(timestamp_us="9223372036854775808")),
        ("singular_matrix", lambda v: v["calibration"].update(matrix=[0] * 9)),
        ("invalid_roi", lambda v: v["calibration"].update(roi=[[0, 0], [1, 1], [1, 0], [0, 1]])),
        ("negative_noise", lambda v: v["calibration"].update(ground_noise_floor_m=-1)),
        ("unknown_calibration_key", lambda v: v["calibration"].update(extra=True)),
        ("invalid_camera_focal", lambda v: v["camera"].update(fx=0)),
        ("unknown_camera_key", lambda v: v["camera"].update(extra=True)),
    ]:
        invalid = copy.deepcopy(control)
        mutate(invalid)
        bad(name, {"replace_projection": encode(invalid)})
    for name, value in [
        ("control_object_not_raw_text", {"replace_projection": control}),
        ("mixed_measurement", dict(frames[5], measurement=frames[0]["measurement"])),
        ("mixed_health", dict(frames[5], health=frames[0]["health"])),
        ("unknown_outer_key", dict(frames[5], extra=True)),
        ("duplicate_outer_key", '{"replace_projection":"bad",' + encode(frames[5])[1:]),
        ("duplicate_inner_timestamp", {"replace_projection": '{"timestamp_us":"500000",' + encode(control)[1:]}),
        ("duplicate_inner_camera", {"replace_projection": '{"camera":null,' + encode(control)[1:]}),
        ("inner_trailing_json", {"replace_projection": encode(control) + '{}'}),
        ("inner_nonfinite_number", {"replace_projection": encode(control).replace('"fx":400', '"fx":1e999')}),
        ("inner_nonobject", {"replace_projection": '[]'}),
    ]:
        bad(name, value)
    bad("late_invalid_control_no_checkpoint", {"replace_projection": encode(dict(control, camera=False))}, checkpoint=True)
    # Independent commands resume exactly the pre-failure state, accepting a
    # corrected request at that same proposed timestamp.
    correction = native(binary, "--guarded-checkpoint", [{"resume": saved}, frames[5]], count=1)[0]
    assert correction == native(binary, "--guarded-checkpoint", [header] + frames[:6], count=1)[0]
    # Watermark MAX cannot be advanced even by a projection-only operation.
    maximum = copy.deepcopy(saved)
    delta = 9223372036854775807 - 400000
    # Generate the valid MAX checkpoint through the ordinary public path,
    # rather than forging filter history times.
    big_header, _, big_frames = fixture(delta, "projection-full-clock")
    maximum = native(binary, "--guarded-checkpoint", [big_header] + big_frames[:5], count=1)[0]
    _, evidence = run(binary, "--guarded", [{"resume": maximum}, replacement(9223372036854775807, projection(), None)], status=2, count=0)
    cases.append(dict(name="maximum_watermark_cannot_advance", **evidence))
    return {"rejected_cases": len(cases), "complete_prefix_preserved": True,
        "late_failure_emits_no_checkpoint": True, "same_proposed_timestamp_correction_from_saved_state": "passed", "cases": cases}


def transport_checks(binary):
    header, _, frames = fixture()
    records = [header] + frames[:6]
    expected = native(binary, "--guarded", records)
    for ending in [b"\n", b"\r\n"]:
        payload = ending.join(encode(v).encode() for v in records)
        assert run(binary, "--guarded", payload=payload)[0] == expected
    # Spaces inside the raw control text let the outer physical line exercise
    # the precise inherited 1 MiB bound without changing the inner JSON.
    base = frames[5]["replace_projection"]
    padded = {"replace_projection": base + " " * (1048576 - len(encode(frames[5]).encode()))}
    exact = encode(padded).encode()
    assert len(exact) == 1048576
    assert native(binary, "--guarded", [header] + frames[:5] + [padded]) == expected
    too_large = dict(padded, replace_projection=padded["replace_projection"] + " ")
    actual, evidence = run(binary, "--guarded", [header] + frames[:5] + [too_large], status=2)
    assert actual == expected[:5]
    # The native transport override does not enlarge the independent codec
    # budget. An inner document at its own limit cannot fit this raw-string
    # envelope, so do not claim a successful inner-boundary observation.
    overridden, override_failure = run(binary, "--guarded", [header] + frames[:5] + [too_large],
        status=2, extra=["--max-line-bytes", "16777216"])
    assert overridden == expected[:5]
    _, inner_failure = run(binary, "--guarded-checkpoint", [header] + frames[:5] +
        [{"replace_projection": base.ljust(1048577)}], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    return {"crlf_and_unterminated_eof": "passed", "exact_outer_physical_bytes": len(exact),
        "one_extra_outer_byte": evidence, "codec_limit_with_native_transport_override": override_failure,
        "oversized_raw_inner_document": inner_failure}


def transit_checks(binary):
    header, _, frames = fixture()
    reports = native(binary, "--guarded", [header] + frames[:6])
    analysis_source = json.loads(header["analysis"])
    transit = {"counting": analysis_source["counting"], "sections": [{"section_id": "corridor",
        "entry_gate_id": "entry", "entry_direction": "negative_to_positive", "exit_gate_id": "exit",
        "exit_direction": "negative_to_positive"}], "max_duration_us": "300000000"}
    measured = [frame["analysis"]["measurement"] for frame in reports]
    events = native(binary, "--transit", [transit] + measured)
    # The hidden frame immediately preceding the barrier already interrupts
    # counting continuity. Separately remove it to make the barrier itself
    # the sole discontinuity observed by downstream transit.
    measured = measured[:4] + measured[5:]
    events = native(binary, "--transit", [transit] + measured)
    assert events[-2]["pending_count"] == 2
    assert events[-1]["pending_count"] == 0
    assert len(events[-1]["cancellations"]) == 2
    assert all(item["reason"] == "discontinuity" for item in events[-1]["cancellations"])
    assert not any(event["passages"] for event in events)
    checkpoint = native(binary, "--transit-checkpoint", [transit] + measured, count=1)[0]
    assert checkpoint["pending"] == []
    return {"status": "passed", "barrier_discontinuity_cancellations": 2,
        "pending_before": 2, "pending_after": 0, "passages_across_replacement": 0}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/projection-replace.test.mjs"]
    completed = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=300)
    if completed.returncode:
        raise AssertionError("Node replacement verification failed:\n" + completed.stdout[-18000:] + completed.stderr[-2000:])
    summary, directions = {}, None
    for value in completed.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", value)
        if match:
            summary[match.group(1)] = int(match.group(2))
        if value.startswith('# {"cut_points":'):
            directions = json.loads(value[2:])
    assert summary.get("tests") and summary.get("pass") == summary["tests"] and not summary.get("fail") and directions is not None
    return {"status": "passed", "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "command": " ".join(command), "summary": summary, "cross_runtime": directions,
        "test_script_sha256": hashlib.sha256((ROOT / "web/projection-replace.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(), "stderr": completed.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/projection-replace-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "fixtures": "deterministic", "command": " ".join(shlex.quote(v) for v in [sys.executable] + sys.argv),
        "python": platform.python_version(), "numpy": np.__version__, "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "health_reference_sha256": hashlib.sha256(Path(health_reference.__file__).read_bytes()).hexdigest(),
        "gate_reference_sha256": hashlib.sha256(Path(gates.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["independent_host_composition"] = reference_checks(binary)
    result["strict_transport"] = strict_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    result["downstream_transit"] = transit_checks(binary)
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
