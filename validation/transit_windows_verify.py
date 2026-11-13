#!/usr/bin/env python3
"""Check confirmation-time windows by independent offline integer grouping.

Existing Decimal/Fraction transit fixtures supply real completed mean-chord
elapsed bounds. This reference groups all supplied outcomes from scratch by
integer quotient and classifies those bounds, without production window code.
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

import evidence_guarded_transit_verify as guarded
import evidence_transit_verify as intervals
import gates_verify as gates
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
MAX = 9223372036854775807
REASONS = ["discontinuity", "expired", "reentered", "reversed", "ambiguous_order"]
STREAM, CHECKPOINT = "--transit-windows", "--transit-windows-checkpoint"
encode, native, run = gates.encode, gates.native, gates.execute
SCOPE = "observed_chord_elapsed_bounds"


def source(transit, width=250000, limits=(0, 1, 100000, 200000, 300000, MAX), origin=0):
    return {"transit": encode(transit), "window_us": str(width),
        "duration_limits_us": [str(value) for value in limits], "origin_us": str(origin)}


def stamp(frame):
    return int(frame["counting"]["counting"]["timestamp_us"])


def initial_fields(upstream, header):
    configuration = upstream["counting"]["configuration"]
    gate = configuration["counting"]
    config = {key: copy.deepcopy(gate[key]) for key in
        ["max_gap_us", "max_tracks", "max_position_std_m"] if key in gate}
    return {"format": "moonground.evidence-transit-windows", "checkpoint_version": "1",
        "session_id": gate["session_id"], "gates": copy.deepcopy(gate["gates"]),
        "sections": copy.deepcopy(upstream["sections"]), "config": config,
        "sigma_multiplier": configuration["sigma_multiplier"],
        "window_us": header["window_us"], "origin_us": header.get("origin_us", "0"),
        "duration_limits_us": header["duration_limits_us"],
        "baseline_timestamp_us": upstream["counting"]["state"]["last_timestamp_us"],
        "baseline_counts": copy.deepcopy(upstream["counts"]),
        "last_timestamp_us": upstream["counting"]["state"]["last_timestamp_us"],
        "counts": copy.deepcopy(upstream["counts"]), "current_window": None}


def offline_window(frames, header, sections):
    """Recount one complete observed bucket; never accumulate rolling counters."""
    first, last = stamp(frames[0]), stamp(frames[-1])
    width, origin = int(header["window_us"]), int(header.get("origin_us", "0"))
    index = (first - origin) // width
    start = origin + index * width
    end = start + width
    assert all((stamp(frame) - origin) // width == index for frame in frames)
    values = []
    for section in sections:
        identity = section["section_id"]
        passages = [item for frame in frames for item in frame["passages"] if item["section_id"] == identity]
        cancellations = [item for frame in frames for item in frame["cancellations"] if item["section_id"] == identity]
        thresholds = []
        for raw in header["duration_limits_us"]:
            limit = int(raw)
            within = sum(int(item["elapsed_upper_us"]) <= limit for item in passages)
            exceeded = sum(int(item["elapsed_lower_us"]) > limit for item in passages)
            thresholds.append({"limit_us": raw, "within": str(within), "exceeded": str(exceeded),
                "indeterminate": str(len(passages) - within - exceeded)})
        values.append({"section_id": identity, "completed": str(len(passages)), "duration_limits": thresholds,
            "cancellations": [{"reason": reason, "count": str(sum(item["reason"] == reason for item in cancellations))}
                for reason in REASONS]})
    return {"start_us": str(start), "end_exclusive_us": str(end) if end <= MAX else None,
        "first_timestamp_us": str(first), "last_timestamp_us": str(last),
        "input_frames": str(len(frames)), "sections": values}


def oracle(upstream, header, frames):
    """Group prefixes offline. Quotients, durations and counts stay Python ints."""
    checkpoint = initial_fields(upstream, header)
    width, origin = int(header["window_us"]), int(header.get("origin_us", "0"))
    buckets, order, outputs = {}, [], []
    for frame in frames:
        timestamp = stamp(frame)
        index = (timestamp - origin) // width
        closed, omitted = None, 0
        if index not in buckets:
            if order:
                closed = offline_window(buckets[order[-1]], header, upstream["sections"])
                omitted = index - order[-1] - 1
            order.append(index)
            buckets[index] = []
        buckets[index].append(frame)
        current = offline_window(buckets[index], header, upstream["sections"])
        outputs.append({"schema_version": "0.1.0", "kind": "evidence_transit_window_frame",
            "session_id": checkpoint["session_id"], "timestamp_us": str(timestamp),
            "closed_window": closed, "current_window": current, "unobserved_windows": str(omitted),
            "classification_scope": SCOPE})
        checkpoint.update(last_timestamp_us=str(timestamp), counts=copy.deepcopy(frame["counts"]),
            current_window=current)
    return outputs, checkpoint


def check_case(binary, name, transit, frames, width=250000, limits=(0, 1, 100000, 200000, 300000, MAX), origin=0):
    header = source(transit, width, limits, origin)
    upstream = native(binary, intervals.CHECKPOINT, [transit], count=1)[0]
    expected, final = oracle(upstream, header, frames)
    actual = native(binary, STREAM, [header] + frames)
    assert actual == expected, name + ": integer offline grouping differs"
    assert native(binary, CHECKPOINT, [header] + frames, count=1)[0] == final, name + ": checkpoint differs"
    for cut in range(len(frames) + 1):
        prefix = native(binary, CHECKPOINT, [header] + frames[:cut], count=1)[0]
        assert prefix == oracle(upstream, header, frames[:cut])[1]
        assert native(binary, STREAM, [{"resume": prefix}] + frames[cut:]) == expected[cut:]
        assert native(binary, CHECKPOINT, [{"resume": prefix}] + frames[cut:], count=1)[0] == final
    return {"name": name, "frames": len(frames), "resume_cut_points": len(frames) + 1,
        "passages": sum(len(frame["passages"]) for frame in frames),
        "cancellations": sum(len(frame["cancellations"]) for frame in frames),
        "closed_windows": sum(value["closed_window"] is not None for value in expected),
        "unobserved_windows": str(sum(int(value["unobserved_windows"]) for value in expected)),
        "checkpoint_sha256": hashlib.sha256(encode(final).encode()).hexdigest()}


def reference_checks(binary):
    results, reasons = [], set()
    for name, transit, measurements in intervals.fixtures():
        frames, _ = intervals.check_sequence(binary, transit, measurements, all_cuts=False)
        reasons.update(item["reason"] for frame in frames for item in frame["cancellations"])
        results.append(check_case(binary, name, transit, frames))
    assert set(REASONS) <= reasons
    zero = intervals.configuration("window-zero-sigma", multiplier=0)
    zero_frames = native(binary, intervals.STREAM, [zero] + intervals.sequence(zero, [(0, -1), (0, 1), (0, 4)]))
    results.append(check_case(binary, "zero_sigma_supported_diagnostics", zero, zero_frames))
    delayed = intervals.configuration("window-long-pending-with-short-crossing-brackets")
    policy = intervals.evidence_source(delayed)
    gate_config = json.loads(policy["counting"])
    gate_config["max_gap_us"] = "300"
    policy["counting"] = encode(gate_config)
    delayed.update(counting=encode(policy), max_duration_us="1000")
    delayed_measurements = intervals.sequence(delayed, [(0, -1), (0, 1), (0, 2), (0, 2), (0, 2), (0, 1), (0, 4)],
        [(0.01, 0, 0.01)] * 2 + [(1, 0, 1)] * 3 + [(0.01, 0, 0.01)] * 2,
        times=[0, 100, 200, 300, 400, 500, 600])
    delayed_frames = native(binary, intervals.STREAM, [delayed] + delayed_measurements)
    assert delayed_frames[-1]["passages"][0]["elapsed_upper_us"] == "600"
    results.append(check_case(binary, "elapsed_bounds_can_exceed_gate_gap", delayed, delayed_frames,
        width=200, limits=(0, 399, 400, 401, 599, 600, MAX)))
    transit = intervals.configuration("window-clock-boundaries")
    for name, times, width, origin in [
        ("one_microsecond_at_2pow53", [9007199254740993 + i for i in range(4)], 1, 9007199254740993),
        ("nonaligned_origin_above_2pow53", [9007199254740993 + i for i in range(4)], 3, 9007199254740992),
        ("exclusive_end_equal_MAX_then_terminal", [MAX - 3 + i for i in range(4)], MAX, 0),
        ("one_microsecond_terminal", [MAX - 3 + i for i in range(4)], 1, 0),
        ("unobserved_giant_gap", [0, MAX], 1, 0),
    ]:
        points = [(0, -1), (0, 1), (0, 2), (0, 4)][:len(times)]
        if name == "unobserved_giant_gap":
            measurements = [intervals.measured(transit, t) for t in times]
        else:
            measurements = intervals.sequence(transit, points, times=times)
        frames = native(binary, intervals.STREAM, [transit] + measurements)
        results.append(check_case(binary, name, transit, frames, width, (0, 1, 2, 3, MAX), origin))
    _, long_source, _ = intervals.fixtures()[-1]
    long_measurements = intervals.sequence(long_source, [(0, -1), (0, 1), (0, 2), (0, 4)], times=[0, 1, MAX - 1, MAX])
    long_frames = native(binary, intervals.STREAM, [long_source] + long_measurements)
    assert long_frames[-1]["passages"][0]["elapsed_upper_us"] == str(MAX)
    results.append(check_case(binary, "elapsed_interval_reaches_Int64_MAX", long_source, long_frames, MAX,
        (0, MAX - 3, MAX - 2, MAX - 1, MAX)))
    # A real pending entry and earlier completed history already exist in this source.
    transit = intervals.configuration("window-started-pending")
    measurements = intervals.sequence(transit, [(0, -1), (0, 1), (0, 4), (0, -1), (0, 1), (0, 4)])
    saved = native(binary, intervals.CHECKPOINT, [transit] + measurements[:5], count=1)[0]
    assert saved["pending"] and int(saved["counts"][0]["completed"]) > 0
    future = native(binary, intervals.STREAM, [{"resume": saved}] + measurements[5:])
    assert future[0]["passages"]
    results.append(check_case(binary, "started_checkpoint_does_not_reconstruct_history", {"resume": saved}, future, 100000))
    initial = native(binary, CHECKPOINT, [source({"resume": saved})], count=1)[0]
    assert initial["current_window"] is None and initial["counts"] == saved["counts"]
    assert initial["last_timestamp_us"] == saved["counting"]["state"]["last_timestamp_us"]
    # Every blocked and projection-control frame remains in the downstream log.
    for name, header, records in [guarded.fixtures()[0], guarded.pending_replacement_fixture()]:
        output = native(binary, "--guarded-transit-evidence", [header] + records)
        nested = json.loads(header["analysis"])
        transit = json.loads(nested["transit"])
        frames = [value["analysis"]["transit"] for value in output]
        results.append(check_case(binary, "guarded_" + name, transit, frames, 100000))
    return {"cases": len(results), **{key: sum(value[key] for value in results) for key in
        ["frames", "resume_cut_points", "passages", "cancellations", "closed_windows"]},
        "all_five_cancellation_reasons": sorted(reasons), "integer_oracle_exact": True,
        "records": results}


def strict_checks(binary):
    transit = intervals.configuration("window-strict")
    measurements = intervals.sequence(transit, [(0, -1), (0, 1), (0, 4), (0, -1)])
    frames = native(binary, intervals.STREAM, [transit] + measurements)
    header = source(transit)
    saved = native(binary, CHECKPOINT, [header] + frames[:3], count=1)[0]
    cases = []

    def bad(name, records, prefix=(), mode=STREAM, payload=None, extra=()):
        values, evidence = run(binary, mode, records, status=2, payload=payload, extra=extra)
        assert values == list(prefix), name + ": complete prefix differs"
        cases.append(dict(name=name, **evidence))

    for name, value in [
        ("missing_transit", {"window_us": "1", "duration_limits_us": ["0"]}),
        ("transit_not_raw", dict(header, transit=transit)),
        ("zero_width", dict(header, window_us="0")),
        ("negative_origin", dict(header, origin_us="-1")),
        ("number_width_not_decimal_string", dict(header, window_us=250000)),
        ("fractional_width_text", dict(header, window_us="1.0")),
        ("noncanonical_width", dict(header, window_us="01")),
        ("empty_limits", dict(header, duration_limits_us=[])),
        ("duplicate_limits", dict(header, duration_limits_us=["1", "1"])),
        ("unordered_limits", dict(header, duration_limits_us=["2", "1"])),
        ("seventeen_limits", dict(header, duration_limits_us=[str(i) for i in range(17)])),
        ("number_limit", dict(header, duration_limits_us=[1])),
        ("overflow_limit", dict(header, duration_limits_us=[str(MAX + 1)])),
        ("unknown_header", dict(header, extra=True)),
        ("duplicate_header", '{"window_us":"1",' + encode(header)[1:]),
    ]:
        bad(name, [value])
    for name, mutate in [
        ("wrong_format", lambda v: v.update(format="moonground.transit")),
        ("wrong_version", lambda v: v.update(checkpoint_version="2")),
        ("unknown_checkpoint_field", lambda v: v.update(extra=True)),
        ("missing_effective_width", lambda v: v.pop("window_us")),
        ("missing_config_gap", lambda v: v["config"].pop("max_gap_us")),
        ("missing_effective_sigma", lambda v: v.pop("sigma_multiplier")),
        ("missing_deadband", lambda v: v["gates"][0].pop("deadband_m")),
        ("baseline_after_watermark", lambda v: v.update(baseline_timestamp_us="200001")),
        ("baseline_count_exceeds_lifetime", lambda v: v["baseline_counts"][0].update(completed="2")),
        ("wrong_current_start", lambda v: v["current_window"].update(start_us="1")),
        ("wrong_current_end", lambda v: v["current_window"].update(end_exclusive_us=None)),
        ("current_last_not_watermark", lambda v: v["current_window"].update(last_timestamp_us="199999")),
        ("first_after_last", lambda v: v["current_window"].update(first_timestamp_us="200001")),
        ("zero_observed_frames", lambda v: v["current_window"].update(input_frames="0")),
        ("too_many_distinct_input_frames", lambda v: v["current_window"].update(input_frames="200002")),
        ("missing_current_with_advanced_watermark", lambda v: v.update(current_window=None)),
        ("window_count_exceeds_new_lifetime", lambda v: v["current_window"]["sections"][0].update(completed="2")),
        ("partition_sum", lambda v: v["current_window"]["sections"][0]["duration_limits"][0].update(indeterminate="2")),
        ("MAX_limit_not_all_within", lambda v: v["current_window"]["sections"][0]["duration_limits"][-1].update(within="0", indeterminate="1")),
        ("zero_limit_within", lambda v: v["current_window"]["sections"][0]["duration_limits"][0].update(within="1", exceeded="0", indeterminate="0")),
        ("wrong_cancellation_order", lambda v: v["current_window"]["sections"][0]["cancellations"].reverse()),
        ("negative_cancellation_count", lambda v: v["current_window"]["sections"][0]["cancellations"][0].update(count="-1")),
        ("cancellation_count_exceeds_observed_frame_capacity", lambda v: v["current_window"]["sections"][0]["cancellations"][0].update(count=str(MAX))),
    ]:
        value = copy.deepcopy(saved)
        mutate(value)
        bad(name, [{"resume": value}])
    good_prefix = native(binary, STREAM, [header] + frames[:2])
    for name, mutate in [
        ("wrong_session", lambda v: v["counting"]["counting"].update(session_id="other")),
        ("duplicate_passage", lambda v: v["passages"].append(copy.deepcopy(v["passages"][0]))),
        ("missing_passage", lambda v: v.update(passages=[])),
        ("omitted_completed_count", lambda v: v["counts"][0].update(completed="0")),
        ("unknown_section", lambda v: v["passages"][0].update(section_id="other")),
        ("bad_elapsed_bound", lambda v: v["passages"][0].update(elapsed_upper_us="199999")),
        ("bad_estimate", lambda v: v["passages"][0].update(estimated_elapsed_us=0)),
        ("wrong_exit_confirmation", lambda v: v["passages"][0]["exit"].update(to_timestamp_us="199999")),
        ("identity_mismatch", lambda v: v["passages"][0]["exit"].update(track_id=2)),
        ("unknown_frame_field", lambda v: v.update(extra=True)),
        ("wrong_crossing_fraction", lambda v: v["passages"][0]["entry"].update(crossing_fraction=0.25)),
        ("evidence_policy_changed", lambda v: v["counting"].update(sigma_multiplier=3)),
        ("evidence_side_changed", lambda v: v["counting"]["evidence"][0].update(side="negative")),
        ("missing_source_exit_crossing", lambda v: v["counting"]["counting"].update(crossings=[])),
    ]:
        value = copy.deepcopy(frames[2])
        mutate(value)
        bad(name, [header] + frames[:2] + [value], good_prefix)
    bad("duplicate_frame", [header, frames[0], frames[0]], good_prefix[:1])
    tiny_pending = encode(frames[0]).replace('"pending_count":0', '"pending_count":1e-999')
    bad("raw_pending_underflow_is_not_zero", [header, tiny_pending])
    exact_zero = encode(frames[0]).replace('"pending_count":0', '"pending_count":0.0e3')
    assert native(binary, STREAM, [header, exact_zero]) == good_prefix[:1]
    raw = encode(frames[2]).replace('"track_id":1', '"track_id":1.0000000000000001', 1)
    bad("raw_fractional_track_identity", [header] + frames[:2] + [raw], good_prefix)
    bad("late_error_no_checkpoint", [header] + frames[:2] + [dict(frames[2], extra=True)], mode=CHECKPOINT)
    bad("invalid_utf8_tail", [], good_prefix, payload=gates.lines([header] + frames[:2]).encode() + b"\xff\n")
    value = copy.deepcopy(saved)
    limits = value["current_window"]["sections"][0]["duration_limits"]
    limits[2].update(within="1", exceeded="0", indeterminate="0")
    limits[3].update(within="0", exceeded="0", indeterminate="1")
    bad("nonmonotone_within_across_thresholds", [{"resume": value}])
    # The public checkpoint contract checks local aggregate consistency rather
    # than authenticating an unrecorded event history. Exhaust a cancellation
    # slot in an accepted detached state, then exercise the real increment guard.
    cancelled_measurements = intervals.sequence(transit, [(0, -1), (0, 1), None])
    cancelled_frames = native(binary, intervals.STREAM, [transit] + cancelled_measurements)
    assert cancelled_frames[-1]["cancellations"][0]["reason"] == "discontinuity"
    exhausted = native(binary, CHECKPOINT, [header] + cancelled_frames[:2], count=1)[0]
    exhausted.update(window_us=str(MAX), last_timestamp_us=str(MAX - 2))
    exhausted["current_window"].update(start_us="0", end_exclusive_us=str(MAX),
        first_timestamp_us="0", last_timestamp_us=str(MAX - 2), input_frames=str(MAX - 1))
    exhausted["current_window"]["sections"][0]["cancellations"][0]["count"] = str(MAX)
    assert native(binary, CHECKPOINT, [{"resume": exhausted}], count=1)[0] == exhausted
    corrected = copy.deepcopy(cancelled_frames[-1])
    corrected["counting"]["counting"]["timestamp_us"] = str(MAX - 1)
    bad("late_cancellation_count_overflow", [{"resume": exhausted}, corrected])
    bad("late_cancellation_overflow_no_checkpoint", [{"resume": exhausted}, corrected], mode=CHECKPOINT)
    corrected["cancellations"] = []
    recovered = native(binary, CHECKPOINT, [{"resume": exhausted}, corrected], count=1)[0]
    assert recovered["last_timestamp_us"] == corrected["counting"]["counting"]["timestamp_us"]
    assert recovered["current_window"]["sections"][0]["cancellations"][0]["count"] == str(MAX)
    assert native(binary, STREAM, [{"resume": saved}, frames[3]]) == native(binary, STREAM, [header] + frames)[3:]
    return {"rejected_cases": len(cases), "cases": cases, "complete_prefix_preserved": True,
        "same_timestamp_correction_from_saved_state": True,
        "synthetic_exhausted_cancellation_slot_checked_without_history_authentication": True}


def transport_checks(binary):
    transit = intervals.configuration("window-transport")
    measurements = intervals.sequence(transit, [(0, -1), (0, 4)])
    frames = native(binary, intervals.STREAM, [transit] + measurements)
    header = source(transit)
    expected = native(binary, STREAM, [header] + frames)
    for ending in [b"\n", b"\r\n"]:
        assert run(binary, STREAM, payload=ending.join(encode(value).encode() for value in [header] + frames))[0] == expected
    saved = native(binary, CHECKPOINT, [header], count=1)[0]
    exact = encode({"resume": saved}).ljust(8388619)
    assert native(binary, CHECKPOINT, [exact], count=1, extra=["--max-line-bytes", "16777216"])[0] == saved
    _, rejected = run(binary, CHECKPOINT, [exact + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    # Window inputs are old native output and may legitimately exceed 1 MiB.
    wide = encode(frames[0]).ljust(1048577)
    _, physical = run(binary, CHECKPOINT, [header, wide], status=2, count=0)
    assert native(binary, STREAM, [header, wide], extra=["--max-line-bytes", "16777216"]) == expected[:1]
    return {"crlf_and_unterminated_eof": "passed", "exact_source_utf16_units": len(exact),
        "source_one_unit_overflow": rejected, "default_native_physical_limit": physical,
        "native_frame_over_1MiB_with_explicit_line_budget": True}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/transit-windows.test.mjs"]
    completed = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=360)
    if completed.returncode:
        raise AssertionError("Node transit windows failed:\n" + completed.stdout[-18000:] + completed.stderr[-2000:])
    summary, directions = {}, None
    for value in completed.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", value)
        if match:
            summary[match.group(1)] = int(match.group(2))
        if value.startswith('# {"cut_points":'):
            directions = json.loads(value[2:])
    assert summary.get("tests") and summary["pass"] == summary["tests"] and not summary["fail"]
    assert directions is not None
    return {"status": "passed", "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "command": " ".join(command), "summary": summary, "cross_runtime": directions,
        "test_script_sha256": hashlib.sha256((ROOT / "web/transit-windows.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(), "stderr": completed.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/transit-windows-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "fixtures": "deterministic",
        "command": " ".join(shlex.quote(value) for value in [sys.executable] + sys.argv),
        "python": platform.python_version(), "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "transit_reference_sha256": hashlib.sha256(Path(intervals.__file__).read_bytes()).hexdigest(),
        "guarded_fixture_sha256": hashlib.sha256(Path(guarded.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "classification_scope": SCOPE}
    result["offline_integer_grouping"] = reference_checks(binary)
    result["strict_transport_and_relations"] = strict_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result.update(elapsed_seconds=time.perf_counter() - started, status="passed")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "output": str(args.output),
        "cases": result["offline_integer_grouping"]["cases"], "frames": result["offline_integer_grouping"]["frames"],
        "resume_cut_points": result["offline_integer_grouping"]["resume_cut_points"],
        "strict_rejections": result["strict_transport_and_relations"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
