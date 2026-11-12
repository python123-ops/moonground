#!/usr/bin/env python3
"""Independent gate-pair timing with NumPy geometry and exact Fraction time.

The existing --count path supplies native crossing documents. A separate NumPy
intersection oracle checks those events, then Python matches sections using
exact integer brackets and Fraction.from_float for interpolation fractions.
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

import gates_verify as gates
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
encode = gates.encode
lines = gates.lines


def run(binary, mode, records=(), status=0, count=None, payload=None, extra=()):
    return gates.execute(binary, mode, records, status=status, count=count, payload=payload, extra=extra)


def native(binary, mode, records=(), **kwargs):
    return run(binary, mode, records, **kwargs)[0]


def section(identity="forward", entry="entry", exit="exit", direction="negative_to_positive"):
    return {"section_id": identity, "entry_gate_id": entry, "entry_direction": direction,
        "exit_gate_id": exit, "exit_direction": direction}


def configuration(name="transit-reference", band=0.05, duration="300000000", reverse_gates=False):
    values = [gates.gate("entry", (-1, 0), (1, 0), band), gates.gate("exit", (-1, 3), (1, 3), band)]
    counting = gates.configuration(name=name, gates=values[::-1] if reverse_gates else values)
    counting["max_tracks"] = 16
    return {"counting": encode(counting), "sections": [section(), section("backward", "exit", "entry", "positive_to_negative")],
        "max_duration_us": duration}


def measured(config, timestamp, point=None, identity=1, segment="1", status="ready", std=0.1, closed=()):
    name = json.loads(config["counting"])["session_id"]
    tracks = [] if point is None else [gates.track(identity, point, timestamp, segment=segment, status=status, std=std)]
    return gates.measurement(timestamp, tracks, closed=closed, name=name)


def sequence(config, points, times=None, start=0):
    times = times or [index * 100000 for index in range(len(points))]
    return [measured(config, start + stamp, point) for point, stamp in zip(points, times)]


def fixtures():
    values = []
    config = configuration()
    points = [(0, -1), (0, 1), (0, 2), (0, 4), (0, 2), (0, 1), (0, -1)]
    values.append(("separate_brackets_both_directions", config, sequence(config, points)))
    config = configuration("transit-same-chord", reverse_gates=True)
    values.append(("same_frame_reverse_configuration_order", config, sequence(config, [(0, -1), (0, 4), (0, -1)])))
    for name, base in [("above_2pow53", 9007199254740993), ("int64_max", 9223372036854775804)]:
        config = configuration("transit-" + name, reverse_gates=True)
        values.append((name + "_microsecond_intervals", config, sequence(config, [(0, -1), (0, 1), (0, 2), (0, 4)], [0, 1, 2, 3], base)))
        values.append((name + "_fractional_same_frame", config, sequence(config, [(0, -1), (0, 4)], [0, 1], base)))
    config = configuration("transit-reentered")
    values.append(("finite_extension_reentry_replaces_start", config,
        sequence(config, [(0, -1), (0, 1), (2, 1), (2, -1), (0, -1), (0, 1), (0, 4)])))
    values.append(("same_frame_reentry_then_completion", config,
        sequence(config, [(0, -1), (0, 1), (2, 1), (2, -1), (0, -1), (0, 4)])))
    config = configuration("transit-exit-before-entry")
    counting = json.loads(config["counting"])
    counting["gates"] = [gates.gate("entry", (0, -1), (0, 1)), gates.gate("exit", (-1, 0), (1, 0))]
    config["counting"] = encode(counting)
    config["sections"] = [dict(section(), entry_direction="positive_to_negative")]
    values.append(("same_frame_exit_completes_old_then_entry_starts_new", config,
        sequence(config, [(-0.5, -0.5), (0.5, -0.5), (0.5, -2), (-0.5, -2), (-0.5, -0.5), (0.5, 1.5)])))
    config = configuration("transit-ambiguous", band=0.1)
    gates_config = json.loads(config["counting"])
    gates_config["gates"][1]["start_m"][1] = 0.5
    gates_config["gates"][1]["end_m"][1] = 0.5
    config["counting"] = encode(gates_config)
    values.append(("overlapping_different_chords_are_ambiguous", config, sequence(config, [(0, -1), (0, 0.05), (0, 1)])))
    config = configuration("transit-expiration", duration="200000")
    values.append(("expiration_confirmation_boundary", config,
        sequence(config, [(0, -1), (0, 1), (0, 2), (0, 4)], [0, 100000, 299999, 300000])))
    values.append(("discontinuity_precedes_expiration", config,
        [measured(config, 0, (0, -1)), measured(config, 100000, (0, 1)), measured(config, 600000)]))
    for interruption in ["missing", "rejected_projection", "rejected_innovation", "numerical_failure", "quality", "closed", "gap"]:
        config = configuration("transit-interruption-" + interruption)
        gates_config = json.loads(config["counting"])
        if interruption == "quality":
            gates_config["max_position_std_m"] = 0.15
            config["counting"] = encode(gates_config)
        records = sequence(config, [(0, -1), (0, 1)])
        if interruption == "missing":
            middle = measured(config, 200000)
        elif interruption == "closed":
            middle = measured(config, 200000, (0, 2), segment="2", closed=["1"])
        elif interruption == "gap":
            middle = measured(config, 600000, (0, 2))
        else:
            middle = measured(config, 200000, (0, 2), status=interruption if interruption.startswith("rejected") or interruption == "numerical_failure" else "uncertain",
                std=0.2 if interruption == "quality" else 0.1)
        records += [middle, measured(config, int(middle["timestamp_us"]) + 100000, (0, 4), segment="2" if interruption == "closed" else "1")]
        values.append(("cancel_" + interruption, config, records))
    config = configuration("transit-reversal")
    values.append(("reverse_entry_cancels_pending", config, sequence(config, [(0, -1), (0, 1), (0, -1), (0, 4)])))
    config = configuration("transit-blocked-empty")
    # This is exactly the measurement emitted by a guarded interruption: close
    # the live segment and provide no stale position or fabricated zero speed.
    values.append(("guarded_interrupt_closes_pending", config, [measured(config, 0, (0, -1)),
        measured(config, 100000, (0, 1)), measured(config, 200000, closed=["1"]),
        measured(config, 300000, (0, 4), segment="2")]))
    return values


def before(a, b):
    if int(a["to_timestamp_us"]) <= int(b["from_timestamp_us"]):
        return True
    same = all(a[key] == b[key] for key in ["from_timestamp_us", "to_timestamp_us", "from_position_m", "to_position_m"])
    return same and Fraction.from_float(a["crossing_fraction"]) < Fraction.from_float(b["crossing_fraction"])


def exact_time(event):
    first, last = int(event["from_timestamp_us"]), int(event["to_timestamp_us"])
    return Fraction(first) + Fraction.from_float(event["crossing_fraction"]) * (last - first)


class Oracle:
    def __init__(self, config):
        self.sections = config["sections"]
        source = json.loads(config["counting"])
        self.counting = source["resume"]["configuration"] if "resume" in source else source
        self.duration = int(config["max_duration_us"])
        self.pending = {}
        self.counts = [0] * len(self.sections)
        self.last = int(source["resume"]["state"]["last_timestamp_us"]) if "resume" in source and source["resume"]["state"]["last_timestamp_us"] is not None else None

    def update(self, frame, counting):
        timestamp = int(frame["timestamp_us"])
        quality = self.counting.get("max_position_std_m")
        accepted = {item["track_id"]: item["segment_id"] for item in frame["tracks"] if
            item["status"] in ("initializing", "ready", "uncertain") and item["position_m"] is not None and
            int(item["last_accepted_timestamp_us"]) == timestamp and
            (quality is None or item["position_std_m"] is not None and item["position_std_m"] <= quality)}
        continuous = self.last is not None and timestamp - self.last < int(self.counting.get("max_gap_us", "500000"))
        passages, cancellations = [], []
        for index, section in enumerate(self.sections):
            events = {}
            for event in counting["crossings"]:
                if event["gate_id"] in (section["entry_gate_id"], section["exit_gate_id"]):
                    events.setdefault(event["track_id"], []).append(event)
            identities = sorted(set(identity for pair, identity in self.pending if pair == index) | set(events))
            for identity in identities:
                key = index, identity

                def cancel(reason):
                    old = self.pending.pop(key)
                    cancellations.append({"section_id": section["section_id"], "track_id": identity,
                        "segment_id": old["segment_id"], "reason": reason, "entry": old})

                if key in self.pending:
                    old = self.pending[key]
                    if not continuous or accepted.get(identity) != old["segment_id"]:
                        cancel("discontinuity")
                    elif timestamp - int(old["to_timestamp_us"]) >= self.duration:
                        cancel("expired")
                current = events.get(identity, [])
                entry = next((v for v in current if v["gate_id"] == section["entry_gate_id"]), None)
                exit = next((v for v in current if v["gate_id"] == section["exit_gate_id"]), None)
                if entry is not None and exit is not None and not before(entry, exit) and not before(exit, entry):
                    if key in self.pending:
                        cancel("ambiguous_order")
                    elif entry["direction"] == section["entry_direction"]:
                        self.pending[key] = entry
                        cancel("ambiguous_order")
                    continue
                ordered = [entry, exit] if entry is None or exit is None or before(entry, exit) else [exit, entry]
                for event in ordered:
                    if event is None:
                        continue
                    is_entry = event["gate_id"] == section["entry_gate_id"]
                    expected_direction = section["entry_direction"] if is_entry else section["exit_direction"]
                    if event["direction"] != expected_direction:
                        if key in self.pending:
                            cancel("reversed")
                    elif is_entry:
                        if key in self.pending:
                            cancel("reentered")
                        self.pending[key] = event
                    elif key in self.pending:
                        old = self.pending[key]
                        if not before(old, event):
                            cancel("ambiguous_order")
                            continue
                        elapsed = exact_time(event) - exact_time(old)
                        if elapsed <= 0:
                            raise AssertionError("proved event order yielded nonpositive rational duration")
                        lower = max(0, int(event["from_timestamp_us"]) - int(old["to_timestamp_us"]))
                        upper = int(event["to_timestamp_us"]) - int(old["from_timestamp_us"])
                        passages.append({"section_id": section["section_id"], "track_id": identity,
                            "segment_id": old["segment_id"], "entry": old, "exit": event,
                            "elapsed_lower_us": str(lower), "elapsed_upper_us": str(upper),
                            "estimated_elapsed_us": float(elapsed)})
                        self.counts[index] += 1
                        self.pending.pop(key)
        self.last = timestamp
        return {"schema_version": "0.1.0", "kind": "transit_events", "counting": counting,
            "passages": passages, "counts": [{"section_id": v["section_id"], "completed": str(self.counts[i])} for i, v in enumerate(self.sections)],
            "cancellations": cancellations, "pending_count": len(self.pending)}


def reference_checks(binary):
    errors, records, reasons = {}, [], set()
    total = cuts = passages = 0
    for name, config, frames in fixtures():
        counted = native(binary, "--count", [json.loads(config["counting"])] + frames)
        geometry = gates.Oracle(json.loads(config["counting"]))
        oracle = Oracle(config)
        actual = native(binary, "--transit", [config] + frames)
        for measured, gate_output, transit in zip(frames, counted, actual):
            gates.tree_close(gate_output, geometry.update(measured), errors)
            expected = oracle.update(measured, gate_output)
            gates.tree_close(transit, expected, errors)
            reasons.update(item["reason"] for item in transit["cancellations"])
            passages += len(transit["passages"])
        if len(actual) != len(frames):
            raise AssertionError("transit frame count differs")
        saved = native(binary, "--transit-checkpoint", [config] + frames, count=1)[0]
        if saved["counting"] != native(binary, "--count-checkpoint", [json.loads(config["counting"])] + frames, count=1)[0]:
            raise AssertionError("transit changed the original gate checkpoint")
        if saved["counts"] != [{"section_id": v["section_id"], "completed": str(oracle.counts[i])} for i, v in enumerate(config["sections"])]:
            raise AssertionError("checkpoint section totals differ")
        expected_pending = [{"section_id": config["sections"][index]["section_id"], "entry": entry}
            for (index, identity), entry in sorted(oracle.pending.items())]
        if saved["pending"] != expected_pending:
            raise AssertionError("checkpoint pending entries differ")
        for cut in range(len(frames) + 1):
            prefix = native(binary, "--transit-checkpoint", [config] + frames[:cut], count=1)[0]
            if native(binary, "--transit", [{"resume": prefix}] + frames[cut:]) != actual[cut:]:
                raise AssertionError("{} cut {} differs".format(name, cut))
            if native(binary, "--transit-checkpoint", [{"resume": prefix}] + frames[cut:], count=1)[0] != saved:
                raise AssertionError("{} cut {} loses durable state".format(name, cut))
            cuts += 1
        records.append({"name": name, "frames": len(frames), "checkpoint_sha256": hashlib.sha256(encode(saved).encode()).hexdigest()})
        total += len(frames)
    if not {"discontinuity", "expired", "reentered", "reversed", "ambiguous_order"}.issubset(reasons):
        raise AssertionError("missing cancellation branches: " + str(reasons))
    return {"cases": len(records), "frames": total, "passages": passages, "resume_cut_points": cuts,
        "cancellation_reasons": sorted(reasons), "maximum_absolute_oracle_errors": errors, "records": records}


def rejection_checks(binary):
    config = configuration("transit-strict")
    frames = sequence(config, [(0, -1), (0, 1), (0, 2), (0, 4)])
    saved = native(binary, "--transit-checkpoint", [config] + frames[:2], count=1)[0]
    prefix = native(binary, "--transit", [config, frames[0]])
    cases = []

    def bad(name, values, expected=(), mode="--transit", payload=None, extra=()):
        actual, evidence = run(binary, mode, values, status=2, payload=payload, extra=extra)
        if actual != list(expected):
            raise AssertionError(name + ": failure exposed a checkpoint or lost complete prefix")
        cases.append(dict(name=name, **evidence))

    for name, mutate in [
        ("unknown_source_key", lambda v: v.update(extra=True)),
        ("source_counting_object", lambda v: v.update(counting=json.loads(v["counting"]))),
        ("empty_sections", lambda v: v.update(sections=[])),
        ("duplicate_section_identity", lambda v: v["sections"].append(copy.deepcopy(v["sections"][0]))),
        ("unknown_entry_gate", lambda v: v["sections"][0].update(entry_gate_id="unknown")),
        ("invalid_direction", lambda v: v["sections"][0].update(entry_direction="forward")),
        ("same_entry_exit_gate", lambda v: v["sections"][0].update(exit_gate_id="entry")),
        ("zero_confirmation_deadline", lambda v: v.update(max_duration_us="0")),
        ("unknown_section_field", lambda v: v["sections"][0].update(extra=True)),
    ]:
        invalid = copy.deepcopy(config)
        mutate(invalid)
        bad(name, [invalid])
    bad("duplicate_source_key", ['{"counting":"bad",' + encode(config)[1:]])
    malformed = copy.deepcopy(config)
    malformed["counting"] = malformed["counting"].replace('"max_tracks":16', '"max_tracks":16.0000000000000001')
    bad("raw_fractional_gate_capacity", [malformed])
    for name, mutate in [
        ("unknown_measurement_key", lambda v: v.update(extra=True)),
        ("duplicate_track", lambda v: v["tracks"].append(copy.deepcopy(v["tracks"][0]))),
        ("same_timestamp", lambda v: v.update(timestamp_us="0")),
        ("wrong_session", lambda v: v.update(session_id="other")),
        ("invalid_position_covariance", lambda v: v["tracks"][0].update(position_covariance=[1, 2, 1])),
    ]:
        invalid = copy.deepcopy(frames[1])
        mutate(invalid)
        bad(name, [config, frames[0], invalid], prefix)
    bad("raw_fractional_track", [config, frames[0], encode(frames[1]).replace('"track_id":1', '"track_id":1.0000000000000001')], prefix)
    bad("duplicate_measurement_key", [config, frames[0], '{"timestamp_us":"1",' + encode(frames[1])[1:]], prefix)
    bad("invalid_utf8", [], prefix, payload=lines([config, frames[0]]).encode() + b"\xff\n")
    bad("blank_measurement", [config, frames[0], ""], prefix)
    bad("late_error_no_checkpoint", [config, frames[0], dict(frames[1], extra=True)], mode="--transit-checkpoint")
    for name, mutate in [
        ("wrong_checkpoint_format", lambda v: v.update(format="other")),
        ("wrong_checkpoint_version", lambda v: v.update(checkpoint_version="2")),
        ("unknown_checkpoint_field", lambda v: v.update(extra=True)),
        ("missing_completed_count", lambda v: v.update(counts=[])),
        ("negative_completed_count", lambda v: v["counts"][0].update(completed="-1")),
        ("unearned_completed_count", lambda v: v["counts"][0].update(completed="2")),
        ("unknown_pending_section", lambda v: v["pending"][0].update(section_id="unknown")),
        ("duplicate_pending_identity", lambda v: v["pending"].append(copy.deepcopy(v["pending"][0]))),
        ("wrong_pending_segment", lambda v: v["pending"][0]["entry"].update(segment_id="2")),
        ("wrong_pending_direction", lambda v: v["pending"][0]["entry"].update(direction="positive_to_negative")),
        ("wrong_pending_gate", lambda v: v["pending"][0]["entry"].update(gate_id="exit")),
        ("pending_fraction_corrupted", lambda v: v["pending"][0]["entry"].update(crossing_fraction=0.25)),
        ("pending_crossing_point_corrupted", lambda v: v["pending"][0]["entry"].update(position_m=[0.1, 0])),
        ("pending_future_confirmation", lambda v: v["pending"][0]["entry"].update(to_timestamp_us="100001")),
        ("pending_no_current_qualified_track", lambda v: v["counting"]["state"].update(tracks=[])),
    ]:
        invalid = copy.deepcopy(saved)
        mutate(invalid)
        bad(name, [{"resume": invalid}])
    bad("resume_override", [{"resume": saved, "sections": config["sections"]}])
    expired = native(binary, "--transit-checkpoint", [config] + frames[:3], count=1)[0]
    expired["max_duration_us"] = "100000"
    bad("pending_confirmation_deadline_equality", [{"resume": expired}])
    oversized_bracket = copy.deepcopy(saved)
    oversized_bracket["counting"]["configuration"]["max_gap_us"] = "100000"
    bad("pending_bracket_reaches_gate_gap_limit", [{"resume": oversized_bracket}])
    used_entry = copy.deepcopy(saved)
    used_entry["counts"][0]["completed"] = "1"
    used_entry["counting"]["state"]["counts"][1]["negative_to_positive"] = "1"
    bad("pending_exceeds_uncompleted_entry_total", [{"resume": used_entry}])
    # Restore a valid but exhausted gate counter; the next exit must fail before
    # either gate totals or the in-flight transit are committed.
    saturated = copy.deepcopy(saved)
    for count in saturated["counting"]["state"]["counts"]:
        count.update(negative_to_positive="9223372036854775807", positive_to_negative="9223372036854775807")
    safe_prefix = native(binary, "--transit", [{"resume": saturated}, frames[2]])
    bad("gate_counter_overflow_atomic", [{"resume": saturated}] + frames[2:], safe_prefix)
    bad("gate_counter_overflow_no_checkpoint", [{"resume": saturated}] + frames[2:], mode="--transit-checkpoint")
    correction = measured(config, 300000, (0, 2))
    corrected = native(binary, "--transit-checkpoint", [{"resume": saturated}, correction], count=1)[0]
    if corrected["pending"] != saved["pending"] or corrected["counts"] != saved["counts"]:
        raise AssertionError("safe same-time correction changed the pending passage or totals")
    return {"rejected_cases": len(cases), "cases": cases, "complete_prefix_preserved": True,
        "saturated_gate_checkpoint_safe_retry": "passed"}


def started_source_checks(binary):
    config = configuration("transit-started-gates")
    counting = json.loads(config["counting"])
    history = sequence(config, [(0, -1), (0, 1)])
    prior = native(binary, "--count-checkpoint", [counting] + history, count=1)[0]
    source = dict(config, counting=encode({"resume": prior}))
    future = [measured(config, 200000, (0, 4)), measured(config, 300000, (0, -1))]
    actual = native(binary, "--transit", [source] + future)
    expected_gates = native(binary, "--count", [{"resume": prior}] + future)
    geometry = gates.Oracle(counting)
    for frame in history:
        geometry.update(frame)
    oracle = Oracle(source)
    errors = {}
    for frame, gate_output, output in zip(future, expected_gates, actual):
        gates.tree_close(gate_output, geometry.update(frame), errors)
        gates.tree_close(output, oracle.update(frame, gate_output), errors)
    if actual[0]["passages"] or actual[0]["pending_count"]:
        raise AssertionError("starting a transit counter reconstructed an old entry")
    if len(actual[1]["passages"]) != 1 or actual[1]["passages"][0]["section_id"] != "backward":
        raise AssertionError("new reverse journey after starting was not measured")
    return {"historical_entry_ignored": True, "future_frames": len(future),
        "maximum_absolute_oracle_errors": errors}


def transport_checks(binary):
    config = configuration("transit-transport")
    frames = sequence(config, [(0, -1), (0, 4)])
    expected = native(binary, "--transit", [config] + frames)
    for ending in [b"\n", b"\r\n"]:
        actual = run(binary, "--transit", payload=ending.join(encode(v).encode() for v in [config] + frames))[0]
        if actual != expected:
            raise AssertionError("line ending or unterminated EOF changed transit")
    exact = max(len(encode(v).encode()) for v in [config] + frames)
    if native(binary, "--transit", [config] + frames, extra=["--max-line-bytes", str(exact)]) != expected:
        raise AssertionError("exact physical line boundary failed")
    saved = native(binary, "--transit-checkpoint", [config], count=1)[0]
    padded = encode({"resume": saved}).ljust(8388619)
    if native(binary, "--transit-checkpoint", [padded], count=1, extra=["--max-line-bytes", "16777216"])[0] != saved:
        raise AssertionError("exact resume source limit changed state")
    _, failure = run(binary, "--transit-checkpoint", [padded + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    return {"crlf_and_unterminated_eof": "passed", "exact_physical_line_bytes": exact,
        "exact_source_utf16_units": 8388619, "source_one_unit_overflow": failure}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/transit.test.mjs"]
    completed = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=300)
    if completed.returncode:
        raise AssertionError("Node transit verification failed:\n" + completed.stdout[-18000:] + completed.stderr[-2000:])
    summary, directions, load = {}, None, None
    for value in completed.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", value)
        if match:
            summary[match.group(1)] = int(match.group(2))
        if value.startswith('# {"cut_points":'):
            directions = json.loads(value[2:])
        if value.startswith('# {"pending_load":'):
            load = json.loads(value[2:])
    if not summary.get("tests") or summary.get("pass") != summary["tests"] or summary.get("fail") or directions is None or load is None:
        raise AssertionError("incomplete Node summary or runtime directions")
    return {"status": "passed", "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "command": " ".join(command), "summary": summary, "cross_runtime": directions, "measured_load": load,
        "test_script_sha256": hashlib.sha256((ROOT / "web/transit.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(), "stderr": completed.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/transit-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "fixtures": "deterministic", "command": " ".join(shlex.quote(v) for v in [sys.executable] + sys.argv),
        "python": platform.python_version(), "numpy": np.__version__, "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "gate_reference_sha256": hashlib.sha256(Path(gates.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["fraction_and_geometry_reference"] = reference_checks(binary)
    result["strict_transport"] = rejection_checks(binary)
    result["started_gate_source"] = started_source_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    result["status"] = "passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "output": str(args.output),
        "cases": result["fraction_and_geometry_reference"]["cases"], "frames": result["fraction_and_geometry_reference"]["frames"],
        "resume_cut_points": result["fraction_and_geometry_reference"]["resume_cut_points"],
        "strict_rejections": result["strict_transport"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
