#!/usr/bin/env python3
"""Check atomic measurement/transit against independent existing owners.

The host first runs the old measurement CLI and then --transit-evidence.
Decimal normal bands, NumPy finite chords and Fraction integer-clock pairing
remain independent of the new owner. No production transaction code is copied.
"""

import argparse
import copy
from fractions import Fraction
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

import checkpoint_verify as checkpoints
import evidence_analysis_verify as analysis
import evidence_transit_verify as intervals
import evidence_verify as evidence
import gates_verify as gates
import transit_verify as timing
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
STREAM = "--analyze-transit-evidence"
CHECKPOINT = "--analyze-transit-evidence-checkpoint"
encode, native, run = gates.encode, gates.native, gates.execute


def source(measurement, transit):
    return {"measurement": measurement if isinstance(measurement, str) else encode(measurement),
        "transit": transit if isinstance(transit, str) else encode(transit)}


def combined(measurement, transit):
    return {"format": "moonground.evidence-transit-analysis", "checkpoint_version": "1",
        "measurement": measurement, "transit": transit}


def policy(counter):
    counter = copy.deepcopy(counter)
    config = json.loads(counter["counting"])
    if len(config["gates"]) == 1:
        extra = copy.deepcopy(config["gates"][0])
        extra["gate_id"] = "interval-exit"
        a, b = np.asarray(extra["start_m"]), np.asarray(extra["end_m"])
        tangent = b - a
        normal = np.array([-tangent[1], tangent[0]]) / np.linalg.norm(tangent)
        extra["start_m"] = (a + normal * .5).tolist()
        extra["end_m"] = (b + normal * .5).tolist()
        config["gates"].append(extra)
    counter["counting"] = encode(config)
    first, last = [item["gate_id"] for item in config["gates"][:2]]
    return {"counting": encode(counter), "sections": [timing.section("forward", first, last),
        timing.section("backward", last, first, "positive_to_negative")], "max_duration_us": "300000000"}


def journey_fixture(name="evidence-transit-analysis-history", times=None):
    measurement = {"session_id": name, "mode": "ground", "diagnostics": True,
        "motion": {"gate": 1e12, "q": 1e6, "initial_velocity_std": 1000,
            "max_gap_us": "500000", "max_tracks": 10, "min_observations": 2, "min_span_us": "0"}}
    transit = intervals.configuration(name)
    inner = intervals.evidence_source(transit)
    config = json.loads(inner["counting"])
    config["max_tracks"] = 10
    inner["counting"] = encode(config)
    transit["counting"] = encode(inner)
    frames = [checkpoints.frame(time, [checkpoints.observation(1, [0, y], [.01, 0, .01])])
        for time, y in zip(times or [0, 100000, 200000, 300000], [-1, 1, 2, 4])]
    return measurement, transit, frames


def fixtures():
    values = [(name, measurement, policy(counting), frames) for name, measurement, counting, frames in analysis.fixtures()]
    values.append(("confirmed_entry_then_exit",) + journey_fixture())
    measurement, transit, frames = journey_fixture("evidence-transit-analysis-delayed")
    frames = [frames[0], copy.deepcopy(frames[1]), frames[-1]]
    frames[1]["observations"][0]["covariance"] = [.36, 0, .36]
    values.append(("different_covariance_delays_same_frame_different_chords", measurement, transit, frames))
    for name, clock in [("above_2pow53", 9007199254740993), ("int64_max", 9223372036854775804)]:
        measurement, transit, frames = journey_fixture("transit-analysis-" + name, [clock + index for index in range(4)])
        measurement["motion"]["initial_velocity_std"] = 1e7
        values.append((name + "_one_microsecond_intervals", measurement, transit, frames))
    return values


def expected(binary, measurement, transit, frames):
    measured = native(binary, "--stream", [measurement] + frames)
    counted = native(binary, "--transit-evidence", [transit] + measured)
    outputs = [{"schema_version": "0.1.0", "kind": "evidence_transit_analysis_frame",
        "measurement": left, "transit": right} for left, right in zip(measured, counted)]
    saved = combined(native(binary, "--checkpoint", [measurement] + frames, count=1)[0],
        native(binary, "--transit-evidence-checkpoint", [transit] + measured, count=1)[0])
    return outputs, saved


