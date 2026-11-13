#!/usr/bin/env python3
"""Compare atomic evidence analysis with the existing two independent owners.

The successful host pipeline uses --stream/--checkpoint followed by the old
--count-evidence/--evidence-checkpoint. Fraction/Decimal evidence and NumPy
finite-chord references are reused independently of the new combined owner.
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
import checkpoint_verify as checkpoints
import evidence_verify as evidence_reference
import gates_verify as gates
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
encode, native, run = gates.encode, gates.native, gates.execute
source = analysis_reference.source


def evidence_source(counting, multiplier=2):
    return {"counting": encode(counting), "sigma_multiplier": multiplier}


def combined(measurement, counting):
    return {"format": "moonground.evidence-analysis", "checkpoint_version": "1",
        "measurement": measurement, "counting": counting}


def history_fixture():
    measurement = checkpoints.config("evidence-analysis-history")
    measurement["motion"].update(gate=1e9, initial_velocity_std=1000, min_observations=2, min_span_us="100000")
    counting = gates.configuration(name=measurement["session_id"], gates=[gates.gate(deadband=.05)])
    frames = [checkpoints.frame(0, [checkpoints.observation(1, [0, -1], [.01, 0, .01])]),
        checkpoints.frame(100000, [checkpoints.observation(1, [0, .1], [1, 0, 1])]),
        checkpoints.frame(200000, [checkpoints.observation(1, [0, 3], [.01, 0, .01])])]
    return measurement, evidence_source(counting), frames


def fixtures():
    values = []
    for name, measurement, counting, frames in analysis_reference.fixtures():
        policy = copy.deepcopy(counting)
        policy["max_tracks"] = max(policy["max_tracks"], measurement.get("motion", {}).get("max_tracks", 1000))
        values.append((name, measurement, evidence_source(policy), frames))
    values.append(("unconfirmed_mean_outside_legacy_deadband",) + history_fixture())
    measurement, counting, frames = history_fixture()
    measurement = copy.deepcopy(measurement)
    measurement["session_id"] = "evidence-analysis-upper-clock"
    gate_config = json.loads(counting["counting"])
    gate_config["session_id"] = measurement["session_id"]
    upper = copy.deepcopy(frames)
    for frame in upper:
        frame["timestamp_us"] = str(9223372036854775807 - 200000 + int(frame["timestamp_us"]))
    values.append(("int64_max_history", measurement, evidence_source(gate_config), upper))
    measurement = checkpoints.config("evidence-analysis-quality-skip")
    counting = gates.configuration(name=measurement["session_id"], quality=.01)
    # Valid old motion covariance lies outside the stricter correlated normal
    # domain, but scalar quality filtering skips this target before that math.
    frames = [checkpoints.frame(0, [checkpoints.observation(1, [1, 1], [1, float(np.nextafter(-1., 0)), 1])])]
    values.append(("quality_skip_precedes_normal_domain", measurement, evidence_source(counting), frames))
    return values


def expected(binary, measurement, counting, frames):
    measured = native(binary, "--stream", [measurement] + frames)
    counted = native(binary, "--count-evidence", [counting] + measured)
    outputs = [{"schema_version": "0.1.0", "kind": "evidence_analysis_frame",
        "measurement": left, "counting": right} for left, right in zip(measured, counted)]
    saved = combined(native(binary, "--checkpoint", [measurement] + frames, count=1)[0],
        native(binary, "--evidence-checkpoint", [counting] + measured, count=1)[0])
    return outputs, saved


def reference_checks(binary):
    records, statuses, absolute, relative = [], set(), {}, {}
    total = events = evidence_count = cuts = 0
    for name, measurement, counting, frames in fixtures():
        header = source(measurement, counting)
        baseline, final = expected(binary, measurement, counting, frames)
        actual = native(binary, "--analyze-evidence", [header] + frames)
        assert actual == baseline, name + ": combined frames differ from independent owners"
        assert native(binary, "--analyze-evidence-checkpoint", [header] + frames, count=1)[0] == final, name
        oracle = evidence_reference.Oracle(counting, final["counting"]["configuration"]["counting"])
        for value in actual:
            evidence_reference.compare_frame(value["counting"], oracle.update(value["measurement"]), absolute, relative)
            statuses.update(item["status"] for item in value["measurement"]["tracks"])
            events += len(value["counting"]["counting"]["crossings"])
            evidence_count += len(value["counting"]["evidence"])
        for cut in range(len(frames) + 1):
            saved = native(binary, "--analyze-evidence-checkpoint", [header] + frames[:cut], count=1)[0]
            old_measured = native(binary, "--stream", [measurement] + frames[:cut])
            assert saved == combined(native(binary, "--checkpoint", [measurement] + frames[:cut], count=1)[0],
                native(binary, "--evidence-checkpoint", [counting] + old_measured, count=1)[0]), name
            for resume in [{"resume": saved}, source({"resume": saved["measurement"]}, {"resume": saved["counting"]})]:
                assert native(binary, "--analyze-evidence", [resume] + frames[cut:]) == actual[cut:], (name, cut)
                assert native(binary, "--analyze-evidence-checkpoint", [resume] + frames[cut:], count=1)[0] == final, (name, cut)
            cuts += 1
        total += len(frames)
        records.append({"name": name, "frames": len(frames), "checkpoint_sha256": hashlib.sha256(encode(final).encode()).hexdigest()})
    required = {"initializing", "ready", "uncertain", "rejected_innovation", "rejected_projection", "numerical_failure"}
    assert required.issubset(statuses), required - statuses
    assert events > 0
    return {"cases": len(records), "frames": total, "evidence_records": evidence_count, "crossings": events,
        "resume_cut_points": cuts, "resume_source_forms": 2, "statuses": sorted(statuses),
        "full_motion_state_covariance_paths_counts_and_original_anchor_covariances_equal": True,
        "maximum_absolute_oracle_errors": absolute, "maximum_relative_or_scaled_evidence_errors": relative, "records": records}


def rejection_checks(binary):
    measurement = checkpoints.config("evidence-analysis-strict")
    measurement["motion"].update(gate=1e9, min_observations=2, min_span_us="100000")
    gate_config = gates.configuration(name=measurement["session_id"])
    counting = evidence_source(gate_config)
    head = source(measurement, counting)
    first = checkpoints.frame(100000, [checkpoints.observation(1, [0, -1])])
    later = checkpoints.frame(200000, [checkpoints.observation(1, [0, 1])])
    prefix = native(binary, "--analyze-evidence", [head, first])
    saved = native(binary, "--analyze-evidence-checkpoint", [head, first], count=1)[0]
    records = []

    def bad(name, values, expected_prefix=(), mode="--analyze-evidence", payload=None, extra=()):
        try:
            actual, detail = run(binary, mode, values, status=2, payload=payload, extra=extra)
        except AssertionError as error:
            raise AssertionError(name + ": " + str(error)) from error
        assert actual == list(expected_prefix), name + ": partial data/checkpoint exposed"
        records.append(dict(name=name, **detail))

    for name, value in [
        ("missing_counting_source", {"measurement": head["measurement"]}),
        ("source_object_not_raw", dict(head, counting=counting)),
        ("unknown_source_field", dict(head, extra=True)),
        ("duplicate_raw_source_key", '{"measurement":"bad",' + encode(head)[1:]),
        ("raw_fractional_capacity", source(measurement, dict(counting, counting=counting["counting"].replace('"max_tracks":100', '"max_tracks":100.0000000000000001')))),
        ("measurement_only_started", source({"resume": saved["measurement"]}, counting)),
        ("evidence_only_started", source(measurement, {"resume": saved["counting"]})),
    ]:
        bad(name, [value])
    for name, mutate in [
        ("wrong_joint_format", lambda v: v.update(format="moonground.analysis")),
        ("wrong_joint_version", lambda v: v.update(checkpoint_version="2")),
        ("unknown_joint_key", lambda v: v.update(extra=True)),
        ("different_session", lambda v: v["counting"]["configuration"]["counting"].update(session_id="other")),
        ("different_watermark", lambda v: v["counting"]["state"].update(last_timestamp_us="100001")),
        ("missing_current_evidence_track", lambda v: v["counting"]["state"].update(tracks=[])),
        ("extra_current_evidence_track", lambda v: v["counting"]["state"]["tracks"].append(dict(copy.deepcopy(v["counting"]["state"]["tracks"][0]), track_id=2))),
        ("different_segment", lambda v: v["counting"]["state"]["tracks"][0].update(segment_id="2")),
        ("stable_missing_anchor", lambda v: v["counting"]["state"]["tracks"][0].update(anchors=[None])),
        ("current_anchor_wrong_position", lambda v: v["counting"]["state"]["tracks"][0]["anchors"][0].update(point_m=[.25, -1])),
        ("current_anchor_wrong_covariance", lambda v: v["counting"]["state"]["tracks"][0]["anchors"][0].update(covariance=[.02, .002, .02])),
        ("anchor_predates_segment", lambda v: v["counting"]["state"]["tracks"][0]["anchors"][0].update(timestamp_us="99999")),
        ("quality_forged_current_track", lambda v: v["counting"]["configuration"]["counting"].update(max_position_std_m=.01)),
        ("missing_effective_gap", lambda v: v["counting"]["configuration"]["counting"].pop("max_gap_us")),
        ("missing_effective_capacity", lambda v: v["counting"]["configuration"]["counting"].pop("max_tracks")),
        ("missing_effective_deadband", lambda v: v["counting"]["configuration"]["counting"]["gates"][0].pop("deadband_m")),
        ("missing_effective_multiplier", lambda v: v["counting"]["configuration"].pop("sigma_multiplier")),
    ]:
        invalid = copy.deepcopy(saved)
        mutate(invalid)
        bad(name, [{"resume": invalid}])
    for name, invalid in [
        ("raw_fractional_track", encode(later).replace('"track_id":1', '"track_id":1.0000000000000001')),
        ("duplicate_raw_frame_key", '{"timestamp_us":"200000",' + encode(later)[1:]),
        ("same_time", first), ("unknown_frame_field", dict(later, extra=True)),
        ("duplicate_observation", dict(later, observations=later["observations"] * 2)),
        ("observation_lost_conflict", dict(later, lost=[1])),
    ]:
        bad(name, [head, first, invalid], prefix)
    bad("late_failure_no_checkpoint", [head, first, dict(later, extra=True)], mode="--analyze-evidence-checkpoint")
    bad("invalid_utf8_tail", [], prefix, payload=gates.lines([head, first]).encode() + b"\xff")
    history_measurement, history_counting, history_frames = history_fixture()
    history_head = source(history_measurement, history_counting)
    history = native(binary, "--analyze-evidence-checkpoint", [history_head] + history_frames[:2], count=1)[0]
    anchor = history["counting"]["state"]["tracks"][0]["anchors"][0]
    assert anchor["timestamp_us"] == "0"
    measured = native(binary, "--stream", [history_measurement] + history_frames[:2])
    assert measured[-1]["tracks"][0]["position_m"][1] > .05
    assert history["counting"]["state"]["last_timestamp_us"] == "100000"
    assert native(binary, "--analyze-evidence-checkpoint", [{"resume": history}], count=1)[0] == history
    for name, mutate in [
        ("historical_first_point_mismatch", lambda v: v["counting"]["state"]["tracks"][0]["anchors"][0].update(point_m=[.25, -1])),
        ("unconfirmed_current_time_historical_covariance", lambda v: v["counting"]["state"]["tracks"][0]["anchors"][0].update(timestamp_us="100000")),
    ]:
        invalid = copy.deepcopy(history)
        mutate(invalid)
        # The component is structurally valid; the combined relation is not.
        native(binary, "--evidence-checkpoint", [{"resume": invalid["counting"]}], count=1)
        bad(name, [{"resume": invalid}])
    # Motion preserves small covariance roundoff asymmetry. The public position
    # covariance uses the upper P01, never a new average with P10.
    symmetric = native(binary, "--analyze-evidence-checkpoint", [head, first, later], count=1)[0]
    covariance = symmetric["measurement"]["motion"]["tracks"][0]["covariance"]
    covariance[4] = covariance[1] * (1 + 1e-10)
    assert native(binary, "--analyze-evidence-checkpoint", [{"resume": symmetric}], count=1)[0] == symmetric
    saturated = copy.deepcopy(saved)
    saturated["counting"]["state"]["counts"][0]["negative_to_positive"] = "9223372036854775807"
    bad("counter_exhaustion", [{"resume": saturated}, later])
    bad("counter_exhaustion_no_checkpoint", [{"resume": saturated}, later], mode="--analyze-evidence-checkpoint")
    correction = checkpoints.frame(200000)
    corrected = native(binary, "--analyze-evidence-checkpoint", [{"resume": saturated}, correction], count=1)[0]
    assert corrected["measurement"]["motion"]["last_timestamp_us"] == "200000"
    assert corrected["counting"]["state"]["last_timestamp_us"] == "200000"
    assert corrected["counting"]["state"]["counts"] == saturated["counting"]["state"]["counts"]
    assert corrected["counting"]["state"]["tracks"] == []
    # A new target is staged and allocated by motion, then evidence fails.
    # Public independent session updates succeed on these same observations.
    for name, gate_values, point, covariance in [
        ("coalesced_interval", [gates.gate()], [0, 1e200], [1, 0, 1]),
        ("unsupported_normal_covariance", [gates.gate("diagonal", [-1, 1], [1, -1], 0)], [1, 1], [1, float(np.nextafter(-1., 0)), 1]),
        ("gate_geometry_overflow", [gates.gate("far", [1e308, 0], [1e308, 1], 0)], [-1e308, 0], [1, 0, 1]),
    ]:
        simple = {"session_id": name, "mode": "ground"}
        policy = evidence_source(gates.configuration(name=name, gates=gate_values))
        entry = source(simple, policy)
        empty, invalid = checkpoints.frame(0), checkpoints.frame(1, [checkpoints.observation(1, point, covariance)])
        prior = native(binary, "--analyze-evidence", [entry, empty])
        native(binary, "--checkpoint", [simple, empty, invalid], count=1)
        bad(name, [entry, empty, invalid], prior)
        bad(name + "_no_checkpoint", [entry, empty, invalid], mode="--analyze-evidence-checkpoint")
        original = native(binary, "--analyze-evidence-checkpoint", [entry, empty], count=1)[0]
        repaired = native(binary, "--analyze-evidence-checkpoint", [{"resume": original}, checkpoints.frame(1)], count=1)[0]
        assert repaired["measurement"]["motion"]["next_segment_id"] == "1"
    return {"rejected_cases": len(records), "cases": records, "complete_prefix_preserved": True,
        "failed_checkpoint_has_no_output": True, "saved_state_same_timestamp_correction": "passed",
        "valid_older_anchor_when_current_mean_exceeds_legacy_deadband": True,
        "motion_covariance_upper_block_preserves_roundoff_asymmetry": True}


def transport_checks(binary):
    measurement, counting, frames = history_fixture()
    header = source(measurement, counting)
    expected_frames = native(binary, "--analyze-evidence", [header] + frames)
    for ending in [b"\n", b"\r\n"]:
        assert run(binary, "--analyze-evidence", payload=ending.join(encode(v).encode() for v in [header] + frames))[0] == expected_frames
    saved = native(binary, "--analyze-evidence-checkpoint", [header], count=1)[0]
    exact = encode({"resume": saved}).ljust(8388619)
    assert native(binary, "--analyze-evidence-checkpoint", [exact], count=1, extra=["--max-line-bytes", "16777216"])[0] == saved
    _, overflow = run(binary, "--analyze-evidence-checkpoint", [exact + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    padded = encode(frames[0]).ljust(1048576)
    assert native(binary, "--analyze-evidence", [header, padded]) == expected_frames[:1]
    _, frame_failure = run(binary, "--analyze-evidence-checkpoint", [header, padded + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    return {"crlf_and_unterminated_eof": "passed", "exact_resume_source_utf16_units": 8388619,
        "source_overflow": overflow, "exact_observation_frame_utf16_units": 1048576, "frame_overflow": frame_failure}


def reframe_checks(binary):
    records = [json.loads(value) for value in (ROOT / "examples/distorted-camera.ndjson").read_text().splitlines()]
    measurement, frames = records[0], records[1:]
    measurement["diagnostics"] = True
    counting = evidence_source(gates.configuration(name=measurement["session_id"], gates=[
        gates.gate("horizontal", (-100, 3.8), (100, 3.8), .005)]))
    baseline, _ = expected(binary, measurement, counting, frames)
    cut = 4
    saved = native(binary, "--analyze-evidence-checkpoint", [source(measurement, counting)] + frames[:cut], count=1)[0]
    transform = {"scale_x": .6, "scale_y": 1.3, "offset_x": -40, "offset_y": 16}
    converted = native(binary, "--reframe", [{"source": {"resume": saved["measurement"]}, "transform": transform}] + frames[cut:])
    changed = copy.deepcopy(saved)
    changed["measurement"] = converted[0]["resume"]
    # Reframing changes pixel configuration only; all saved metric evidence
    # and the asymmetric accepted motion covariance remain untouched.
    assert changed["measurement"]["motion"] == saved["measurement"]["motion"]
    expected_frames, final = expected(binary, {"resume": changed["measurement"]}, {"resume": changed["counting"]}, converted[1:])
    actual = native(binary, "--analyze-evidence", [{"resume": changed}] + converted[1:])
    assert actual == expected_frames
    assert native(binary, "--analyze-evidence-checkpoint", [{"resume": changed}] + converted[1:], count=1)[0] == final
    errors = {}
    gates.tree_close(actual, baseline[cut:], errors)
    return {"status": "passed", "brown_pixel_prefix_frames": cut, "continuation_frames": len(actual),
        "saved_metric_motion_and_evidence_unchanged": True, "maximum_absolute_reframe_differences": errors}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/evidence-analysis.test.mjs"]
    completed = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=300)
    if completed.returncode:
        raise AssertionError("Node evidence-analysis verification failed:\n" + completed.stdout[-18000:] + completed.stderr[-2000:])
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
        "test_script_sha256": hashlib.sha256((ROOT / "web/evidence-analysis.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(), "stderr": completed.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/evidence-analysis-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "fixtures": "deterministic", "command": " ".join(shlex.quote(v) for v in [sys.executable] + sys.argv),
        "python": platform.python_version(), "numpy": np.__version__, "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "evidence_reference_sha256": hashlib.sha256(Path(evidence_reference.__file__).read_bytes()).hexdigest(),
        "analysis_fixture_sha256": hashlib.sha256(Path(analysis_reference.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["independent_composition"] = reference_checks(binary)
    result["strict_transport_and_relations"] = rejection_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    result["pixel_reframe_continuation"] = reframe_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    result["status"] = "passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "output": str(args.output), "cases": result["independent_composition"]["cases"],
        "frames": result["independent_composition"]["frames"], "resume_cut_points": result["independent_composition"]["resume_cut_points"],
        "strict_rejections": result["strict_transport_and_relations"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
