#!/usr/bin/env python3
"""Check health admission against independent health and atomic transit owners.

The host stages --health and --analyze-transit-evidence separately. Suppressed
objects become an ordinary empty measurement removing all active filters. A
projection barrier starts an old health monitor, interrupts the old owner, and
changes only its canonical projection. NumPy health, Decimal normal evidence
and Fraction integer-clock pairing supply separate mathematical references.
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
import evidence_transit_analysis_verify as joint
import evidence_transit_verify as intervals
from fractions import Fraction
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
    counting = {"counting": analysis["counting"], "sigma_multiplier": multiplier}
    return source(joint.source(analysis["measurement"], joint.policy(counting)), old["health"])


def combined(analysis, health):
    return {"format": "moonground.evidence-guarded-transit", "checkpoint_version": "1", "analysis": analysis, "health": health}


def fixtures():
    values = [("replacement_" + name, header(old, 3.5), frames)
        for name, old, _, frames in replacement_reference.fixtures()]
    values.extend(("admission_" + name, header(old), frames) for name, old, _, frames in guarded.fixtures())
    values.append(pending_replacement_fixture())
    values.append(instant_gap_fixture())
    values.append(instant_gap_fixture("instant_health_gap_one_microsecond_above_2pow53", 1, 9007199254740993))
    return values


def pending_replacement_fixture():
    old, config = replacement_reference.configuration("guarded-transit-pending-barrier")
    records = [replacement_reference.observation_frame(config, time, y=y) for time, y in
        [(0, 1), (100000, 1), (200000, 1), (300000, 3)]]
    visible = json.loads(records[-1]["measurement"])
    visible["observations"] = [value for value in visible["observations"] if value["track_id"] == 1]
    records[-1]["measurement"] = encode(visible)
    calibration, camera = replacement_reference.projection(1), replacement_reference.camera()
    records.append(replacement_reference.replacement(350000, calibration, camera))
    next_config = copy.deepcopy(config)
    replacement_reference.change_projection(next_config, {"calibration": calibration, "camera": camera})
    records += [replacement_reference.observation_frame(next_config, time, y=y) for time, y in
        [(400000, 1), (500000, 1), (600000, 1), (700000, 3), (800000, 7)]]
    return "replacement_cancels_pending_and_hidden_segments", header(old, 3.5), records


def instant_gap_fixture(name="instant_health_gap_boundary_continues_motion", gap=100000, start=0):
    old, config = replacement_reference.configuration(name, immediate=True)
    config["health"]["max_gap_us"] = str(gap)
    old["health"] = encode(config)
    records = [replacement_reference.observation_frame(config, start + gap * index, y=1) for index in range(3)]
    return name, header(old, 3.5), records


def host_reference(binary, head, frames):
    analysis_source = json.loads(head["analysis"])
    analysis = native(binary, "--analyze-transit-evidence-checkpoint", [analysis_source], count=1)[0]
    health = native(binary, "--health-checkpoint", [head["health"]], count=1)[0]
    health_oracle = health_reference.Oracle(health["configuration"])
    counter_config = analysis["transit"]["counting"]["configuration"]
    gate_oracle = evidence_reference.Oracle({"counting": encode(counter_config["counting"]),
        "sigma_multiplier": counter_config["sigma_multiplier"]}, counter_config["counting"])
    pairing = intervals.PairOracle(json.loads(analysis_source["transit"]))
    snapshots = [combined(analysis, health)]
    outputs, absolute, relative = [], {}, {}
    elapsed_errors = {"maximum_absolute_error_us": 0, "maximum_relative_error": 0}
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
            removed=sorted(item["track_id"] for item in analysis["measurement"]["motion"]["tracks"]))
        analysis_frame = native(binary, "--analyze-transit-evidence", [{"resume": analysis}, effective], count=1)[0]
        measured, counted = analysis_frame["measurement"], analysis_frame["transit"]
        previous = copy.deepcopy(gate_oracle.tracks)
        evidence_reference.compare_frame(counted["counting"], gate_oracle.update(measured), absolute, relative)
        wanted = pairing.update_evidence(measured, counted["counting"], previous)
        gates.tree_close(counted, wanted, absolute)
        for passage in counted["passages"]:
            elapsed = intervals.transit.exact_time(passage["exit"]) - intervals.transit.exact_time(passage["entry"])
            assert int(passage["elapsed_lower_us"]) <= elapsed <= int(passage["elapsed_upper_us"])
            difference = abs(Fraction.from_float(float(passage["estimated_elapsed_us"])) - elapsed)
            assert difference <= elapsed * Fraction(1, 2 ** 49)
            elapsed_errors["maximum_absolute_error_us"] = max(elapsed_errors["maximum_absolute_error_us"], float(difference))
            elapsed_errors["maximum_relative_error"] = max(elapsed_errors["maximum_relative_error"], float(difference / elapsed))
        next_analysis = native(binary, "--analyze-transit-evidence-checkpoint", [{"resume": analysis}, effective], count=1)[0]
        assert next_analysis["transit"]["pending"] == pairing.pending_documents()
        next_health = native(binary, "--health-checkpoint", [health_source, landmark_frame], count=1)[0]
        if replacing:
            replacement_reference.change_projection(next_analysis["measurement"]["configuration"], next_health["configuration"])
        outputs.append({"schema_version": "0.1.0", "kind": "evidence_guarded_transit_projection_replaced" if replacing else "evidence_guarded_transit_frame",
            "decision": "allowed" if allowed else "blocked", "suppressed_track_ids": [] if allowed or replacing else
                sorted(item["track_id"] for item in object_frame["observations"]), "health": report, "analysis": analysis_frame})
        analysis, health = next_analysis, next_health
        snapshots.append(combined(analysis, health))
    return outputs, snapshots, absolute, relative, elapsed_errors


def reference_checks(binary):
    records, absolute, relative = [], {}, {}
    total = cuts = allowed = blocked = barriers = events = evidence_count = closed = passages = cancelled = 0
    elapsed_errors = {"maximum_absolute_error_us": 0, "maximum_relative_error": 0}
    for name, head, frames in fixtures():
        expected, snapshots, numeric, scaled, elapsed = host_reference(binary, head, frames)
        actual = native(binary, "--guarded-transit-evidence", [head] + frames)
        assert actual == expected, name + ": differs from independent health and joint-analysis owners"
        if name.startswith("instant_health_gap"):
            assert all(value["decision"] == "allowed" and value["health"]["status"] == "healthy" for value in actual)
            assert snapshots[-1]["analysis"]["measurement"]["motion"]["tracks"][0]["first_timestamp_us"] == json.loads(frames[0]["measurement"])["timestamp_us"]
            assert snapshots[-1]["health"]["state"]["streak"]["since_us"] == json.loads(frames[-1]["measurement"])["timestamp_us"]
        if name == "replacement_cancels_pending_and_hidden_segments":
            assert actual[3]["analysis"]["transit"]["pending_count"] == 1
            assert len(actual[4]["analysis"]["measurement"]["closed_segment_ids"]) == 2
            assert actual[4]["analysis"]["transit"]["cancellations"][0]["reason"] == "discontinuity"
        for key, value in elapsed.items():
            elapsed_errors[key] = max(elapsed_errors[key], value)
        for key, value in numeric.items():
            absolute[key] = max(absolute.get(key, 0), value)
        for key, value in scaled.items():
            relative[key] = max(relative.get(key, 0), value)
        for cut in range(len(frames) + 1):
            saved = native(binary, "--guarded-transit-evidence-checkpoint", [head] + frames[:cut], count=1)[0]
            assert saved == snapshots[cut], (name, cut, "full checkpoint differs")
            for resume in [{"resume": saved}, source({"resume": saved["analysis"]}, {"resume": saved["health"]})]:
                assert native(binary, "--guarded-transit-evidence", [resume] + frames[cut:]) == actual[cut:], (name, cut)
                assert native(binary, "--guarded-transit-evidence-checkpoint", [resume] + frames[cut:], count=1)[0] == snapshots[-1], (name, cut)
            cuts += 1
        for index, value in enumerate(actual):
            is_allowed = value["decision"] == "allowed"
            allowed += is_allowed
            blocked += not is_allowed
            measured = value["analysis"]["measurement"]
            counted = value["analysis"]["transit"]["counting"]
            events += len(counted["counting"]["crossings"])
            evidence_count += len(counted["evidence"])
            closed += len(measured["closed_segment_ids"])
            passages += len(value["analysis"]["transit"]["passages"])
            cancelled += len(value["analysis"]["transit"]["cancellations"])
            if not is_allowed:
                assert measured["tracks"] == [] and counted["evidence"] == []
                assert value["analysis"]["transit"]["pending_count"] == 0
            if value["kind"] == "evidence_guarded_transit_projection_replaced":
                barriers += 1
                before, after = snapshots[index], snapshots[index + 1]
                assert after["health"]["state"]["streak"] is None
                assert after["analysis"]["measurement"]["motion"]["tracks"] == []
                assert after["analysis"]["transit"]["counting"]["state"]["tracks"] == []
                assert before["analysis"]["transit"]["counting"]["configuration"] == after["analysis"]["transit"]["counting"]["configuration"]
                assert before["analysis"]["transit"]["counting"]["state"]["counts"] == after["analysis"]["transit"]["counting"]["state"]["counts"]
                assert before["analysis"]["measurement"]["motion"]["next_segment_id"] == after["analysis"]["measurement"]["motion"]["next_segment_id"]
                assert after["analysis"]["transit"]["pending"] == []
                for key in ["sections", "max_duration_us", "counts"]:
                    assert before["analysis"]["transit"][key] == after["analysis"]["transit"][key]
        total += len(frames)
        records.append({"name": name, "frames": len(frames), "checkpoint_sha256": hashlib.sha256(encode(snapshots[-1]).encode()).hexdigest()})
    assert allowed and blocked and barriers and closed and events
    return {"cases": len(records), "frames": total, "allowed": allowed, "blocked": blocked,
        "replacement_barriers": barriers, "closed_segments": closed, "evidence_records": evidence_count, "crossings": events,
        "passages": passages, "cancellations": cancelled, "elapsed_errors_against_exact_fraction_interpolation": elapsed_errors,
        "resume_cut_points": cuts, "resume_source_forms": 2,
        "full_health_streak_motion_covariance_paths_counts_anchor_covariances_and_projection_caches_equal": True,
        "maximum_absolute_oracle_errors": absolute, "maximum_relative_or_scaled_evidence_errors": relative, "records": records}


def strict_checks(binary):
    old, _, frames = guarded.fixture()
    head = header(old)
    prefix = native(binary, "--guarded-transit-evidence", [head, frames[0]])
    saved = native(binary, "--guarded-transit-evidence-checkpoint", [head] + frames[:4], count=1)[0]
    records = []

    def bad(name, values, expected=(), mode="--guarded-transit-evidence", payload=None, extra=()):
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
    transit = json.loads(analysis["transit"])
    evidence = json.loads(transit["counting"])
    policy = json.loads(evidence["counting"])
    policy["max_tracks"] = 15
    evidence["counting"] = encode(policy)
    transit["counting"] = encode(evidence)
    analysis["transit"] = encode(transit)
    smaller["analysis"] = encode(analysis)
    bad("counter_capacity_cannot_cover_motion", [smaller])
    ground = {"session_id": "evidence-guarded-ground", "mode": "ground", "motion": {"max_tracks": 8}}
    ground_policy = {"counting": encode(gates.configuration(name=ground["session_id"])), "sigma_multiplier": 2}
    bad("ground_measurement_forbidden", [source(joint.source(ground, joint.policy(ground_policy)), old["health"])])
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
        ("missing_current_evidence_track", lambda v: v["analysis"]["transit"]["counting"]["state"].update(tracks=[])),
        ("missing_effective_sigma", lambda v: v["analysis"]["transit"]["counting"]["configuration"].pop("sigma_multiplier")),
        ("missing_effective_deadband", lambda v: v["analysis"]["transit"]["counting"]["configuration"]["counting"]["gates"][0].pop("deadband_m")),
        ("missing_effective_health_threshold", lambda v: v["health"]["configuration"]["health"].pop("rms_limit_m")),
    ]:
        invalid = copy.deepcopy(saved)
        mutate(invalid)
        bad(name, [{"resume": invalid}])
    brown_old, _, brown_frames = guarded.fixture(camera_reference.CAMERAS[0], "evidence-guarded-camera")
    brown = native(binary, "--guarded-transit-evidence-checkpoint", [header(brown_old)] + brown_frames[:4], count=1)[0]
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
    bad("late_error_no_checkpoint", [head, frames[0], dict(frames[1], extra=True)], mode="--guarded-transit-evidence-checkpoint")
    bad("invalid_utf8_tail", [], prefix, payload=gates.lines([head, frames[0]]).encode() + b"\xff")
    # These finite/SPD raw values would require expensive projection and normal
    # arithmetic if admitted, but a blocked frame validates only their structure.
    ignored = copy.deepcopy(frames[1])
    object_frame = json.loads(ignored["measurement"])
    for item in object_frame["observations"]:
        item.update(point=[1e308, -1e308], covariance=[1e300, 0, 1e300])
    ignored["measurement"] = encode(object_frame)
    suppressed = native(binary, "--guarded-transit-evidence", [head, frames[0], ignored])[-1]
    assert suppressed["analysis"]["measurement"]["tracks"] == []
    assert suppressed["analysis"]["transit"]["counting"]["evidence"] == []
    assert suppressed["suppressed_track_ids"] == [1, 2]
    # A numeric failure exactly when health would become Healthy cannot commit
    # the confirming sample or allocate the new object's first segment.
    enormous = header(old, 1e308)
    pending = native(binary, "--guarded-transit-evidence-checkpoint", [enormous] + frames[:2], count=1)[0]
    assert pending["health"]["state"]["streak"]["observations"] == 2
    invalid = copy.deepcopy(frames[2])
    obj = json.loads(invalid["measurement"])
    for item in obj["observations"]:
        item["covariance"] = [1e6, 0, 1e6]
    invalid["measurement"] = encode(obj)
    pending_prefix = native(binary, "--guarded-transit-evidence", [enormous] + frames[:2])
    bad("first_healthy_normal_overflow", [enormous] + frames[:2] + [invalid], pending_prefix)
    bad("first_healthy_overflow_no_checkpoint", [{"resume": pending}, invalid], mode="--guarded-transit-evidence-checkpoint")
    corrected = native(binary, "--guarded-transit-evidence-checkpoint", [{"resume": pending}, frames[2]], count=1)[0]
    assert corrected["health"]["state"]["streak"]["observations"] == 3
    assert corrected["analysis"]["measurement"]["motion"]["tracks"][0]["segment_id"] == "1"
    assert pending["analysis"]["measurement"]["motion"]["next_segment_id"] == "1"
    saturated = copy.deepcopy(saved)
    for value in saturated["analysis"]["transit"]["counting"]["state"]["counts"]:
        value.update(negative_to_positive="9223372036854775807", positive_to_negative="9223372036854775807")
    crossing = copy.deepcopy(frames[4])
    obj = json.loads(frames[3]["measurement"])
    obj["timestamp_us"] = "500000"
    for item in obj["observations"]:
        item["point"][1] = -100
    crossing["measurement"] = encode(obj)
    bad("healthy_counter_overflow", [{"resume": saturated}, crossing])
    bad("healthy_counter_overflow_no_checkpoint", [{"resume": saturated}, crossing], mode="--guarded-transit-evidence-checkpoint")
    correction = copy.deepcopy(frames[4])
    correction["measurement"] = encode(checkpoints.frame(500000))
    continued = native(binary, "--guarded-transit-evidence-checkpoint", [{"resume": saturated}, correction], count=1)[0]
    assert continued["analysis"]["transit"]["counting"]["state"]["counts"] == saturated["analysis"]["transit"]["counting"]["state"]["counts"]
    old_replace, _, replace_frames = replacement_reference.fixture()
    replace_head = header(old_replace, 3.5)
    control = json.loads(replace_frames[5]["replace_projection"])
    prior = native(binary, "--guarded-transit-evidence", [replace_head] + replace_frames[:5])
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
    baseline = native(binary, "--guarded-transit-evidence", [head] + frames)
    cut = 4
    saved = native(binary, "--guarded-transit-evidence-checkpoint", [head] + frames[:cut], count=1)[0]
    assert saved["health"]["state"]["streak"] is not None
    assert saved["analysis"]["measurement"]["motion"]["tracks"]
    transform = {"scale_x": .6, "scale_y": 1.3, "offset_x": -40, "offset_y": 16}
    converted = native(binary, "--reframe", [{"source": {"resume": saved["analysis"]["measurement"]}, "transform": transform}] +
        [value["measurement"] for value in frames[cut:]])
    changed = copy.deepcopy(saved)
    changed["analysis"]["measurement"] = converted[0]["resume"]
    replacement_reference.change_projection(changed["health"]["configuration"], changed["analysis"]["measurement"]["configuration"])
    assert changed["analysis"]["measurement"]["motion"] == saved["analysis"]["measurement"]["motion"]
    assert changed["analysis"]["transit"] == saved["analysis"]["transit"]
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
    actual = native(binary, "--guarded-transit-evidence", [{"resume": changed}] + future)
    errors = {}
    gates.tree_close(actual, baseline[cut:], errors)
    final = native(binary, "--guarded-transit-evidence-checkpoint", [{"resume": changed}] + future, count=1)[0]
    assert final["analysis"]["transit"]["counting"]["configuration"]["sigma_multiplier"] == 3.5
    return {"status": "passed", "warm_brown_prefix_frames": cut, "continuation_frames": len(actual),
        "health_streak_metric_motion_covariance_and_evidence_preserved_at_transform": True,
        "maximum_absolute_reframe_differences": errors}


def health_gap_relation_checks(binary):
    _, head, frames = instant_gap_fixture()
    saved = native(binary, "--guarded-transit-evidence-checkpoint", [head] + frames[:2], count=1)[0]
    cases = []

    def impossible(name, checkpoint):
        # Each existing owner accepts its own checkpoint. Only the shared
        # observed Healthy timeline makes their combination impossible.
        native(binary, "--analyze-transit-evidence-checkpoint", [{"resume": checkpoint["analysis"]}], count=1)
        native(binary, "--health-checkpoint", [{"resume": checkpoint["health"]}], count=1)
        _, detail = run(binary, "--guarded-transit-evidence-checkpoint", [{"resume": checkpoint}], status=2, count=0)
        cases.append(dict(name=name, **detail))

    first = copy.deepcopy(saved)
    first["analysis"]["measurement"]["motion"]["tracks"][0]["first_timestamp_us"] = "99999"
    impossible("first_accepted_inside_forbidden_pre_streak_window", first)
    strict = copy.deepcopy(saved)
    strict["health"]["configuration"]["health"]["max_gap_us"] = "500000"
    impossible("no_gap_exception_when_health_gap_equals_motion_gap", strict)
    definition = json.loads(head["analysis"])
    config = json.loads(head["health"])
    first_object = json.loads(frames[0]["measurement"])
    hidden_objects = [first_object, dict(copy.deepcopy(first_object), timestamp_us="99999"), checkpoints.frame(100000)]
    hidden = combined(native(binary, "--analyze-transit-evidence-checkpoint", [definition] + hidden_objects, count=1)[0], saved["health"])
    impossible("hidden_last_accepted_inside_forbidden_window", hidden)
    anchor_source = copy.deepcopy(definition)
    transit = json.loads(anchor_source["transit"])
    evidence = json.loads(transit["counting"])
    gate_config = json.loads(evidence["counting"])
    for key in ["start_m", "end_m"]:
        gate_config["gates"][0][key][1] = 1.5
    evidence["counting"] = encode(gate_config)
    transit["counting"] = encode(evidence)
    anchor_source["transit"] = encode(transit)
    anchor_objects = [json.loads(replacement_reference.observation_frame(config, time, y=y)["measurement"])
        for time, y in [(0, 1), (99999, 1), (100000, 2)]]
    anchored = combined(native(binary, "--analyze-transit-evidence-checkpoint", [anchor_source] + anchor_objects, count=1)[0], saved["health"])
    assert anchored["analysis"]["transit"]["counting"]["state"]["tracks"][0]["anchors"][0]["timestamp_us"] == "99999"
    impossible("historical_gate_anchor_inside_forbidden_window", anchored)
    pending_objects = [json.loads(replacement_reference.observation_frame(config, time, y=y)["measurement"])
        for time, y in [(0, 1), (150000, 3), (200000, 4)]]
    health_at_200000 = native(binary, "--guarded-transit-evidence-checkpoint", [head] + frames, count=1)[0]["health"]
    pending = combined(native(binary, "--analyze-transit-evidence-checkpoint", [definition] + pending_objects, count=1)[0], health_at_200000)
    assert pending["analysis"]["transit"]["pending"][0]["entry"]["to_timestamp_us"] == "150000"
    impossible("historical_pending_confirmation_inside_forbidden_window", pending)
    return {"independently_valid_but_incompatible_checkpoints_rejected": len(cases), "cases": cases,
        "instant_first_confirmation_remains_allowed": True,
        "healthy_gap_reconfirmation_preserves_reachable_motion_at_exact_gap_boundary": True,
        "hidden_tracks_anchors_and_pending_witness_times_checked": True}


def transport_checks(binary):
    old, _, frames = guarded.fixture()
    head = header(old)
    expected = native(binary, "--guarded-transit-evidence", [head] + frames[:2])
    for ending in [b"\n", b"\r\n"]:
        assert run(binary, "--guarded-transit-evidence", payload=ending.join(encode(v).encode() for v in [head] + frames[:2]))[0] == expected
    saved = native(binary, "--guarded-transit-evidence-checkpoint", [head], count=1)[0]
    padded = encode({"resume": saved}).ljust(8388619)
    assert native(binary, "--guarded-transit-evidence-checkpoint", [padded], count=1, extra=["--max-line-bytes", "16777216"])[0] == saved
    _, overflow = run(binary, "--guarded-transit-evidence-checkpoint", [padded + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    return {"crlf_and_unterminated_eof": "passed", "exact_resume_source_utf16_units": 8388619, "source_overflow": overflow}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/evidence-guarded-transit.test.mjs"]
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
        "test_script_sha256": hashlib.sha256((ROOT / "web/evidence-guarded-transit.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(), "stderr": completed.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/evidence-guarded-transit-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "fixtures": "deterministic", "command": " ".join(shlex.quote(v) for v in [sys.executable] + sys.argv),
        "python": platform.python_version(), "numpy": np.__version__, "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "evidence_reference_sha256": hashlib.sha256(Path(evidence_reference.__file__).read_bytes()).hexdigest(),
        "transit_reference_sha256": hashlib.sha256(Path(intervals.__file__).read_bytes()).hexdigest(),
        "health_reference_sha256": hashlib.sha256(Path(health_reference.__file__).read_bytes()).hexdigest(),
        "guarded_fixture_sha256": hashlib.sha256(Path(guarded.__file__).read_bytes()).hexdigest(),
        "projection_fixture_sha256": hashlib.sha256(Path(replacement_reference.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["independent_health_and_joint_analysis_composition"] = reference_checks(binary)
    result["strict_transport_and_relations"] = strict_checks(binary)
    result["instant_health_gap_relations"] = health_gap_relation_checks(binary)
    result["warm_pixel_reframe"] = reframe_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    result["status"] = "passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "output": str(args.output), "cases": result["independent_health_and_joint_analysis_composition"]["cases"],
        "frames": result["independent_health_and_joint_analysis_composition"]["frames"], "resume_cut_points": result["independent_health_and_joint_analysis_composition"]["resume_cut_points"],
        "strict_rejections": result["strict_transport_and_relations"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