def oracle_checks(transit, outputs, final):
    inner = intervals.evidence_source(transit)
    normal = evidence.Oracle(inner, final["transit"]["counting"]["configuration"]["counting"])
    pairing = intervals.PairOracle(transit)
    absolute, scaled, errors = {}, {}, {}
    elapsed_errors = {"maximum_absolute_error_us": 0, "maximum_relative_error": 0}
    for value in outputs:
        measured, counted = value["measurement"], value["transit"]
        previous = copy.deepcopy(normal.tracks)
        evidence.compare_frame(counted["counting"], normal.update(measured), absolute, scaled)
        wanted = pairing.update_evidence(measured, counted["counting"], previous)
        gates.tree_close(counted, wanted, errors)
        for passage in counted["passages"]:
            elapsed = timing.exact_time(passage["exit"]) - timing.exact_time(passage["entry"])
            assert int(passage["elapsed_lower_us"]) <= elapsed <= int(passage["elapsed_upper_us"])
            error = abs(Fraction.from_float(float(passage["estimated_elapsed_us"])) - elapsed)
            assert error <= elapsed * Fraction(1, 2 ** 49)
            elapsed_errors["maximum_absolute_error_us"] = max(elapsed_errors["maximum_absolute_error_us"], float(error))
            elapsed_errors["maximum_relative_error"] = max(elapsed_errors["maximum_relative_error"], float(error / elapsed))
    assert final["transit"]["pending"] == pairing.pending_documents()
    return {"maximum_absolute_normal_errors": absolute, "maximum_relative_or_scaled_normal_errors": scaled,
        "maximum_absolute_pairing_errors": errors, "elapsed_errors_against_exact_fraction_interpolation": elapsed_errors}


def reference_checks(binary):
    records, statuses = [], set()
    totals = {key: 0 for key in ["frames", "passages", "crossings", "evidence_records", "resume_cut_points"]}
    for name, measurement, transit, frames in fixtures():
        header = source(measurement, transit)
        baseline, final = expected(binary, measurement, transit, frames)
        actual = native(binary, STREAM, [header] + frames)
        assert actual == baseline, name + ": outputs differ from existing independent owners"
        assert native(binary, CHECKPOINT, [header] + frames, count=1)[0] == final, name
        if name.endswith("one_microsecond_intervals"):
            assert actual[-1]["transit"]["passages"], name + ": fixture failed to cross both channels"
            assert actual[-1]["transit"]["passages"][0]["elapsed_lower_us"] == "1"
            assert actual[-1]["transit"]["passages"][0]["elapsed_upper_us"] == "3"
        if name == "different_covariance_delays_same_frame_different_chords":
            assert not actual[-1]["transit"]["passages"]
            assert actual[-1]["transit"]["cancellations"][0]["reason"] == "ambiguous_order"
        result = oracle_checks(transit, actual, final)
        for value in actual:
            statuses.update(track["status"] for track in value["measurement"]["tracks"])
            totals["passages"] += len(value["transit"]["passages"])
            totals["crossings"] += len(value["transit"]["counting"]["counting"]["crossings"])
            totals["evidence_records"] += len(value["transit"]["counting"]["evidence"])
        for cut in range(len(frames) + 1):
            saved = native(binary, CHECKPOINT, [header] + frames[:cut], count=1)[0]
            assert saved == expected(binary, measurement, transit, frames[:cut])[1], (name, cut)
            for resume in [{"resume": saved}, source({"resume": saved["measurement"]}, {"resume": saved["transit"]})]:
                assert native(binary, STREAM, [resume] + frames[cut:]) == actual[cut:], (name, cut)
                assert native(binary, CHECKPOINT, [resume] + frames[cut:], count=1)[0] == final, (name, cut)
            totals["resume_cut_points"] += 1
        totals["frames"] += len(frames)
        records.append(dict(name=name, frames=len(frames), **result,
            checkpoint_sha256=hashlib.sha256(encode(final).encode()).hexdigest()))
    assert {"initializing", "ready", "uncertain", "rejected_innovation", "rejected_projection", "numerical_failure"} <= statuses
    assert totals["passages"] > 0
    return dict(cases=len(records), **totals, resume_source_forms=2, statuses=sorted(statuses),
        full_motion_state_covariance_paths_evidence_pending_covariances_and_counts_equal=True, records=records)


