#!/usr/bin/env python3
"""Check raw joint windows against the original analysis and window owners.

The host executes v0.16 independently, then supplies every outcome to v0.18.
Offline Python-integer grouping checks statistics; the existing Decimal/Fraction
reference checks the measured evidence and mean-chord elapsed bounds separately.
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

import checkpoint_verify as observations
import evidence_transit_analysis_verify as upstream
import gates_verify as gates
import transit_windows_verify as windows
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
MAX = windows.MAX
STREAM, CHECKPOINT = "--analyze-transit-windows", "--analyze-transit-windows-checkpoint"
encode, native, run = gates.encode, gates.native, gates.execute


def options(width=250000, limits=(0, 1, 100000, 200000, 300000, MAX), origin=0):
    return {"window_us": str(width), "duration_limits_us": [str(value) for value in limits], "origin_us": str(origin)}


def source(analysis, strategy=None):
    strategy = options() if strategy is None else strategy
    return {"analysis": analysis if isinstance(analysis, str) else encode(analysis),
        "windows": strategy if isinstance(strategy, str) else encode(strategy)}


def combined(analysis, statistics):
    return {"format": "moonground.evidence-transit-window-analysis", "checkpoint_version": "1",
        "analysis": analysis, "windows": statistics}


def host(binary, analysis, strategy, frames):
    initial = native(binary, upstream.CHECKPOINT, [analysis], count=1)[0]
    output = native(binary, upstream.STREAM, [analysis] + frames)
    final_analysis = native(binary, upstream.CHECKPOINT, [analysis] + frames, count=1)[0]
    if "resume" in strategy:
        window_source = strategy
        # Oracle can continue a complete saved aggregate by rechecking against
        # the separate original window owner; fresh fixtures below use grouping.
        grouped = native(binary, windows.STREAM, [window_source] + [value["transit"] for value in output])
    else:
        window_source = dict(strategy, transit=encode({"resume": initial["transit"]}))
        grouped, expected_checkpoint = windows.oracle(initial["transit"], strategy, [value["transit"] for value in output])
        assert native(binary, windows.STREAM, [window_source] + [value["transit"] for value in output]) == grouped
    final_windows = native(binary, windows.CHECKPOINT,
        [window_source] + [value["transit"] for value in output], count=1)[0]
    if "resume" not in strategy:
        assert final_windows == expected_checkpoint
    return ([{"schema_version": "0.1.0", "kind": "evidence_transit_window_analysis_frame", "analysis": left, "windows": right}
        for left, right in zip(output, grouped)], combined(final_analysis, final_windows), initial)


def check_case(binary, name, analysis, strategy, frames, numeric=None):
    expected, final, initial = host(binary, analysis, strategy, frames)
    header = source(analysis, strategy)
    assert native(binary, STREAM, [header] + frames) == expected, name
    assert native(binary, CHECKPOINT, [header] + frames, count=1)[0] == final, name
    for cut in range(len(frames) + 1):
        saved = native(binary, CHECKPOINT, [header] + frames[:cut], count=1)[0]
        analysis_prefix = native(binary, upstream.CHECKPOINT, [analysis] + frames[:cut], count=1)[0]
        if "resume" not in strategy:
            window_prefix = windows.oracle(initial["transit"], strategy, [value["analysis"]["transit"] for value in expected[:cut]])[1]
            assert saved == combined(analysis_prefix, window_prefix), (name, cut)
        for resumed in [{"resume": saved}, source({"resume": saved["analysis"]}, {"resume": saved["windows"]})]:
            assert native(binary, STREAM, [resumed] + frames[cut:]) == expected[cut:], (name, cut)
            assert native(binary, CHECKPOINT, [resumed] + frames[cut:], count=1)[0] == final, (name, cut)
    return {"name": name, "frames": len(frames), "resume_cut_points": len(frames) + 1,
        "passages": sum(len(value["analysis"]["transit"]["passages"]) for value in expected),
        "cancellations": sum(len(value["analysis"]["transit"]["cancellations"]) for value in expected),
        "closed_windows": sum(value["windows"]["closed_window"] is not None for value in expected),
        "numeric_reference": numeric, "checkpoint_sha256": hashlib.sha256(encode(final).encode()).hexdigest()}


def reference_checks(binary):
    records, statuses = [], set()
    for name, measurement, transit, frames in upstream.fixtures():
        analysis = upstream.source(measurement, transit)
        old_frames, old_final = upstream.expected(binary, measurement, transit, frames)
        numeric = upstream.oracle_checks(transit, old_frames, old_final)
        for value in old_frames:
            statuses.update(track["status"] for track in value["measurement"]["tracks"])
        strategy = options(MAX if "int64_max" in name else 250000)
        records.append(check_case(binary, name, analysis, strategy, frames, numeric))
    measurement, transit, frames = upstream.journey_fixture("window-analysis-started")
    original = upstream.source(measurement, transit)
    saved = native(binary, upstream.CHECKPOINT, [original] + frames[:3], count=1)[0]
    assert saved["transit"]["pending"]
    records.append(check_case(binary, "pending_before_statistics_baseline_completes", {"resume": saved}, options(100000), frames[3:]))
    history = frames + [observations.frame(t, [observations.observation(1, [0, y], [.01, 0, .01])])
        for t, y in [(400000, -1), (500000, 1)]]
    historical = native(binary, upstream.CHECKPOINT, [original] + history, count=1)[0]
    assert historical["transit"]["pending"] and int(historical["transit"]["counts"][0]["completed"]) > 0
    future = [observations.frame(600000, [observations.observation(1, [0, 4], [.01, 0, .01])])]
    records.append(check_case(binary, "nonzero_completed_baseline_is_not_new_window_history", {"resume": historical}, options(100000), future))
    # A gap with no objects still advances the window clock once per supplied frame.
    empty = [observations.frame(0), observations.frame(MAX)]
    records.append(check_case(binary, "huge_empty_gap_one_microsecond_windows", original, options(1), empty))
    # The first valid raw frame may coincide with a nonzero configured origin.
    aligned = [observations.frame(100, [observations.observation(1, [0, -1], [.01, 0, .01])])]
    records.append(check_case(binary, "first_input_exactly_at_origin", original, options(1, origin=100), aligned))
    # Hidden track 2 is explicitly removed together with the visible pending track.
    hidden = [observations.frame(0, [observations.observation(i, [0, -1], [.01, 0, .01]) for i in [1, 2]]),
        observations.frame(100000, [observations.observation(1, [0, 1], [.01, 0, .01])]),
        observations.frame(150000, removed=[1, 2]),
        observations.frame(200000, [observations.observation(1, [0, 4], [.01, 0, .01])])]
    records.append(check_case(binary, "empty_removal_closes_hidden_and_cancels_pending", original, options(100000), hidden))
    return {"cases": len(records), **{key: sum(value[key] for value in records) for key in
        ["frames", "resume_cut_points", "passages", "cancellations", "closed_windows"]},
        "resume_source_forms": 2, "statuses": sorted(statuses), "offline_integer_statistics_exact": True,
        "complete_measurement_covariance_paths_evidence_pending_counts_and_windows_equal": True, "records": records}


def strict_checks(binary):
    measurement, transit, frames = upstream.journey_fixture("window-analysis-strict")
    analysis = upstream.source(measurement, transit)
    header = source(analysis, options(MAX))
    saved = native(binary, CHECKPOINT, [header] + frames[:3], count=1)[0]
    cases, relations = [], []

    def bad(name, records, prefix=(), mode=STREAM, payload=None, extra=()):
        output, detail = run(binary, mode, records, status=2, payload=payload, extra=extra)
        assert output == list(prefix), name + ": incorrect complete output prefix"
        cases.append(dict(name=name, **detail))

    def incompatible(name, value):
        # Both original standalone restore paths must succeed first.
        assert native(binary, upstream.CHECKPOINT, [{"resume": value["analysis"]}], count=1)[0] == value["analysis"]
        assert native(binary, windows.CHECKPOINT, [{"resume": value["windows"]}], count=1)[0] == value["windows"]
        bad(name, [{"resume": value}])
        relations.append(name)

    for name, value in [
        ("missing_windows", {"analysis": header["analysis"]}),
        ("analysis_not_raw", dict(header, analysis=analysis)),
        ("windows_not_raw", dict(header, windows=options())),
        ("windows_has_duplicate_transit_source", source(analysis, dict(options(), transit=encode(transit)))),
        ("unknown_source_key", dict(header, extra=True)),
        ("duplicate_source_key", '{"analysis":"bad",' + encode(header)[1:]),
        ("number_width", source(analysis, dict(options(), window_us=100))),
        ("empty_window_strategy", source(analysis, {})),
        ("noncanonical_width", source(analysis, dict(options(), window_us="01"))),
        ("duplicate_raw_window_key", source(analysis, '{"window_us":"1",' + encode(options())[1:])),
    ]:
        bad(name, [value])
    for name, mutate in [
        ("wrong_format", lambda v: v.update(format="moonground.evidence-transit-analysis")),
        ("wrong_version", lambda v: v.update(checkpoint_version="2")),
        ("unknown_checkpoint_key", lambda v: v.update(extra=True)),
        ("missing_window_width", lambda v: v["windows"].pop("window_us")),
        ("missing_window_deadband", lambda v: v["windows"]["gates"][0].pop("deadband_m")),
        ("missing_evidence_sigma", lambda v: v["analysis"]["transit"]["counting"]["configuration"].pop("sigma_multiplier")),
    ]:
        value = copy.deepcopy(saved)
        mutate(value)
        bad(name, [{"resume": value}])
    for name, mutate in [
        ("bound_session_mismatch", lambda v: v["windows"].update(session_id="other")),
        ("bound_sigma_mismatch", lambda v: v["windows"].update(sigma_multiplier=3)),
        ("bound_capacity_mismatch", lambda v: v["windows"]["config"].update(max_tracks=11)),
        ("bound_gap_mismatch", lambda v: v["windows"]["config"].update(max_gap_us="500001")),
        ("bound_quality_mismatch", lambda v: v["windows"]["config"].update(max_position_std_m=10)),
        ("bound_current_lifetime_count_mismatch", lambda v: v["windows"]["counts"][0].update(completed="1")),
        ("bound_gate_geometry_mismatch", lambda v: v["windows"]["gates"][0]["start_m"].__setitem__(0, -2)),
        ("bound_section_direction_mismatch", lambda v: v["windows"]["sections"][0].update(entry_direction="positive_to_negative")),
    ]:
        value = copy.deepcopy(saved)
        mutate(value)
        incompatible(name, value)
    value = copy.deepcopy(saved)
    value["windows"]["last_timestamp_us"] = "200001"
    value["windows"]["current_window"]["last_timestamp_us"] = "200001"
    incompatible("bound_watermark_mismatch", value)
    # Sparse timestamps from two tracks include a hidden accepted sample.
    stationary = [observations.frame(0, [observations.observation(i, [0, -1], [.01, 0, .01]) for i in [1, 2]]),
        observations.frame(100000, [observations.observation(2, [0, -1], [.01, 0, .01])]),
        observations.frame(200000, [observations.observation(1, [0, -1], [.01, 0, .01])])]
    coherent = native(binary, CHECKPOINT, [header] + stationary, count=1)[0]
    value = copy.deepcopy(coherent)
    value["windows"]["current_window"].update(first_timestamp_us="200000", input_frames="1")
    incompatible("known_accepted_sample_before_first_statistics_frame", value)
    value = copy.deepcopy(coherent)
    value["windows"]["current_window"]["input_frames"] = "2"
    incompatible("hidden_distinct_accepted_times_exceed_input_frames", value)
    # Exact per-track accepted_count gives a stronger bound than its two endpoints.
    dense = [observations.frame(t, [observations.observation(1, [0, -1], [.01, 0, .01])]) for t in range(11)]
    dense_header = source(analysis, options(6))
    value = native(binary, CHECKPOINT, [dense_header] + dense, count=1)[0]
    value["windows"]["current_window"]["input_frames"] = "4"
    incompatible("accepted_count_outside_bucket_capacity", value)
    value = copy.deepcopy(coherent)
    value["windows"].update(origin_us="1")
    value["windows"]["current_window"].update(start_us="1", end_exclusive_us=None, first_timestamp_us="100000", input_frames="2")
    incompatible("unstarted_baseline_cannot_contain_pre_origin_motion", value)
    finished = native(binary, CHECKPOINT, [header] + frames, count=1)[0]
    assert finished["analysis"]["transit"]["counts"][0]["completed"] == "1"
    value = copy.deepcopy(finished)
    for section in value["windows"]["current_window"]["sections"]:
        section["completed"] = "0"
        for row in section["duration_limits"]:
            row.update(within="0", exceeded="0", indeterminate="0")
    incompatible("first_bucket_omits_lifetime_completion", value)
    value = copy.deepcopy(saved)
    value["windows"]["current_window"]["sections"][0]["cancellations"][0]["count"] = "1"
    incompatible("pending_and_window_cancellation_reuse_one_entry", value)
    value = copy.deepcopy(finished)
    value["windows"]["current_window"]["sections"][0]["cancellations"][0]["count"] = "1"
    incompatible("completion_and_window_cancellation_reuse_one_entry", value)
    # Two individually finite reason counters must not wrap their aggregate
    # budget comparison. The old components authenticate no historical log.
    clock_measurement, clock_transit, clock_frames = upstream.journey_fixture("window-budget-large-clock", [MAX - 4, MAX - 3, MAX - 2, MAX - 1])
    clock_measurement["motion"]["initial_velocity_std"] = 1e7
    value = native(binary, CHECKPOINT, [source(upstream.source(clock_measurement, clock_transit), options(MAX))] + clock_frames[:3], count=1)[0]
    value["analysis"]["transit"]["pending"] = []
    for count in value["analysis"]["transit"]["counting"]["state"]["counts"]:
        count.update(negative_to_positive=str(MAX), positive_to_negative=str(MAX))
    value["windows"]["current_window"].update(first_timestamp_us="0", input_frames=str(MAX - 1))
    for row in value["windows"]["current_window"]["sections"][0]["cancellations"][:2]:
        row["count"] = str(MAX - 1)
    incompatible("cancellation_budget_sum_cannot_wrap_Int64", value)
    # A baseline exactly one microsecond before the bucket also excludes all earlier statistics buckets.
    before = frames[:3] + [observations.frame(299999, [observations.observation(1, [0, 2], [.01, 0, .01])])]
    seed = native(binary, upstream.CHECKPOINT, [analysis] + before, count=1)[0]
    boundary_exit = observations.frame(300000, [observations.observation(1, [0, 10], [.01, 0, .01])])
    boundary = native(binary, CHECKPOINT, [source({"resume": seed}, options(100000)), boundary_exit], count=1)[0]
    assert boundary["windows"]["baseline_timestamp_us"] == "299999"
    assert boundary["windows"]["current_window"]["sections"][0]["completed"] == "1"
    for section in boundary["windows"]["current_window"]["sections"]:
        section["completed"] = "0"
        for row in section["duration_limits"]:
            row.update(within="0", exceeded="0", indeterminate="0")
    incompatible("baseline_at_start_minus_one_cannot_lose_completion", boundary)
    # A real late window rejection occurs after the upstream candidate succeeds.
    origin_header = source(analysis, options(origin=100))
    initial = native(binary, CHECKPOINT, [origin_header], count=1)[0]
    early = observations.frame(99, [observations.observation(9, [0, -1], [.01, 0, .01])])
    bad("candidate_before_window_origin", [origin_header, early])
    bad("before_origin_no_checkpoint", [origin_header, early], mode=CHECKPOINT)
    corrected_origin = dict(early, timestamp_us="100")
    recovered = native(binary, CHECKPOINT, [{"resume": initial}, corrected_origin], count=1)[0]
    assert recovered["analysis"]["measurement"]["motion"]["tracks"][0]["segment_id"] == "1"
    # Saturate a valid upstream gate, preserving bound window policy/counts.
    first = native(binary, CHECKPOINT, [header, frames[0]], count=1)[0]
    saturated = copy.deepcopy(first)
    for count in saturated["analysis"]["transit"]["counting"]["state"]["counts"]:
        count.update(negative_to_positive=str(MAX), positive_to_negative=str(MAX))
    bad("upstream_gate_overflow", [{"resume": saturated}, frames[1]])
    bad("upstream_gate_overflow_no_checkpoint", [{"resume": saturated}, frames[1]], mode=CHECKPOINT)
    noncrossing = observations.frame(100000, [observations.observation(1, [0, -2], [.01, 0, .01]),
        observations.observation(9, [0, -1], [.01, 0, .01])])
    retry = native(binary, CHECKPOINT, [{"resume": saturated}, noncrossing], count=1)[0]
    assert retry["analysis"]["measurement"]["motion"]["tracks"][1]["segment_id"] == "2"
    assert retry["windows"]["current_window"]["input_frames"] == "2"
    # Near-correlated SPD is outside the supported normal arithmetic domain.
    numeric = copy.deepcopy(frames[1])
    numeric["observations"][0]["covariance"] = [1, float.fromhex("0x1.fffffffffffffp-1"), 1]
    bad("upstream_normal_numeric_failure", [header, numeric])
    prefix = native(binary, STREAM, [header, frames[0]])
    for name, value in [("duplicate_objects", dict(frames[1], observations=frames[1]["observations"] * 2)),
        ("unknown_observation_key", dict(frames[1], extra=True))]:
        bad(name, [header, frames[0], value], prefix)
    raw_id = encode(frames[1]).replace('"track_id":1', '"track_id":1.0000000000000001')
    bad("raw_fractional_identity", [header, frames[0], raw_id], prefix)
    bad("late_error_no_checkpoint", [header, frames[0], dict(frames[1], extra=True)], mode=CHECKPOINT)
    bad("invalid_utf8_tail", [], prefix, payload=gates.lines([header, frames[0]]).encode() + b"\xff\n")
    return {"rejected_cases": len(cases), "independently_valid_incompatible_component_pairs": len(relations),
        "incompatible_pair_names": relations, "cases": cases, "complete_prefix_preserved": True,
        "origin_correction_changes_99_to_100_not_same_timestamp": True,
        "upstream_gate_exhaustion_same_timestamp_retry_from_saved_state": True,
        "no_unproved_reachable_window_overflow_claim": True}


def reframe_checks(binary):
    raw = [json.loads(value) for value in (ROOT / "examples/distorted-camera.ndjson").read_text().splitlines()]
    measurement, frames = raw[0], raw[1:]
    measurement["diagnostics"] = True
    transit = upstream.policy(upstream.analysis.evidence_source(gates.configuration(name=measurement["session_id"], gates=[
        gates.gate("horizontal", [-100, 3.8], [100, 3.8], .005)])))
    header = source(upstream.source(measurement, transit))
    baseline = native(binary, STREAM, [header] + frames)
    cut = 4
    saved = native(binary, CHECKPOINT, [header] + frames[:cut], count=1)[0]
    transform = {"scale_x": .6, "scale_y": 1.3, "offset_x": -40, "offset_y": 16}
    converted = native(binary, "--reframe", [{"source": {"resume": saved["analysis"]["measurement"]}, "transform": transform}] + frames[cut:])
    changed = copy.deepcopy(saved)
    changed["analysis"]["measurement"] = converted[0]["resume"]
    assert changed["windows"] == saved["windows"]
    assert changed["analysis"]["transit"] == saved["analysis"]["transit"]
    expected, final, _ = host(binary, {"resume": changed["analysis"]}, {"resume": changed["windows"]}, converted[1:])
    actual = native(binary, STREAM, [{"resume": changed}] + converted[1:])
    assert actual == expected
    assert native(binary, CHECKPOINT, [{"resume": changed}] + converted[1:], count=1)[0] == final
    assert [value["windows"] for value in actual] == [value["windows"] for value in baseline[cut:]]
    errors = {}
    gates.tree_close(actual, baseline[cut:], errors)
    return {"status": "passed", "brown_prefix_frames": cut, "continuation_frames": len(actual),
        "entire_window_state_metric_motion_and_pending_preserved_at_transform": True,
        "integer_windows_exact_after_reframe": True, "maximum_absolute_reframe_differences": errors}


def transport_checks(binary):
    measurement, transit, frames = upstream.journey_fixture()
    header = source(upstream.source(measurement, transit))
    expected = native(binary, STREAM, [header] + frames)
    for ending in [b"\n", b"\r\n"]:
        assert run(binary, STREAM, payload=ending.join(encode(value).encode() for value in [header] + frames))[0] == expected
    saved = native(binary, CHECKPOINT, [header], count=1)[0]
    exact = encode({"resume": saved}).ljust(8388619)
    assert native(binary, CHECKPOINT, [exact], count=1, extra=["--max-line-bytes", "16777216"])[0] == saved
    _, source_failure = run(binary, CHECKPOINT, [exact + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    padded = encode(frames[0]).ljust(1048576)
    assert native(binary, STREAM, [header, padded]) == expected[:1]
    _, frame_failure = run(binary, CHECKPOINT, [header, padded + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    return {"crlf_and_unterminated_eof": "passed", "exact_resume_utf16_units": len(exact), "source_overflow": source_failure,
        "exact_observation_utf16_units": len(padded), "observation_overflow": frame_failure}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/evidence-transit-window-analysis.test.mjs"]
    result = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=360)
    if result.returncode:
        raise AssertionError("Node joint window analysis failed:\n" + result.stdout[-18000:] + result.stderr[-2000:])
    summary, directions, batch = {}, None, None
    for line in result.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", line)
        if match:
            summary[match.group(1)] = int(match.group(2))
        if line.startswith('# {"cut_points":'):
            directions = json.loads(line[2:])
        if line.startswith('# {"successful_empty_frames":'):
            batch = json.loads(line[2:])
    assert summary.get("tests") and summary["pass"] == summary["tests"] and not summary["fail"] and directions is not None and batch is not None
    return {"status": "passed", "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "command": " ".join(command), "summary": summary, "cross_runtime": directions, "measured_bounded_batch": batch,
        "test_script_sha256": hashlib.sha256((ROOT / "web/evidence-transit-window-analysis.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(result.stdout.encode()).hexdigest(), "stderr": result.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/evidence-transit-window-analysis-results.json")
    args = parser.parse_args()
    binary, started = args.binary.resolve(), time.perf_counter()
    if not binary.is_file():
        parser.error("native binary does not exist")
    result = {"format_version": "1", "fixtures": "deterministic", "command": " ".join(shlex.quote(value) for value in [sys.executable] + sys.argv),
        "python": platform.python_version(), "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "upstream_reference_sha256": hashlib.sha256(Path(upstream.__file__).read_bytes()).hexdigest(),
        "window_reference_sha256": hashlib.sha256(Path(windows.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "classification_scope": windows.SCOPE}
    result["independent_components_and_integer_grouping"] = reference_checks(binary)
    result["strict_transport_and_joint_relations"] = strict_checks(binary)
    result["warm_brown_reframe"] = reframe_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result.update(elapsed_seconds=time.perf_counter() - started, status="passed")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "output": str(args.output), "cases": result["independent_components_and_integer_grouping"]["cases"],
        "frames": result["independent_components_and_integer_grouping"]["frames"],
        "resume_cut_points": result["independent_components_and_integer_grouping"]["resume_cut_points"],
        "strict_rejections": result["strict_transport_and_joint_relations"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
