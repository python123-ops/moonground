#!/usr/bin/env python3
"""Check health admission with three independent pre-existing CLI owners.

The host stages --health, --stream and --count-evidence separately. Suppressed
objects become an ordinary empty measurement removing all active filters. A
projection barrier starts an old health monitor, interrupts the old session,
and changes only its canonical projection. No new guarded owner is used by the
reference. NumPy landmarks and Fraction/Decimal gate evidence remain separate.
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
import evidence_analysis_verify as evidence_analysis
import evidence_verify as evidence_reference
import gates_verify as gates
import guarded_verify as guarded
import health_verify as health_reference
import projection_replace_verify as replacement_reference
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
encode, native, run = gates.encode, gates.native, gates.execute
source, wrapper = guarded.source, guarded.wrapper


def header(old, multiplier=2):
    analysis = json.loads(old["analysis"])
    return source(analysis_reference.source(analysis["measurement"],
        {"counting": analysis["counting"], "sigma_multiplier": multiplier}), old["health"])


def combined(analysis, health):
    return {"format": "moonground.evidence-guarded", "checkpoint_version": "1", "analysis": analysis, "health": health}


def fixtures():
    values = [("replacement_" + name, header(old, 3.5), frames)
        for name, old, _, frames in replacement_reference.fixtures()]
    values.extend(("admission_" + name, header(old), frames) for name, old, _, frames in guarded.fixtures())
    return values


def host_reference(binary, head, frames):
    analysis_source = json.loads(head["analysis"])
    measurement = native(binary, "--checkpoint", [analysis_source["measurement"]], count=1)[0]
    counting = native(binary, "--evidence-checkpoint", [analysis_source["counting"]], count=1)[0]
    health = native(binary, "--health-checkpoint", [head["health"]], count=1)[0]
    health_oracle = health_reference.Oracle(health["configuration"])
    counter_config = counting["configuration"]
    gate_oracle = evidence_reference.Oracle({"counting": encode(counter_config["counting"]),
        "sigma_multiplier": counter_config["sigma_multiplier"]}, counter_config["counting"])
    snapshots = [combined(evidence_analysis.combined(measurement, counting), health)]
    outputs, absolute, relative = [], {}, {}
    for value in frames:
        replacing = "replace_projection" in value
        if replacing:
            control = json.loads(value["replace_projection"])
            config = copy.deepcopy(health["configuration"])
            replacement_reference.change_projection(config, control if control["camera"] is not None else {"calibration": control["calibration"]})
            health_source = config
            landmark_frame = health_reference.frame(control["timestamp_us"])
            object_frame = checkpoints.frame(control["timestamp_us"])
            health_oracle = health_reference.Oracle(config)
        else:
            health_source = {"resume": health}
            landmark_frame, object_frame = json.loads(value["health"]), json.loads(value["measurement"])
        report = native(binary, "--health", [health_source, landmark_frame], count=1)[0]
        health_reference.compare_report(report, health_oracle.update(landmark_frame), absolute)
        allowed = not replacing and report["status"] == "healthy"
        effective = object_frame if allowed else checkpoints.frame(object_frame["timestamp_us"],
            removed=sorted(item["track_id"] for item in measurement["motion"]["tracks"]))
        measured = native(binary, "--stream", [{"resume": measurement}, effective], count=1)[0]
        counted = native(binary, "--count-evidence", [{"resume": counting}, measured], count=1)[0]
        evidence_reference.compare_frame(counted, gate_oracle.update(measured), absolute, relative)
        next_measurement = native(binary, "--checkpoint", [{"resume": measurement}, effective], count=1)[0]
        next_counting = native(binary, "--evidence-checkpoint", [{"resume": counting}, measured], count=1)[0]
        next_health = native(binary, "--health-checkpoint", [health_source, landmark_frame], count=1)[0]
        if replacing:
            replacement_reference.change_projection(next_measurement["configuration"], next_health["configuration"])
        analysis = {"schema_version": "0.1.0", "kind": "evidence_analysis_frame", "measurement": measured, "counting": counted}
        outputs.append({"schema_version": "0.1.0", "kind": "evidence_guarded_projection_replaced" if replacing else "evidence_guarded_frame",
            "decision": "allowed" if allowed else "blocked", "suppressed_track_ids": [] if allowed or replacing else
                sorted(item["track_id"] for item in object_frame["observations"]), "health": report, "analysis": analysis})
        measurement, counting, health = next_measurement, next_counting, next_health
        snapshots.append(combined(evidence_analysis.combined(measurement, counting), health))
    return outputs, snapshots, absolute, relative


def reference_checks(binary):
    records, absolute, relative = [], {}, {}
    total = cuts = allowed = blocked = barriers = events = evidence_count = closed = 0
    for name, head, frames in fixtures():
        expected, snapshots, numeric, scaled = host_reference(binary, head, frames)
        actual = native(binary, "--guarded-evidence", [head] + frames)
        assert actual == expected, name + ": differs from three independent owners"
        for key, value in numeric.items():
            absolute[key] = max(absolute.get(key, 0), value)
        for key, value in scaled.items():
            relative[key] = max(relative.get(key, 0), value)
        for cut in range(len(frames) + 1):
            saved = native(binary, "--guarded-evidence-checkpoint", [head] + frames[:cut], count=1)[0]
            assert saved == snapshots[cut], (name, cut, "full checkpoint differs")
            for resume in [{"resume": saved}, source({"resume": saved["analysis"]}, {"resume": saved["health"]})]:
                assert native(binary, "--guarded-evidence", [resume] + frames[cut:]) == actual[cut:], (name, cut)
                assert native(binary, "--guarded-evidence-checkpoint", [resume] + frames[cut:], count=1)[0] == snapshots[-1], (name, cut)
            cuts += 1
        for index, value in enumerate(actual):
            is_allowed = value["decision"] == "allowed"
            allowed += is_allowed
            blocked += not is_allowed
            measured = value["analysis"]["measurement"]
            counted = value["analysis"]["counting"]
            events += len(counted["counting"]["crossings"])
            evidence_count += len(counted["evidence"])
            closed += len(measured["closed_segment_ids"])
            if not is_allowed:
                assert measured["tracks"] == [] and counted["evidence"] == []
            if value["kind"] == "evidence_guarded_projection_replaced":
                barriers += 1
                before, after = snapshots[index], snapshots[index + 1]
                assert after["health"]["state"]["streak"] is None
                assert after["analysis"]["measurement"]["motion"]["tracks"] == []
                assert after["analysis"]["counting"]["state"]["tracks"] == []
                assert before["analysis"]["counting"]["configuration"] == after["analysis"]["counting"]["configuration"]
                assert before["analysis"]["counting"]["state"]["counts"] == after["analysis"]["counting"]["state"]["counts"]
                assert before["analysis"]["measurement"]["motion"]["next_segment_id"] == after["analysis"]["measurement"]["motion"]["next_segment_id"]
        total += len(frames)
        records.append({"name": name, "frames": len(frames), "checkpoint_sha256": hashlib.sha256(encode(snapshots[-1]).encode()).hexdigest()})
    assert allowed and blocked and barriers and closed and events
    return {"cases": len(records), "frames": total, "allowed": allowed, "blocked": blocked,
        "replacement_barriers": barriers, "closed_segments": closed, "evidence_records": evidence_count, "crossings": events,
        "resume_cut_points": cuts, "resume_source_forms": 2,
        "full_health_streak_motion_covariance_paths_counts_anchor_covariances_and_projection_caches_equal": True,
        "maximum_absolute_oracle_errors": absolute, "maximum_relative_or_scaled_evidence_errors": relative, "records": records}


def strict_checks(binary):
    old, _, frames = guarded.fixture()
    head = header(old)
    prefix = native(binary, "--guarded-evidence", [head, frames[0]])
    saved = native(binary, "--guarded-evidence-checkpoint", [head] + frames[:4], count=1)[0]
    records = []

    def bad(name, values, expected=(), mode="--guarded-evidence", payload=None, extra=()):
        try:
            found, detail = run(binary, mode, values, status=2, payload=payload, extra=extra)
        except AssertionError as error:
            raise AssertionError(name + ": " + str(error)) from error
        assert found == list(expected), name + ": partial output/checkpoint exposed"
        records.append(dict(name=name, **detail))

    for name, invalid in [
        ("missing_health", {"analysis": head["analysis"]}),
        ("source_object_not_raw", dict(head, analysis=json.loads(head["analysis"]))),
        ("unknown_source_key", dict(head, extra=True)),
        ("duplicate_source_key", '{"analysis":"bad",' + encode(head)[1:]),
        ("old_guarded_source_not_upgraded", old),
    ]:
        bad(name, [invalid])
    smaller = copy.deepcopy(head)
    analysis = json.loads(smaller["analysis"])
    evidence = json.loads(analysis["counting"])
    policy = json.loads(evidence["counting"])
    policy["max_tracks"] = 15
    evidence["counting"] = encode(policy)
    analysis["counting"] = encode(evidence)
    smaller["analysis"] = encode(analysis)
    bad("counter_capacity_cannot_cover_motion", [smaller])
    ground = {"session_id": "evidence-guarded-ground", "mode": "ground", "motion": {"max_tracks": 8}}
    ground_policy = {"counting": encode(gates.configuration(name=ground["session_id"])), "sigma_multiplier": 2}
    bad("ground_measurement_forbidden", [source(analysis_reference.source(ground, ground_policy), old["health"])])
    for name, mutate in [
        ("wrong_format", lambda v: v.update(format="moonground.guarded")),
        ("wrong_version", lambda v: v.update(checkpoint_version="2")),
        ("unknown_checkpoint_field", lambda v: v.update(extra=True)),
        ("health_watermark_mismatch", lambda v: v["health"]["state"].update(last_timestamp_us="400001")),
        ("health_matrix_mismatch", lambda v: v["health"]["configuration"]["calibration"]["matrix"].__setitem__(2, .1)),
        ("health_roi_order_mismatch", lambda v: v["health"]["configuration"]["calibration"]["roi"].reverse()),
        ("health_noise_mismatch", lambda v: v["health"]["configuration"]["calibration"].update(ground_noise_floor_m=.002)),
        ("health_maximum_scale_mismatch", lambda v: v["health"]["configuration"]["calibration"].update(max_meters_per_pixel=1)),
        ("nonhealthy_retains_active_motion", lambda v: v["health"]["state"].update(streak=None)),
        ("segment_predates_health_confirmation", lambda v: v["health"]["state"]["streak"].update(since_us="100000")),
        ("missing_current_evidence_track", lambda v: v["analysis"]["counting"]["state"].update(tracks=[])),
        ("missing_effective_sigma", lambda v: v["analysis"]["counting"]["configuration"].pop("sigma_multiplier")),
        ("missing_effective_deadband", lambda v: v["analysis"]["counting"]["configuration"]["counting"]["gates"][0].pop("deadband_m")),
        ("missing_effective_health_threshold", lambda v: v["health"]["configuration"]["health"].pop("rms_limit_m")),
    ]:
        invalid = copy.deepcopy(saved)
        mutate(invalid)
        bad(name, [{"resume": invalid}])
    brown_old, _, brown_frames = guarded.fixture(camera_reference.CAMERAS[0], "evidence-guarded-camera")
    brown = native(binary, "--guarded-evidence-checkpoint", [header(brown_old)] + brown_frames[:4], count=1)[0]
    brown["health"]["configuration"]["camera"]["k1"] += .001
    bad("camera_mismatch", [{"resume": brown}])
    for name, mutate in [
        ("blocked_duplicate_object", lambda v: v["observations"].append(copy.deepcopy(v["observations"][0]))),
        ("blocked_lost_conflict", lambda v: v.update(lost=[1])),
        ("blocked_removed_conflict", lambda v: v.update(removed=[2])),
        ("blocked_indefinite_covariance", lambda v: v["observations"][0].update(covariance=[1, 2, 1])),
        ("blocked_capacity", lambda v: v.update(observations=[checkpoints.observation(i, [8, 8]) for i in range(1, 18)])),
    ]:
        invalid = copy.deepcopy(frames[1])
        obj = json.loads(invalid["measurement"])
        mutate(obj)
        invalid["measurement"] = encode(obj)
        bad(name, [head, frames[0], invalid], prefix)
    fractional = copy.deepcopy(frames[1])
    fractional["measurement"] = fractional["measurement"].replace('"track_id":2', '"track_id":2.0000000000000001')
    bad("blocked_raw_fractional_id", [head, frames[0], fractional], prefix)
    bad("mixed_wrapper_unknown", [head, frames[0], dict(frames[1], extra=True)], prefix)
    mismatch = copy.deepcopy(frames[1])
    mismatch["health"] = encode(dict(json.loads(mismatch["health"]), timestamp_us="100001"))
    bad("paired_timestamp_mismatch", [head, frames[0], mismatch], prefix)
    bad("late_error_no_checkpoint", [head, frames[0], dict(frames[1], extra=True)], mode="--guarded-evidence-checkpoint")
    bad("invalid_utf8_tail", [], prefix, payload=gates.lines([head, frames[0]]).encode() + b"\xff")
    # These finite/SPD raw values would require expensive projection and normal
    # arithmetic if admitted, but a blocked frame validates only their structure.
    ignored = copy.deepcopy(frames[1])
    object_frame = json.loads(ignored["measurement"])
    for item in object_frame["observations"]:
        item.update(point=[1e308, -1e308], covariance=[1e300, 0, 1e300])
    ignored["measurement"] = encode(object_frame)
    suppressed = native(binary, "--guarded-evidence", [head, frames[0], ignored])[-1]
    assert suppressed["analysis"]["measurement"]["tracks"] == []
    assert suppressed["analysis"]["counting"]["evidence"] == []
    assert suppressed["suppressed_track_ids"] == [1, 2]
    # A numeric failure exactly when health would become Healthy cannot commit
    # the confirming sample or allocate the new object's first segment.
    enormous = header(old, 1e308)
    pending = native(binary, "--guarded-evidence-checkpoint", [enormous] + frames[:2], count=1)[0]
    assert pending["health"]["state"]["streak"]["observations"] == 2
    invalid = copy.deepcopy(frames[2])
    obj = json.loads(invalid["measurement"])
    for item in obj["observations"]:
        item["covariance"] = [1e6, 0, 1e6]
    invalid["measurement"] = encode(obj)
    pending_prefix = native(binary, "--guarded-evidence", [enormous] + frames[:2])
    bad("first_healthy_normal_overflow", [enormous] + frames[:2] + [invalid], pending_prefix)
    bad("first_healthy_overflow_no_checkpoint", [{"resume": pending}, invalid], mode="--guarded-evidence-checkpoint")
    corrected = native(binary, "--guarded-evidence-checkpoint", [{"resume": pending}, frames[2]], count=1)[0]
    assert corrected["health"]["state"]["streak"]["observations"] == 3
    assert corrected["analysis"]["measurement"]["motion"]["tracks"][0]["segment_id"] == "1"
    assert pending["analysis"]["measurement"]["motion"]["next_segment_id"] == "1"
    saturated = copy.deepcopy(saved)
    for value in saturated["analysis"]["counting"]["state"]["counts"]:
        value.update(negative_to_positive="9223372036854775807", positive_to_negative="9223372036854775807")
    crossing = copy.deepcopy(frames[4])
    obj = json.loads(frames[3]["measurement"])
    obj["timestamp_us"] = "500000"
    for item in obj["observations"]:
        item["point"][1] = -100
    crossing["measurement"] = encode(obj)
    bad("healthy_counter_overflow", [{"resume": saturated}, crossing])
    bad("healthy_counter_overflow_no_checkpoint", [{"resume": saturated}, crossing], mode="--guarded-evidence-checkpoint")
    correction = copy.deepcopy(frames[4])
    correction["measurement"] = encode(checkpoints.frame(500000))
    continued = native(binary, "--guarded-evidence-checkpoint", [{"resume": saturated}, correction], count=1)[0]
    assert continued["analysis"]["counting"]["state"]["counts"] == saturated["analysis"]["counting"]["state"]["counts"]
    old_replace, _, replace_frames = replacement_reference.fixture()
    replace_head = header(old_replace, 3.5)
    control = json.loads(replace_frames[5]["replace_projection"])
    prior = native(binary, "--guarded-evidence", [replace_head] + replace_frames[:5])
    for name, value in [
        ("replacement_camera_required", {k: v for k, v in control.items() if k != "camera"}),
        ("replacement_not_strictly_later", dict(control, timestamp_us="400000")),
        ("replacement_unknown_inner_field", dict(control, extra=True)),
        ("replacement_invalid_matrix", dict(control, calibration=dict(control["calibration"], matrix=[0] * 9))),
    ]:
        bad(name, [replace_head] + replace_frames[:5] + [{"replace_projection": encode(value)}], prior)
    bad("replacement_mixed_payload", [replace_head] + replace_frames[:5] + [dict(replace_frames[5], health=frames[0]["health"])], prior)
    return {"rejected_cases": len(records), "cases": records, "complete_prefix_preserved": True,
        "blocked_finite_spd_objects_are_not_projected_or_evaluated": True,
        "saved_pending_health_same_timestamp_correction_reconfirms_and_uses_first_segment": True,
        "saved_saturated_counter_same_timestamp_empty_correction": True,
        "cli_retry_checks_start_from_saved_state_not_an_in_process_mutation_probe": True}


def reframe_checks(binary):
    old, _, frames = guarded.fixture(camera_reference.CAMERAS[0], "evidence-guarded-reframe")
    head = header(old, 3.5)
    baseline = native(binary, "--guarded-evidence", [head] + frames)
    cut = 4
    saved = native(binary, "--guarded-evidence-checkpoint", [head] + frames[:cut], count=1)[0]
    assert saved["health"]["state"]["streak"] is not None
    assert saved["analysis"]["measurement"]["motion"]["tracks"]
    transform = {"scale_x": .6, "scale_y": 1.3, "offset_x": -40, "offset_y": 16}
    converted = native(binary, "--reframe", [{"source": {"resume": saved["analysis"]["measurement"]}, "transform": transform}] +
        [value["measurement"] for value in frames[cut:]])
    changed = copy.deepcopy(saved)
    changed["analysis"]["measurement"] = converted[0]["resume"]
    replacement_reference.change_projection(changed["health"]["configuration"], changed["analysis"]["measurement"]["configuration"])
    assert changed["analysis"]["measurement"]["motion"] == saved["analysis"]["measurement"]["motion"]
    assert changed["analysis"]["counting"] == saved["analysis"]["counting"]
    assert changed["health"]["state"] == saved["health"]["state"]
    future = []
    sx, sy = transform["scale_x"], transform["scale_y"]
    for measured, original in zip(converted[1:], frames[cut:]):
        health_frame = json.loads(original["health"])
        for point in health_frame["observations"]:
            point["point"] = [sx * point["point"][0] + transform["offset_x"], sy * point["point"][1] + transform["offset_y"]]
            xx, xy, yy = point.get("covariance", [4, 0, 4])
            point["covariance"] = [sx * sx * xx, sx * sy * xy, sy * sy * yy]
        future.append(wrapper(measured, health_frame))
    actual = native(binary, "--guarded-evidence", [{"resume": changed}] + future)
    errors = {}
    gates.tree_close(actual, baseline[cut:], errors)
    final = native(binary, "--guarded-evidence-checkpoint", [{"resume": changed}] + future, count=1)[0]
    assert final["analysis"]["counting"]["configuration"]["sigma_multiplier"] == 3.5
    return {"status": "passed", "warm_brown_prefix_frames": cut, "continuation_frames": len(actual),
        "health_streak_metric_motion_covariance_and_evidence_preserved_at_transform": True,
        "maximum_absolute_reframe_differences": errors}


def transport_checks(binary):
    old, _, frames = guarded.fixture()
    head = header(old)
    expected = native(binary, "--guarded-evidence", [head] + frames[:2])
    for ending in [b"\n", b"\r\n"]:
        assert run(binary, "--guarded-evidence", payload=ending.join(encode(v).encode() for v in [head] + frames[:2]))[0] == expected
    saved = native(binary, "--guarded-evidence-checkpoint", [head], count=1)[0]
    padded = encode({"resume": saved}).ljust(8388619)
    assert native(binary, "--guarded-evidence-checkpoint", [padded], count=1, extra=["--max-line-bytes", "16777216"])[0] == saved
    _, overflow = run(binary, "--guarded-evidence-checkpoint", [padded + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    return {"crlf_and_unterminated_eof": "passed", "exact_resume_source_utf16_units": 8388619, "source_overflow": overflow}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/evidence-guarded.test.mjs"]
    completed = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=300)
    if completed.returncode:
        raise AssertionError("Node evidence-guarded verification failed:\n" + completed.stdout[-18000:] + completed.stderr[-2000:])
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
        "test_script_sha256": hashlib.sha256((ROOT / "web/evidence-guarded.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(), "stderr": completed.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/evidence-guarded-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "fixtures": "deterministic", "command": " ".join(shlex.quote(v) for v in [sys.executable] + sys.argv),
        "python": platform.python_version(), "numpy": np.__version__, "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "evidence_reference_sha256": hashlib.sha256(Path(evidence_reference.__file__).read_bytes()).hexdigest(),
        "health_reference_sha256": hashlib.sha256(Path(health_reference.__file__).read_bytes()).hexdigest(),
        "guarded_fixture_sha256": hashlib.sha256(Path(guarded.__file__).read_bytes()).hexdigest(),
        "projection_fixture_sha256": hashlib.sha256(Path(replacement_reference.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["independent_three_owner_composition"] = reference_checks(binary)
    result["strict_transport_and_relations"] = strict_checks(binary)
    result["warm_pixel_reframe"] = reframe_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    result["status"] = "passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "output": str(args.output), "cases": result["independent_three_owner_composition"]["cases"],
        "frames": result["independent_three_owner_composition"]["frames"], "resume_cut_points": result["independent_three_owner_composition"]["resume_cut_points"],
        "strict_rejections": result["strict_transport_and_relations"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