def rejection_checks(binary):
    measurement, transit, frames = journey_fixture("transit-analysis-strict")
    head = source(measurement, transit)
    initial = native(binary, CHECKPOINT, [head, frames[0]], count=1)[0]
    saved = native(binary, CHECKPOINT, [head] + frames[:3], count=1)[0]
    assert saved["transit"]["pending"]
    prefix = native(binary, STREAM, [head, frames[0]])
    records = []

    def bad(name, values, expected_prefix=(), mode=STREAM, payload=None, extra=()):
        try:
            actual, detail = run(binary, mode, values, status=2, payload=payload, extra=extra)
        except AssertionError as error:
            raise AssertionError(name + ": " + str(error)) from error
        assert actual == list(expected_prefix), name + ": exposed checkpoint/lost complete prefix"
        records.append(dict(name=name, **detail))

    for name, value in [
        ("missing_transit_source", {"measurement": head["measurement"]}),
        ("source_object_not_raw", dict(head, transit=transit)),
        ("unknown_source_key", dict(head, extra=True)),
        ("duplicate_source_key", '{"measurement":"bad",' + encode(head)[1:]),
        ("measurement_only_started", source({"resume": initial["measurement"]}, transit)),
        ("transit_only_started", source(measurement, {"resume": initial["transit"]})),
    ]:
        bad(name, [value])
    fractional = copy.deepcopy(transit)
    fractional_inner = intervals.evidence_source(fractional)
    fractional_inner["counting"] = fractional_inner["counting"].replace('"max_tracks":10', '"max_tracks":10.0000000000000001')
    fractional["counting"] = encode(fractional_inner)
    bad("raw_fractional_nested_capacity", [source(measurement, fractional)])
    for name, mutate in [
        ("wrong_joint_format", lambda v: v.update(format="moonground.evidence-analysis")),
        ("wrong_joint_version", lambda v: v.update(checkpoint_version="2")),
        ("unknown_joint_key", lambda v: v.update(extra=True)),
        ("session_mismatch", lambda v: v["transit"]["counting"]["configuration"]["counting"].update(session_id="other")),
        ("watermark_mismatch", lambda v: v["transit"]["counting"]["state"].update(last_timestamp_us="200001")),
        ("accepted_gate_track_missing", lambda v: v["transit"]["counting"]["state"].update(tracks=[])),
        ("segment_mismatch", lambda v: v["transit"]["counting"]["state"]["tracks"][0].update(segment_id="2")),
        ("current_anchor_point_mismatch", lambda v: v["transit"]["counting"]["state"]["tracks"][0]["anchors"][0].update(point_m=[.25, 2])),
        ("current_anchor_covariance_mismatch", lambda v: v["transit"]["counting"]["state"]["tracks"][0]["anchors"][0].update(covariance=[.02, .002, .02])),
        ("forged_quality_eligible_track", lambda v: v["transit"]["counting"]["configuration"]["counting"].update(max_position_std_m=.001)),
        ("missing_effective_sigma", lambda v: v["transit"]["counting"]["configuration"].pop("sigma_multiplier")),
        ("missing_effective_gap", lambda v: v["transit"]["counting"]["configuration"]["counting"].pop("max_gap_us")),
        ("missing_effective_capacity", lambda v: v["transit"]["counting"]["configuration"]["counting"].pop("max_tracks")),
        ("missing_effective_deadband", lambda v: v["transit"]["counting"]["configuration"]["counting"]["gates"][0].pop("deadband_m")),
        ("missing_pending_covariance", lambda v: v["transit"]["pending"][0].pop("from_covariance")),
        ("pending_from_before_segment", lambda v: v["measurement"]["motion"]["tracks"][0].update(first_timestamp_us="50000")),
        ("known_three_timestamps_but_count_two", lambda v: v["measurement"]["motion"]["tracks"][0].update(accepted_count=2)),
    ]:
        invalid = copy.deepcopy(saved)
        mutate(invalid)
        if name in ["pending_from_before_segment", "known_three_timestamps_but_count_two"]:
            native(binary, "--checkpoint", [{"resume": invalid["measurement"]}], count=1)
            native(binary, "--transit-evidence-checkpoint", [{"resume": invalid["transit"]}], count=1)
        bad(name, [{"resume": invalid}])
    # Recompute a locally valid historical mean chord through the old counter.
    wrong_first = copy.deepcopy(saved)
    entry = wrong_first["transit"]["pending"][0]["entry"]
    old_config = copy.deepcopy(saved["transit"]["counting"]["configuration"]["counting"])
    old_config["gates"] = [old_config["gates"][0]]
    pair = [gates.measurement(int(entry["from_timestamp_us"]), [gates.track(1, [.25, -1], int(entry["from_timestamp_us"]))], name=measurement["session_id"]),
        gates.measurement(int(entry["to_timestamp_us"]), [gates.track(1, entry["to_position_m"], int(entry["to_timestamp_us"]))], name=measurement["session_id"])]
    wrong_first["transit"]["pending"][0]["entry"] = native(binary, "--count", [old_config] + pair)[1]["crossings"][0]
    native(binary, "--transit-evidence-checkpoint", [{"resume": wrong_first["transit"]}], count=1)
    bad("pending_first_point_differs_from_first_filtered", [{"resume": wrong_first}])
    # The exit gate retains the entry-confirmation observation while a later
    # wider covariance confirms entry-side but leaves exit-side unconfirmed.
    witness_frames = copy.deepcopy(frames[:3])
    witness_frames[-1]["observations"][0]["covariance"] = [.36, 0, .36]
    witnesses = native(binary, CHECKPOINT, [head] + witness_frames, count=1)[0]
    witness = witnesses["transit"]["pending"][0]
    assert witnesses["transit"]["counting"]["state"]["tracks"][0]["anchors"][1]["timestamp_us"] == witness["entry"]["to_timestamp_us"]
    witness["to_covariance"] = [.04, 0, .04]
    native(binary, "--transit-evidence-checkpoint", [{"resume": witnesses["transit"]}], count=1)
    bad("same_time_cross_gate_witness_covariance_conflict", [{"resume": witnesses}])
    # No original first covariance is retained by motion. A stable, consistent
    # historical witness may differ from the present P without authentication.
    historical = copy.deepcopy(saved)
    historical["transit"]["pending"][0]["from_covariance"] = [.02, 0, .02]
    assert native(binary, CHECKPOINT, [{"resume": historical}], count=1)[0] == historical
    asymmetric = copy.deepcopy(saved)
    asymmetric["measurement"]["motion"]["tracks"][0]["covariance"][4] = 1e-14
    native(binary, "--checkpoint", [{"resume": asymmetric["measurement"]}], count=1)
    assert native(binary, CHECKPOINT, [{"resume": asymmetric}], count=1)[0] == asymmetric
    averaged = copy.deepcopy(asymmetric)
    averaged["transit"]["counting"]["state"]["tracks"][0]["anchors"][0]["covariance"][1] = 5e-15
    bad("anchor_covariance_averaged_with_lower_motion_block", [{"resume": averaged}])
    for name, invalid in [
        ("raw_fractional_id", encode(frames[1]).replace('"track_id":1', '"track_id":1.0000000000000001')),
        ("duplicate_raw_frame", '{"timestamp_us":"100000",' + encode(frames[1])[1:]),
        ("same_timestamp", frames[0]), ("unknown_frame_key", dict(frames[1], extra=True)),
        ("duplicate_observation", dict(frames[1], observations=frames[1]["observations"] * 2)),
        ("lost_observation_conflict", dict(frames[1], lost=[1])),
    ]:
        bad(name, [head, frames[0], invalid], prefix)
    bad("late_failure_no_checkpoint", [head, frames[0], dict(frames[1], extra=True)], mode=CHECKPOINT)
    bad("invalid_utf8_tail", [], prefix, payload=gates.lines([head, frames[0]]).encode() + b"\xff")
    bad("missing_header", [], payload=b"")
    saturated = copy.deepcopy(initial)
    saturated["transit"]["counting"]["state"]["counts"][0]["negative_to_positive"] = "9223372036854775807"
    late = copy.deepcopy(frames[1])
    late["observations"].append(checkpoints.observation(2, [0, -1], [.01, 0, .01]))
    bad("gate_overflow_after_motion_candidate", [{"resume": saturated}, late])
    bad("gate_overflow_no_checkpoint", [{"resume": saturated}, late], mode=CHECKPOINT)
    correction = copy.deepcopy(late)
    correction["observations"][0]["point"] = [0, -2]
    retried = native(binary, CHECKPOINT, [{"resume": saturated}, correction], count=1)[0]
    assert retried["measurement"]["motion"]["next_segment_id"] == "3"
    assert [item["segment_id"] for item in retried["measurement"]["motion"]["tracks"]] == ["1", "2"]
    assert retried["transit"]["counting"]["state"]["counts"] == saturated["transit"]["counting"]["state"]["counts"]
    for name, point, covariance in [("coalesced_normal_interval", [0, 1e200], [1, 0, 1]),
        ("unsupported_correlated_normal", [0, 1], [1, float(np.nextafter(1., 0.)), 1]),
        ("gate_geometry_overflow", [-1e308, 0], [1, 0, 1])]:
        simple, counted, _ = journey_fixture(name)
        if name == "gate_geometry_overflow":
            inner = intervals.evidence_source(counted)
            config = json.loads(inner["counting"])
            config["gates"] = [gates.gate(identity, [1e308, 0], [1e308, 1], 0) for identity in ["entry", "exit"]]
            inner["counting"] = encode(config)
            counted["counting"] = encode(inner)
        entry = source(simple, counted)
        empty, invalid = checkpoints.frame(0), checkpoints.frame(1, [checkpoints.observation(1, point, covariance)])
        prior = native(binary, STREAM, [entry, empty])
        native(binary, "--checkpoint", [simple, empty, invalid], count=1)
        bad(name, [entry, empty, invalid], prior)
        bad(name + "_no_checkpoint", [entry, empty, invalid], mode=CHECKPOINT)
        original = native(binary, CHECKPOINT, [entry, empty], count=1)[0]
        repaired = native(binary, CHECKPOINT, [{"resume": original}, checkpoints.frame(1)], count=1)[0]
        assert repaired["measurement"]["motion"]["next_segment_id"] == "1"
    return {"rejected_cases": len(records), "cases": records, "complete_prefix_preserved": True,
        "no_checkpoint_after_fatal_frame": True, "saved_state_same_timestamp_retry": "passed",
        "consistent_historical_covariance_not_forced_to_current_motion_covariance": True,
        "motion_upper_covariance_block_preserves_tolerated_roundoff_asymmetry": True,
        "independently_valid_component_checkpoints_with_impossible_joint_witnesses_rejected": True}


