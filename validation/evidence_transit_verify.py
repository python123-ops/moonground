#!/usr/bin/env python3
"""Independent covariance-evidence gate-pair timing and durable-state checks.

The existing --count-evidence owner supplies host events. Decimal/Fraction and
NumPy check its normal bands and finite mean chords independently; the existing
Python transit oracle pairs those events using exact integer time brackets.
Pending endpoint covariances come from the original measurements/anchors.
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

import evidence_verify as evidence
import gates_verify as gates
import guarded_verify as guarded
import projection_replace_verify as replacement
import transit_verify as transit
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
encode, native, run = gates.encode, gates.native, gates.execute
STREAM, CHECKPOINT = "--transit-evidence", "--transit-evidence-checkpoint"


def configuration(name="evidence-transit-reference", multiplier=2):
    value = transit.configuration(name)
    value["counting"] = encode({"counting": value["counting"], "sigma_multiplier": multiplier})
    return value


def evidence_source(source):
    return json.loads(source["counting"])


def old_source(source):
    inner = evidence_source(source)
    config = inner["resume"]["configuration"]["counting"] if "resume" in inner else json.loads(inner["counting"])
    return dict(source, counting=encode(config))


def measured(source, timestamp, point=None, covariance=(0.01, 0, 0.01), **kwargs):
    return evidence.measured(evidence_source(source), timestamp, point, covariance, **kwargs)


def sequence(source, points, covariances=None, times=None, start=0):
    return evidence.sequence(evidence_source(source), points, covariances, times, start)


def fixtures():
    values = []
    for name, old, frames in transit.fixtures():
        source = dict(old, counting=encode({"counting": old["counting"], "sigma_multiplier": 2}))
        values.append((name, source, frames))
    source = configuration("evidence-transit-delayed")
    values.append(("same_frame_different_anchors_are_ambiguous", source,
        sequence(source, [(0, -1), (0, 1), (0, 4)], [(0.01, 0, 0.01), (0.36, 0, 0.36), (0.01, 0, 0.01)])))
    values.append(("unconfirmed_retains_pending_without_refreshing_entry", source,
        sequence(source, [(0, -1), (0, 1), (0, 2), (0, 4)],
            [(0.01, 0, 0.01), (0.01, 0, 0.01), (1, 0, 1), (0.01, 0, 0.01)])))
    values.append(("unconfirmed_anchor_ttl_reaches_exact_gap", source,
        sequence(source, [(0, -1), (0, 1), (0, 2), (0, 2), (0, 4)],
            [(0.01, 0, 0.01), (0.01, 0, 0.01), (4, 0, 4), (4, 0, 4), (0.01, 0, 0.01)], [0, 100000, 400000, 600000, 700000])))
    source = configuration("evidence-transit-changing-covariance")
    values.append(("pending_preserves_original_covariances_after_anchor_moves", source,
        sequence(source, [(0, -1), (0, 1), (0, 2), (0, 4)],
            [(0.04, 0.01, 0.01), (0.01, -0.002, 0.04), (0.02, 0.003, 0.01), (0.01, 0, 0.01)])))
    source = configuration("evidence-transit-rotated")
    original = old_source(source)
    config = json.loads(original["counting"])
    config["gates"] = [gates.gate("exit", (-2, 2), (0, 4)), gates.gate("entry", (-1, -1), (1, 1))]
    source["counting"] = encode({"counting": encode(config), "sigma_multiplier": 3})
    values.append(("rotated_anisotropic_covariance", source,
        sequence(source, [(1, -1), (-0.5, 0.5), (-2.5, 2.5), (1, -1)],
            [(0.01, 0.004, 0.04), (0.04, -0.006, 0.01), (0.02, 0.005, 0.02), (0.01, 0, 0.01)])))
    source = configuration("evidence-transit-multiple-identities")
    records = sequence(source, [(0, -1), (0, 1), (0, 4)])
    for frame in records:
        track = copy.deepcopy(frame["tracks"][0])
        track.update(track_id=2, segment_id="2")
        frame["tracks"].insert(0, track)
    values.append(("section_order_then_sorted_track_ids", source, records))
    source = configuration("evidence-transit-long-span")
    inner = evidence_source(source)
    config = json.loads(inner["counting"])
    config["max_gap_us"] = "9223372036854775807"
    inner["counting"] = encode(config)
    source.update(counting=encode(inner), max_duration_us="9223372036854775807")
    values.append(("long_int64_chord_converts_only_elapsed_difference", source,
        sequence(source, [(0, -1), (0, 4)], times=[0, 9223372036854775806])))
    return values


def event_key(event):
    return (event["track_id"], event["segment_id"], event["gate_id"], event["from_timestamp_us"],
        event["to_timestamp_us"], tuple(event["from_position_m"]), tuple(event["to_position_m"]))


class PairOracle(transit.Oracle):
    """Reuse the independent pre-evidence pairing algorithm, preserving witnesses."""

    def __init__(self, source):
        super().__init__(old_source(source))
        inner = evidence_source(source)
        if "resume" in inner:
            self.last = (None if inner["resume"]["state"]["last_timestamp_us"] is None else
                int(inner["resume"]["state"]["last_timestamp_us"]))
        self.witnesses = {}

    def update_evidence(self, frame, counted, previous_tracks):
        original = {value["track_id"]: value for value in frame["tracks"]}
        indexes = {value["gate_id"]: index for index, value in enumerate(self.counting["gates"])}
        for event in counted["counting"]["crossings"]:
            old = previous_tracks[event["track_id"]]["anchors"][indexes[event["gate_id"]]]
            assert old["timestamp_us"] == event["from_timestamp_us"]
            self.witnesses[event_key(event)] = (copy.deepcopy(old["covariance"]),
                copy.deepcopy(original[event["track_id"]]["position_covariance"]))
        result = super().update(frame, counted["counting"])
        result.update(kind="evidence_transit_frame", counting=counted)
        active = {event_key(value) for value in self.pending.values()}
        self.witnesses = {key: value for key, value in self.witnesses.items() if key in active}
        return result

    def pending_documents(self):
        values = []
        for (index, identity), entry in sorted(self.pending.items()):
            first, last = self.witnesses[event_key(entry)]
            values.append({"section_id": self.sections[index]["section_id"], "entry": entry,
                "from_covariance": first, "to_covariance": last})
        return values


def check_sequence(binary, source, frames, all_cuts=True):
    inner = evidence_source(source)
    empty = native(binary, "--evidence-checkpoint", [inner], count=1)[0]
    canonical = empty["configuration"]["counting"]
    normal = evidence.Oracle(inner, canonical)
    paired = PairOracle(source)
    counted = native(binary, "--count-evidence", [inner] + frames)
    actual = native(binary, STREAM, [source] + frames)
    absolute, scaled, time_errors = {}, {}, {}
    elapsed_errors = {"maximum_absolute_error_us": 0, "maximum_relative_error": 0,
        "maximum_absolute_error_us_when_upper_bound_at_most_1000000": 0}
    snapshots = []
    for frame, host, output in zip(frames, counted, actual):
        previous = copy.deepcopy(normal.tracks)
        evidence.compare_frame(host, normal.update(frame), absolute, scaled)
        expected = paired.update_evidence(frame, host, previous)
        gates.tree_close(output, expected, time_errors)
        snapshots.append(paired.pending_documents())
        for passage in output["passages"]:
            elapsed = transit.exact_time(passage["exit"]) - transit.exact_time(passage["entry"])
            assert int(passage["elapsed_lower_us"]) <= elapsed <= int(passage["elapsed_upper_us"])
            # JSON may print an integral Double without a decimal point. Read
            # its binary64 value before comparing with the exact rational time.
            difference = abs(Fraction.from_float(float(passage["estimated_elapsed_us"])) - elapsed)
            assert difference <= elapsed * Fraction(1, 2 ** 49), "elapsed estimate exceeds eight binary64 epsilons"
            elapsed_errors["maximum_absolute_error_us"] = max(elapsed_errors["maximum_absolute_error_us"], float(difference))
            elapsed_errors["maximum_relative_error"] = max(elapsed_errors["maximum_relative_error"], float(difference / elapsed))
            if int(passage["elapsed_upper_us"]) <= 1000000:
                key = "maximum_absolute_error_us_when_upper_bound_at_most_1000000"
                elapsed_errors[key] = max(elapsed_errors[key], float(difference))
    assert len(actual) == len(frames)
    saved = native(binary, CHECKPOINT, [source] + frames, count=1)[0]
    assert saved["counting"] == native(binary, "--evidence-checkpoint", [inner] + frames, count=1)[0]
    assert saved["counts"] == [{"section_id": value["section_id"], "completed": str(paired.counts[index])}
        for index, value in enumerate(source["sections"])]
    assert saved["pending"] == paired.pending_documents()
    cuts = 0
    if all_cuts:
        for cut in range(len(frames) + 1):
            prefix = native(binary, CHECKPOINT, [source] + frames[:cut], count=1)[0]
            assert prefix["pending"] == ([] if cut == 0 else snapshots[cut - 1])
            assert native(binary, STREAM, [{"resume": prefix}] + frames[cut:]) == actual[cut:]
            assert native(binary, CHECKPOINT, [{"resume": prefix}] + frames[cut:], count=1)[0] == saved
            cuts += 1
    return actual, {"frames": len(frames), "passages": sum(len(value["passages"]) for value in actual),
        "crossings": sum(len(value["counting"]["counting"]["crossings"]) for value in actual),
        "evidence": sum(len(value["counting"]["evidence"]) for value in actual), "resume_cut_points": cuts,
        "maximum_absolute_pairing_errors": time_errors, "maximum_absolute_normal_errors": absolute,
        "maximum_relative_or_scaled_normal_errors": scaled,
        "elapsed_errors_against_exact_fraction_interpolation": elapsed_errors,
        "checkpoint_sha256": hashlib.sha256(encode(saved).encode()).hexdigest()}


def reference_checks(binary):
    results, reasons = [], set()
    for name, source, frames in fixtures():
        actual, result = check_sequence(binary, source, frames)
        reasons.update(item["reason"] for value in actual for item in value["cancellations"])
        if name == "same_frame_different_anchors_are_ambiguous":
            assert not actual[-1]["passages"]
            assert actual[-1]["cancellations"][0]["reason"] == "ambiguous_order"
            crossed = actual[-1]["counting"]["counting"]["crossings"]
            assert len(crossed) == 2 and crossed[0]["from_timestamp_us"] != crossed[1]["from_timestamp_us"]
        result["name"] = name
        results.append(result)
    assert {"discontinuity", "expired", "reentered", "reversed", "ambiguous_order"} <= reasons
    return {"cases": len(results), **{key: sum(value[key] for value in results) for key in
        ["frames", "passages", "crossings", "evidence", "resume_cut_points"]},
        "cancellation_reasons": sorted(reasons), "records": results}


def zero_multiplier_checks(binary):
    total = passages = 0
    for name, source, frames in fixtures():
        inner = dict(evidence_source(source), sigma_multiplier=0)
        source = dict(source, counting=encode(inner))
        old = old_source(source)
        expected = native(binary, "--transit", [old] + frames)
        actual = native(binary, STREAM, [source] + frames)
        for value, wanted in zip(actual, expected):
            value = copy.deepcopy(value)
            value.update(kind="transit_events", counting=value["counting"]["counting"])
            assert value == wanted, name
        total += len(frames)
        passages += sum(len(value["passages"]) for value in actual)
    return {"cases": len(fixtures()), "frames": total, "passages": passages,
        "all_existing_transit_reports_equal_on_supported_covariance_domain": True}


def rejection_checks(binary):
    source = configuration("evidence-transit-strict")
    frames = sequence(source, [(0, -1), (0, 1), (0, 2), (0, 4)])
    saved = native(binary, CHECKPOINT, [source] + frames[:2], count=1)[0]
    prefix = native(binary, STREAM, [source, frames[0]])
    cases = []

    def bad(name, records, expected=(), mode=STREAM, payload=None, extra=()):
        try:
            result, detail = run(binary, mode, records, status=2, payload=payload, extra=extra)
        except AssertionError as error:
            raise AssertionError(name + ": " + str(error)) from error
        assert result == list(expected), name + ": lost prefix/exposed checkpoint"
        cases.append(dict(name=name, **detail))

    for name, mutate in [
        ("unknown_source", lambda v: v.update(extra=True)),
        ("counting_not_raw", lambda v: v.update(counting=json.loads(v["counting"]))),
        ("empty_sections", lambda v: v.update(sections=[])),
        ("duplicate_sections", lambda v: v["sections"].append(copy.deepcopy(v["sections"][0]))),
        ("unknown_gate", lambda v: v["sections"][0].update(entry_gate_id="absent")),
        ("invalid_direction", lambda v: v["sections"][0].update(entry_direction="forward")),
        ("same_two_gates", lambda v: v["sections"][0].update(exit_gate_id="entry")),
        ("duration_zero", lambda v: v.update(max_duration_us="0")),
        ("section_unknown_key", lambda v: v["sections"][0].update(extra=1)),
    ]:
        invalid = copy.deepcopy(source)
        mutate(invalid)
        bad(name, [invalid])
    bad("duplicate_source_key", ['{"counting":"bad",' + encode(source)[1:]])
    invalid = copy.deepcopy(source)
    inner = evidence_source(invalid)
    inner["counting"] = inner["counting"].replace('"max_tracks":16', '"max_tracks":16.0000000000000001')
    invalid["counting"] = encode(inner)
    bad("raw_fractional_inner_capacity", [invalid])
    old = native(binary, "--transit-checkpoint", [old_source(source)] + frames[:2], count=1)[0]
    bad("old_transit_not_upgraded", [{"resume": old}])
    for name, mutate in [
        ("wrong_format", lambda v: v.update(format="moonground.transit")),
        ("wrong_version", lambda v: v.update(checkpoint_version="2")),
        ("unknown_checkpoint_key", lambda v: v.update(extra=True)),
        ("missing_effective_duration", lambda v: v.pop("max_duration_us")),
        ("missing_counts", lambda v: v.update(counts=[])),
        ("negative_completed", lambda v: v["counts"][0].update(completed="-1")),
        ("unearned_completed", lambda v: v["counts"][0].update(completed="2")),
        ("unknown_pending_section", lambda v: v["pending"][0].update(section_id="absent")),
        ("duplicate_pending", lambda v: v["pending"].append(copy.deepcopy(v["pending"][0]))),
        ("wrong_pending_segment", lambda v: v["pending"][0]["entry"].update(segment_id="2")),
        ("wrong_pending_direction", lambda v: v["pending"][0]["entry"].update(direction="positive_to_negative")),
        ("wrong_pending_gate", lambda v: v["pending"][0]["entry"].update(gate_id="exit")),
        ("wrong_pending_fraction", lambda v: v["pending"][0]["entry"].update(crossing_fraction=0.25)),
        ("wrong_pending_intersection", lambda v: v["pending"][0]["entry"].update(position_m=[0.1, 0])),
        ("future_pending", lambda v: v["pending"][0]["entry"].update(to_timestamp_us="100001")),
        ("pending_track_missing", lambda v: v["counting"]["state"].update(tracks=[])),
        ("missing_from_covariance", lambda v: v["pending"][0].pop("from_covariance")),
        ("missing_to_covariance", lambda v: v["pending"][0].pop("to_covariance")),
        ("indefinite_from_covariance", lambda v: v["pending"][0].update(from_covariance=[1, 2, 1])),
        ("wrong_to_covariance_shape", lambda v: v["pending"][0].update(to_covariance=[1, 0])),
        ("unconfirmed_entry_from", lambda v: v["pending"][0].update(from_covariance=[1, 0, 1])),
        ("unconfirmed_entry_to", lambda v: v["pending"][0].update(to_covariance=[1, 0, 1])),
        ("current_entry_anchor_missing", lambda v: v["counting"]["state"]["tracks"][0]["anchors"].__setitem__(0, None)),
        ("current_entry_anchor_point_differs", lambda v: v["counting"]["state"]["tracks"][0]["anchors"][0].update(point_m=[0, 1.1])),
        ("current_entry_anchor_covariance_differs", lambda v: v["counting"]["state"]["tracks"][0]["anchors"][0].update(covariance=[0.02, 0, 0.02])),
        ("entry_anchor_predates_confirmation", lambda v: v["counting"]["state"]["tracks"][0]["anchors"][0].update(timestamp_us="0")),
        ("missing_sigma", lambda v: v["counting"]["configuration"].pop("sigma_multiplier")),
        ("missing_effective_gap", lambda v: v["counting"]["configuration"]["counting"].pop("max_gap_us")),
        ("missing_effective_capacity", lambda v: v["counting"]["configuration"]["counting"].pop("max_tracks")),
        ("missing_effective_deadband", lambda v: v["counting"]["configuration"]["counting"]["gates"][0].pop("deadband_m")),
    ]:
        invalid = copy.deepcopy(saved)
        mutate(invalid)
        bad(name, [{"resume": invalid}])
    for name, mutate in [
        ("unknown_frame", lambda v: v.update(extra=True)),
        ("duplicate_track", lambda v: v["tracks"].append(copy.deepcopy(v["tracks"][0]))),
        ("same_timestamp", lambda v: v.update(timestamp_us="0")),
        ("wrong_session", lambda v: v.update(session_id="absent")),
        ("missing_current_covariance", lambda v: v["tracks"][0].update(position_covariance=None)),
        ("indefinite_current_covariance", lambda v: v["tracks"][0].update(position_covariance=[1, 2, 1])),
    ]:
        invalid = copy.deepcopy(frames[1])
        mutate(invalid)
        bad(name, [source, frames[0], invalid], prefix)
    bad("fractional_raw_track", [source, frames[0], encode(frames[1]).replace('"track_id":1', '"track_id":1.0000000000000001')], prefix)
    bad("duplicate_raw_track", [source, frames[0], encode(frames[1]).replace('"track_id":1', '"track_id":1,"track_id":1')], prefix)
    bad("invalid_utf8", [], prefix, payload=gates.lines([source, frames[0]]).encode() + b"\xff\n")
    bad("blank_frame", [source, frames[0], ""], prefix)
    bad("empty_header", [], payload=b"")
    bad("late_error_no_checkpoint", [source, frames[0], dict(frames[1], extra=True)], mode=CHECKPOINT)
    bad("resume_override", [{"resume": saved, "sections": source["sections"]}])
    # The mean endpoint is one binary64 step outside the closed deadband.
    # At k>0 any representably strict interval necessarily touches that band.
    zero_source = dict(source, counting=encode(dict(evidence_source(source), sigma_multiplier=0)))
    near = sequence(zero_source, [(0, float(np.nextafter(-0.05, -np.inf))), (0, 1)])
    impossible = native(binary, CHECKPOINT, [zero_source] + near, count=1)[0]
    assert impossible["pending"]
    impossible["counting"]["configuration"]["sigma_multiplier"] = 2
    bad("mean_valid_but_positive_k_confirmation_impossible", [{"resume": impossible}])
    unchanged_anchor = native(binary, CHECKPOINT, [source] + frames[:2] + [measured(source, 200000, (0, 2), (4, 0, 4))], count=1)[0]
    unchanged_anchor["counting"]["state"]["tracks"][0]["anchors"][0]["covariance"] = [0.02, 0, 0.02]
    bad("retained_entry_confirmation_anchor_covariance_differs", [{"resume": unchanged_anchor}])
    early_missing = native(binary, CHECKPOINT, [source] + frames[:3], count=1)[0]
    early_missing["counting"]["state"]["tracks"][0]["anchors"][0] = None
    bad("entry_anchor_disappears_before_its_gap_age", [{"resume": early_missing}])
    expired = native(binary, CHECKPOINT, [source] + frames[:3], count=1)[0]
    expired["max_duration_us"] = "100000"
    bad("pending_exact_deadline", [{"resume": expired}])
    huge_bracket = copy.deepcopy(saved)
    huge_bracket["counting"]["configuration"]["counting"]["max_gap_us"] = "100000"
    bad("entry_bracket_at_gap", [{"resume": huge_bracket}])
    used = copy.deepcopy(saved)
    used["counts"][0]["completed"] = "1"
    used["counting"]["state"]["counts"][1]["negative_to_positive"] = "1"
    bad("pending_exceeds_uncompleted_entries", [{"resume": used}])
    saturated = copy.deepcopy(saved)
    for count in saturated["counting"]["state"]["counts"]:
        count.update(negative_to_positive="9223372036854775807", positive_to_negative="9223372036854775807")
    safe_prefix = native(binary, STREAM, [{"resume": saturated}, frames[2]])
    bad("gate_count_overflow", [{"resume": saturated}] + frames[2:], safe_prefix)
    bad("gate_count_overflow_no_checkpoint", [{"resume": saturated}] + frames[2:], mode=CHECKPOINT)
    corrected = native(binary, CHECKPOINT, [{"resume": saturated}, measured(source, 300000, (0, 2))], count=1)[0]
    assert corrected["pending"] == saved["pending"] and corrected["counts"] == saved["counts"]
    large = copy.deepcopy(saved)
    for count in large["counting"]["state"]["counts"]:
        count.update(negative_to_positive="9007199254740993", positive_to_negative="9007199254740993")
    large["counts"][0]["completed"] = "9007199254740992"
    updated = native(binary, STREAM, [{"resume": large}, frames[-1]], count=1)[0]
    assert updated["counts"][0]["completed"] == "9007199254740993"
    # Correlated near-singular SPD is outside the documented arithmetic domain.
    invalid = copy.deepcopy(frames[-1])
    invalid["tracks"][0]["position_covariance"] = [1, float(np.nextafter(1., 0.)), 1]
    safe = native(binary, STREAM, [{"resume": saved}, frames[2]])
    bad("late_evidence_numeric_failure", [{"resume": saved}, frames[2], invalid], safe)
    bad("late_numeric_failure_no_checkpoint", [{"resume": saved}, frames[2], invalid], mode=CHECKPOINT)
    assert native(binary, CHECKPOINT, [{"resume": saved}, frames[2], frames[-1]], count=1)[0]["counts"][0]["completed"] == "1"
    return {"rejected_cases": len(cases), "cases": cases, "complete_prefix_preserved": True,
        "same_proposed_timestamp_correction_from_saved_state": "passed",
        "large_completed_count_after_increment": "9007199254740993"}


def started_source_checks(binary):
    source = configuration("evidence-transit-started")
    frames = sequence(source, [(0, -1), (0, 1), (0, 4), (0, -1)])
    prior = native(binary, "--evidence-checkpoint", [evidence_source(source)] + frames[:2], count=1)[0]
    started = dict(source, counting=encode({"resume": prior}))
    actual = native(binary, STREAM, [started] + frames[2:])
    assert not actual[0]["passages"] and actual[0]["pending_count"] == 0
    assert actual[1]["passages"][0]["section_id"] == "backward"
    assert [value["counting"] for value in actual] == native(binary, "--count-evidence", [{"resume": prior}] + frames[2:])
    return {"historical_entry_ignored": True, "future_frames": 2, "sigma_multiplier_preserved": prior["configuration"]["sigma_multiplier"]}


def pipeline_checks(binary):
    results = []
    for name, header, _, frames in [guarded.fixtures()[0], replacement.fixtures()[0]]:
        counted = native(binary, "--guarded", [header] + frames)
        old = json.loads(header["analysis"])
        old_counting = json.loads(old["counting"])
        gates_config = old_counting["resume"]["configuration"] if "resume" in old_counting else old_counting
        # Use two finite channels crossing the fixture's observed y travel.
        gates_config["gates"] = [gates.gate("entry", (-100, 1.6), (100, 1.6), 0.001),
            gates.gate("exit", (-100, 2.6), (100, 2.6), 0.001)]
        source = {"counting": encode({"counting": encode(gates_config), "sigma_multiplier": 2}),
            "sections": [transit.section()], "max_duration_us": "300000000"}
        measurements = [value["analysis"]["measurement"] for value in counted]
        actual, result = check_sequence(binary, source, measurements)
        for index, value in enumerate(counted):
            if value["decision"] == "blocked":
                assert actual[index]["pending_count"] == 0 and not actual[index]["counting"]["evidence"]
        results.append(dict(name=name, blocked_frames=sum(value["decision"] == "blocked" for value in counted),
            projection_barriers=sum(value["kind"] == "guarded_projection_replaced" for value in counted), **result))
    return {"old_guarded_measurements_consumed_without_adapter": True, "records": results}


def transport_checks(binary):
    source = configuration("evidence-transit-transport")
    frames = sequence(source, [(0, -1), (0, 4)])
    expected = native(binary, STREAM, [source] + frames)
    for ending in [b"\n", b"\r\n"]:
        assert run(binary, STREAM, payload=ending.join(encode(value).encode() for value in [source] + frames))[0] == expected
    exact = max(len(encode(value).encode()) for value in [source] + frames)
    assert native(binary, STREAM, [source] + frames, extra=["--max-line-bytes", str(exact)]) == expected
    saved = native(binary, CHECKPOINT, [source], count=1)[0]
    padded = encode({"resume": saved}).ljust(8388619)
    assert native(binary, CHECKPOINT, [padded], count=1, extra=["--max-line-bytes", "16777216"])[0] == saved
    _, rejected = run(binary, CHECKPOINT, [padded + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    return {"crlf_and_unterminated_eof": "passed", "exact_physical_line_bytes": exact,
        "exact_resume_utf16_units": 8388619, "source_one_unit_overflow": rejected}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/evidence-transit.test.mjs"]
    completed = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=300)
    if completed.returncode:
        raise AssertionError("Node evidence transit failed:\n" + completed.stdout[-18000:] + completed.stderr[-2000:])
    summary, directions, load = {}, None, None
    for value in completed.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", value)
        if match:
            summary[match.group(1)] = int(match.group(2))
        if value.startswith('# {"cut_points":'):
            directions = json.loads(value[2:])
        if value.startswith('# {"pending_load":'):
            load = json.loads(value[2:])
    assert summary.get("tests") and summary["pass"] == summary["tests"] and not summary["fail"]
    assert directions is not None and load is not None
    return {"status": "passed", "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "command": " ".join(command), "summary": summary, "cross_runtime": directions, "measured_load": load,
        "test_script_sha256": hashlib.sha256((ROOT / "web/evidence-transit.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(), "stderr": completed.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/evidence-transit-results.json")
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
        "transit_reference_sha256": hashlib.sha256(Path(transit.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["decimal_fraction_reference"] = reference_checks(binary)
    result["zero_multiplier_old_transit"] = zero_multiplier_checks(binary)
    result["strict_transport"] = rejection_checks(binary)
    result["started_evidence_source"] = started_source_checks(binary)
    result["guarded_and_projection_barriers"] = pipeline_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result.update(elapsed_seconds=time.perf_counter() - started, status="passed")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "output": str(args.output),
        "cases": result["decimal_fraction_reference"]["cases"], "frames": result["decimal_fraction_reference"]["frames"],
        "resume_cut_points": result["decimal_fraction_reference"]["resume_cut_points"],
        "strict_rejections": result["strict_transport"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