def transport_checks(binary):
    measurement, transit, frames = journey_fixture()
    head = source(measurement, transit)
    expected_frames = native(binary, STREAM, [head] + frames)
    for ending in [b"\n", b"\r\n"]:
        assert run(binary, STREAM, payload=ending.join(encode(value).encode() for value in [head] + frames))[0] == expected_frames
    saved = native(binary, CHECKPOINT, [head], count=1)[0]
    exact = encode({"resume": saved}).ljust(8388619)
    assert native(binary, CHECKPOINT, [exact], count=1, extra=["--max-line-bytes", "16777216"])[0] == saved
    _, source_failure = run(binary, CHECKPOINT, [exact + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    padded = encode(frames[0]).ljust(1048576)
    assert native(binary, STREAM, [head, padded]) == expected_frames[:1]
    _, frame_failure = run(binary, CHECKPOINT, [head, padded + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    return {"crlf_and_unterminated_eof": "passed", "exact_resume_utf16_units": 8388619,
        "source_overflow": source_failure, "exact_frame_utf16_units": 1048576, "frame_overflow": frame_failure}


def reframe_checks(binary):
    raw = [json.loads(value) for value in (ROOT / "examples/distorted-camera.ndjson").read_text().splitlines()]
    measurement, frames = raw[0], raw[1:]
    measurement["diagnostics"] = True
    transit = policy(analysis.evidence_source(gates.configuration(name=measurement["session_id"], gates=[
        gates.gate("horizontal", [-100, 3.8], [100, 3.8], .005)])))
    baseline, _ = expected(binary, measurement, transit, frames)
    cut = 4
    saved = native(binary, CHECKPOINT, [source(measurement, transit)] + frames[:cut], count=1)[0]
    transform = {"scale_x": .6, "scale_y": 1.3, "offset_x": -40, "offset_y": 16}
    converted = native(binary, "--reframe", [{"source": {"resume": saved["measurement"]}, "transform": transform}] + frames[cut:])
    changed = copy.deepcopy(saved)
    changed["measurement"] = converted[0]["resume"]
    assert changed["measurement"]["motion"] == saved["measurement"]["motion"]
    wanted, final = expected(binary, {"resume": changed["measurement"]}, {"resume": changed["transit"]}, converted[1:])
    actual = native(binary, STREAM, [{"resume": changed}] + converted[1:])
    assert actual == wanted
    assert native(binary, CHECKPOINT, [{"resume": changed}] + converted[1:], count=1)[0] == final
    errors = {}
    gates.tree_close(actual, baseline[cut:], errors)
    return {"status": "passed", "brown_prefix_frames": cut, "continuation_frames": len(actual),
        "saved_metric_motion_and_transit_unchanged": True, "maximum_absolute_reframe_differences": errors}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/evidence-transit-analysis.test.mjs"]
    completed = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=300)
    if completed.returncode:
        raise AssertionError("Node evidence transit analysis failed:\n" + completed.stdout[-18000:] + completed.stderr[-2000:])
    summary, directions = {}, None
    for value in completed.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", value)
        if match:
            summary[match.group(1)] = int(match.group(2))
        if value.startswith('# {"cut_points":'):
            directions = json.loads(value[2:])
    assert summary.get("tests") and summary["pass"] == summary["tests"] and not summary["fail"] and directions is not None
    return {"status": "passed", "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "command": " ".join(command), "summary": summary, "cross_runtime": directions,
        "test_script_sha256": hashlib.sha256((ROOT / "web/evidence-transit-analysis.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(), "stderr": completed.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/evidence-transit-analysis-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "fixtures": "deterministic",
        "command": " ".join(shlex.quote(value) for value in [sys.executable] + sys.argv),
        "python": platform.python_version(), "numpy": np.__version__, "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "evidence_reference_sha256": hashlib.sha256(Path(evidence.__file__).read_bytes()).hexdigest(),
        "transit_reference_sha256": hashlib.sha256(Path(intervals.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["independent_composition"] = reference_checks(binary)
    result["strict_transport_and_relations"] = rejection_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    result["pixel_reframe_continuation"] = reframe_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result.update(elapsed_seconds=time.perf_counter() - started, status="passed")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "output": str(args.output),
        "cases": result["independent_composition"]["cases"], "frames": result["independent_composition"]["frames"],
        "resume_cut_points": result["independent_composition"]["resume_cut_points"],
        "strict_rejections": result["strict_transport_and_relations"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
