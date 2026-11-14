#!/usr/bin/env python3
"""Independent raw measurement, explicit footprint run and integer-window chain.

The original motion and v29 APIs supply separate component outputs. The v26
backward suffix oracle and Python bigint grouping independently check the run
and window results. No host code predicts segment IDs or keeps a shape map.
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

import footprint_run_analysis_verify as joint_reference
import footprint_run_windows_verify as window_reference
import footprint_run_verify as run_reference
import checkpoint_verify as checkpoints
import gates_verify as gates
import verify as reference

ROOT = Path(__file__).resolve().parents[1]
MODE = "--analyze-footprint-run-windows"
CHECKPOINT = "--analyze-footprint-run-windows-checkpoint"
PREVIEW = "--preview-footprint-run-window"
MAX = 9223372036854775807
encode, native, execute = gates.encode, gates.native, gates.execute
assigned = run_reference.assigned


def source(analysis, width=300000, origin=0):
    return {"analysis": encode(analysis), "window": encode({"window_us": str(width), "origin_us": str(origin)})}


def combined(measurement, windows):
    return {"format": "moonground.footprint-run-window-analysis", "checkpoint_version": "1", "measurement": measurement, "windows": windows}


def component_chain(binary, measurement, runs, raw, cut=0, width=300000, origin=0):
    measured = native(binary, "--stream", [measurement] + raw)
    documents = [joint_reference.document(v, i) for i, v in enumerate(measured)]
    wrapped = [assigned.wrap(v, d) for v, d in zip(raw, documents)]
    measured_wrapped = [assigned.wrap(v, d) for v, d in zip(measured, documents)]
    position, options = json.loads(runs["position"]), json.loads(runs["options"])
    old_frames, old_runs = window_reference.component(binary, position, options, measured_wrapped)
    initial_runs = native(binary, run_reference.CHECKPOINT, [runs] + measured_wrapped[:cut], count=1)[0]
    initial_measurement = native(binary, "--checkpoint", [measurement] + raw[:cut], count=1)[0]
    old_window_source = window_reference.source({"resume": initial_runs}, width, origin)
    windows, current = window_reference.oracle(initial_runs, width, origin, old_frames[cut:])
    assert native(binary, window_reference.STREAM, [old_window_source] + measured_wrapped[cut:]) == windows
    window_cp = window_reference.checkpoint(old_runs, width, origin, initial_runs["last_timestamp_us"], current)
    assert native(binary, window_reference.CHECKPOINT, [old_window_source] + measured_wrapped[cut:], count=1)[0] == window_cp
    saved_measurement = native(binary, "--checkpoint", [measurement] + raw, count=1)[0]
    result = [{"schema_version": "0.1.0", "kind": "footprint_run_window_analysis_frame", "measurement": m, "windows": w} for m, w in zip(measured[cut:], windows)]
    initial_joint = joint_reference.combined(initial_measurement, initial_runs)
    original_source = {"resume": initial_joint} if cut else joint_reference.source(measurement, runs)
    return source(original_source, width, origin), result, combined(saved_measurement, window_cp), wrapped[cut:], raw[cut:]


def fixtures():
    values = [(name, m, r, f, 0, 300000, 0) for name, m, r, f in joint_reference.fixtures()]
    for cut in [1, 3, 4]:
        m, r, f = joint_reference.steady("window-started-" + str(cut))
        values.append(("started_baseline_" + str(cut), m, r, f, cut, 1000000, 0))
    m, r, _ = joint_reference.steady("window-terminal")
    m["motion"]["max_gap_us"] = str(MAX)
    r["options"] = encode({"max_gap_us": str(MAX), "confirmation_us": "0", "min_samples": "1"})
    f = [checkpoints.frame(t) for t in [0, MAX - 1, MAX]]
    values.append(("empty_exact_MAX_terminal", m, r, f, 0, MAX, 0))
    f = [checkpoints.frame(t) for t in [0, MAX]]
    values.append(("width_one_huge_unobserved", m, r, f, 0, 1, 0))
    m, r, f = joint_reference.steady("window-origin", 99)
    values.append(("nonzero_origin", m, r, f, 0, 300000, 99))
    return values


def replay_checks(binary):
    records, statuses, reasons, cuts = [], set(), set(), 0
    for name, m, r, raw, initial, width, origin in fixtures():
        head, expected, saved, wrapped, remainder = component_chain(binary, m, r, raw, initial, width, origin)
        assert native(binary, MODE, [head] + wrapped) == expected, name
        assert native(binary, CHECKPOINT, [head] + wrapped, count=1)[0] == saved, name
        for cut in range(len(wrapped) + 1):
            cp = native(binary, CHECKPOINT, [head] + wrapped[:cut], count=1)[0]
            assert native(binary, MODE, [{"resume": cp}] + wrapped[cut:]) == expected[cut:], (name, cut)
            assert native(binary, CHECKPOINT, [{"resume": cp}] + wrapped[cut:], count=1)[0] == saved
            if cut < len(wrapped):
                assert native(binary, PREVIEW, [{"resume": cp}, remainder[cut]], count=1)[0] == {"measurement": expected[cut]["measurement"]}
                assert native(binary, CHECKPOINT, [{"resume": cp}], count=1)[0] == cp
            cuts += 1
        for v in expected:
            statuses.update(t["status"] for t in v["measurement"]["tracks"])
            reasons.update(c["reason"] for c in v["windows"]["runs"]["closed"])
        records.append({"name": name, "frames": len(wrapped), "baseline_frames": initial, "confirmations": sum(len(v["windows"]["runs"]["confirmed"]) for v in expected), "endings": sum(len(v["windows"]["runs"]["closed"]) for v in expected), "buckets": len({v["windows"]["statistics"]["current_window"]["start_us"] for v in expected})})
    assert {"initializing", "ready", "uncertain", "rejected_innovation", "numerical_failure", "rejected_projection"}.issubset(statuses)
    return {"cases": len(records), "frames": sum(v["frames"] for v in records), "cut_points": cuts, "statuses": sorted(statuses), "ending_reasons_observed": sorted(reasons), "full_original_motion_v29_and_offline_bigint_windows_exact": True, "every_preview_noncommitting_and_exact": True, "records": records}


def seed(binary, name="window-joint-strict"):
    m, r, _ = joint_reference.steady(name)
    r["options"] = encode({"max_gap_us": "100", "confirmation_us": "0", "min_samples": "1"})
    raw = [checkpoints.frame(t, [checkpoints.observation(1, [.5, .5], [.01, 0, .01])]) for t in [0, 1, 2, 5, 10]]
    measured = native(binary, "--stream", [m] + raw)
    docs = [assigned.bundle(v, [] if i < 3 else [assigned.assignment(v["tracks"][0], assigned.disk(.25))]) for i, v in enumerate(measured)]
    wrapped = [assigned.wrap(f, d) for f, d in zip(raw, docs)]
    head = source(joint_reference.source(m, r), 100)
    saved = native(binary, CHECKPOINT, [head] + wrapped, count=1)[0]
    return m, r, head, raw, wrapped, saved


def independent_components(binary, cp):
    native(binary, "--checkpoint", [{"resume": cp["measurement"]}], count=1)
    native(binary, window_reference.CHECKPOINT, [{"resume": cp["windows"]}], count=1)
    old = joint_reference.combined(cp["measurement"], cp["windows"]["runs"])
    native(binary, joint_reference.CHECKPOINT, [{"resume": old}], count=1)


def strict_checks(binary):
    m, r, head, raw, wrapped, saved = seed(binary)
    records = []
    def bad(name, values, mode=CHECKPOINT, prefix=()):
        out, meta = execute(binary, mode, values, status=2)
        assert out == list(prefix), name
        records.append(dict(name=name, **meta))
    for name, h in [("unknown_source", dict(head, extra=True)), ("analysis_not_raw", dict(head, analysis={})), ("window_not_raw", dict(head, window={})), ("window_number", dict(head, window='{"window_us":100}')), ("window_noncanonical", dict(head, window='{"window_us":"0100"}')), ("zero_width", dict(head, window='{"window_us":"0"}'))]:
        bad(name, [h])
    def damage(name, change, independent=False):
        cp = copy.deepcopy(saved)
        change(cp)
        if independent:
            independent_components(binary, cp)
        bad(name, [{"resume": cp}])
    damage("joint_version", lambda c: c.update(checkpoint_version="2"))
    damage("watermark", lambda c: c["windows"]["runs"].update(last_timestamp_us="11"))
    damage("current_anchor", lambda c: [s.update(last_position_m=[.6, .5]) for s in c["windows"]["runs"]["states"]])
    damage("current_covariance", lambda c: [s["last_position_covariance"].__setitem__(0, s["last_position_covariance"][0] + 1e-6) for s in c["windows"]["runs"]["states"]])
    damage("initializing_motion", lambda c: c["measurement"]["configuration"]["motion"].update(min_observations=6))
    damage("missing_saved_first", lambda c: c["windows"]["current_window"].update(first_timestamp_us="1"), True)
    # A genuine retained run proves exactly two inputs in [5,10]. A second
    # target with three accepted samples there passes both old components.
    cp = copy.deepcopy(saved)
    motion = cp["measurement"]["motion"]
    second = copy.deepcopy(motion["tracks"][0])
    second.update(track_id=2, segment_id="2", first_timestamp_us="5", accepted_count=3)
    motion["tracks"].append(second)
    motion["next_segment_id"] = "3"
    independent_components(binary, cp)
    bad("three_accepted_in_two_suffix_inputs", [{"resume": cp}])
    second["accepted_count"] = 2
    assert native(binary, CHECKPOINT, [{"resume": cp}], count=1)[0] == cp
    # There is only one input before run.first=8. The hidden first=1 witness
    # needs another, although four distinct saved times fit total F=10.
    cp = copy.deepcopy(saved)
    motion = cp["measurement"]["motion"]
    motion["last_timestamp_us"] = "20"
    motion["tracks"][0].update(last_timestamp_us="20", accepted_count=10)
    hidden = native(binary, "--checkpoint", [m, checkpoints.frame(1, [checkpoints.observation(1, [.5, .5], [.01, 0, .01])])], count=1)[0]["motion"]["tracks"][0]
    hidden.update(track_id=2, segment_id="2", first_timestamp_us="1", last_timestamp_us="1", accepted_count=1)
    motion["tracks"].append(hidden)
    motion["next_segment_id"] = "3"
    cp["windows"]["runs"]["last_timestamp_us"] = "20"
    for state in cp["windows"]["runs"]["states"]:
        state["run"].update(first_timestamp_us="8", last_timestamp_us="20", sample_span_us="12", sample_count="9")
    cp["windows"]["current_window"].update(last_timestamp_us="20", input_frames="10")
    independent_components(binary, cp)
    bad("hidden_witness_exceeds_anchor_interval", [{"resume": cp}])
    prefix = native(binary, MODE, [head, wrapped[0]])
    for name, frame in [("duplicate_wrapper", '{"measurement":"bad",' + encode(wrapped[1])[1:]), ("unknown_frame", dict(wrapped[1], extra=True)), ("fractional_id", dict(wrapped[1], measurement=wrapped[1]["measurement"].replace('"track_id":1', '"track_id":1.0000000000000001'))), ("wrong_segment", dict(wrapped[1], assignments=wrapped[1]["assignments"].replace('"footprints":[]', '"footprints":[{"track_id":1,"segment_id":"9","shape":{"kind":"disk","radius_m":0.25}}]'))), ("precomputed_measurement", dict(wrapped[1], measurement=encode(native(binary, "--stream", [m] + raw[:2])[1])))]:
        bad(name, [head, wrapped[0], frame], MODE, prefix)
        assert not execute(binary, CHECKPOINT, [head, wrapped[0], frame], status=2)[0]
    return {"rejected_cases": len(records), "independently_valid_components_joint_suffix_counterexamples": 3, "records": records}


def atomic_checks(binary):
    m, r, raw = joint_reference.steady("window-joint-atomic")
    head, expected, saved, wrapped, _ = component_chain(binary, m, r, raw[:2])
    cp = native(binary, CHECKPOINT, [head, wrapped[0]], count=1)[0]
    bad = copy.deepcopy(wrapped[1])
    doc = json.loads(bad["assignments"])
    doc["footprints"][0]["shape"] = assigned.disk(1e-30)
    bad["assignments"] = encode(doc)
    prefix, meta = execute(binary, MODE, [head, wrapped[0], bad], status=2)
    assert prefix == expected[:1]
    assert not execute(binary, CHECKPOINT, [head, wrapped[0], bad], status=2)[0]
    assert native(binary, MODE, [{"resume": cp}, wrapped[1]]) == expected[1:]
    assert native(binary, CHECKPOINT, [{"resume": cp}, wrapped[1]], count=1)[0] == saved
    assert native(binary, CHECKPOINT, [{"resume": cp}], count=1)[0] == cp
    origin = source(joint_reference.source(m, r), 10, 100)
    before = native(binary, CHECKPOINT, [origin], count=1)[0]
    f = checkpoints.frame(99, [checkpoints.observation(1, [.5, .5])])
    d = {"timestamp_us": "99", "footprints": []}
    assert not execute(binary, CHECKPOINT, [origin, assigned.wrap(f, d)], status=2)[0]
    f["timestamp_us"], d["timestamp_us"] = "100", "100"
    corrected = native(binary, MODE, [origin, assigned.wrap(f, d)], count=1)[0]
    assert corrected["measurement"]["tracks"][0]["segment_id"] == "1"
    assert before["measurement"]["motion"]["next_segment_id"] == "1"
    return {"status": "passed", "late_footprint_numeric_failure": meta, "same_timestamp_retry": raw[1]["timestamp_us"], "complete_motion_P_path_nextsegment_runs_and_windows_checkpoint_exact": True, "origin_failure_corrected_time_segment_one": True, "live_same_preparation_retry_core_and_consumer": True}


def overflow_checks(binary):
    m, r, _ = joint_reference.steady("window-joint-overflow")
    m["motion"].update(max_tracks=2, max_gap_us=str(MAX))
    p = json.loads(r["position"])
    p["max_tracks"] = 2
    r["position"] = encode(p)
    r["options"] = encode({"min_samples": "1", "confirmation_us": "0", "max_gap_us": str(MAX)})
    raw = [checkpoints.frame(t, [checkpoints.observation(i, [.5, .5], [.01, 0, .01]) for i in [1, 2]]) for t in [MAX - 3, MAX - 2]]
    measured = native(binary, "--stream", [m] + raw)
    docs = [assigned.bundle(v, [assigned.assignment(t, assigned.disk(.25)) for t in v["tracks"]]) for v in measured]
    head = source(joint_reference.source(m, r), MAX)
    cp = native(binary, CHECKPOINT, [head] + [assigned.wrap(f, d) for f, d in zip(raw, docs)], count=1)[0]
    w = cp["windows"]["current_window"]
    w.update(first_timestamp_us="0", input_frames=str(MAX - 1))
    for row in w["zones"]:
        row.update(started=str(MAX), confirmed_inside=str(MAX))
        row["endings"][5]["confirmed"] = str(MAX - 2)
    independent_components(binary, cp)
    assert native(binary, CHECKPOINT, [{"resume": cp}], count=1)[0] == cp
    f = copy.deepcopy(raw[-1]); f["timestamp_us"] = str(MAX - 1)
    measured_next = native(binary, "--stream", [{"resume": cp["measurement"]}, f], count=1)[0]
    wrong = assigned.wrap(f, assigned.bundle(measured_next, [assigned.assignment(t, assigned.disk(.5)) for t in measured_next["tracks"]]))
    assert not execute(binary, CHECKPOINT, [{"resume": cp}, wrong], status=2)[0]
    out, meta = execute(binary, MODE, [{"resume": cp}, wrong], status=2); assert not out
    good = assigned.wrap(f, assigned.bundle(measured_next, [assigned.assignment(t, assigned.disk(.25)) for t in measured_next["tracks"]]))
    retry = native(binary, MODE, [{"resume": cp}, good], count=1)[0]
    assert all(s["sample_count"] == "2" for s in retry["windows"]["runs"]["active"])
    assert all(v["started"] == str(MAX) for v in retry["windows"]["statistics"]["current_window"]["zones"])
    assert native(binary, CHECKPOINT, [{"resume": cp}], count=1)[0] == cp
    return {"status": "passed", "counter": str(MAX), "input_frames": str(MAX - 1), "same_timestamp_retry": str(MAX - 1), "failure": meta, "all_components_and_joint_restored_before_probe": True}


def transport_checks(binary):
    m, r, raw = joint_reference.steady("window-joint-transport")
    head, expected, _, wrapped, _ = component_chain(binary, m, r, raw[:1])
    assert native(binary, PREVIEW, [head, raw[0]], count=1)[0] == {"measurement": expected[0]["measurement"]}
    assert not execute(binary, PREVIEW, [head], status=2)[0]
    out, meta = execute(binary, PREVIEW, [head, raw[0], raw[1]], status=2)
    assert out == [{"measurement": expected[0]["measurement"]}]
    assert not execute(binary, MODE, payload=b"", status=2)[0]
    for ending in [b"\n", b"\r\n"]:
        assert execute(binary, MODE, payload=ending.join(encode(v).encode() for v in [head, wrapped[0]]))[0] == expected
    assert native(binary, MODE, [head, encode(wrapped[0]).ljust(1048576)]) == expected
    assert not execute(binary, CHECKPOINT, [head, encode(wrapped[0]).ljust(1048577)], status=2, extra=["--max-line-bytes", "16777216"])[0]
    assert native(binary, CHECKPOINT, [encode(head).ljust(8388619)], count=1, extra=["--max-line-bytes", "16777216"])
    assert not execute(binary, CHECKPOINT, [encode(head).ljust(8388620)], status=2, extra=["--max-line-bytes", "16777216"])[0]
    return {"frame_utf16": 1048576, "source_utf16": 8388619, "LF_CRLF_unterminated_EOF": "passed", "preview_extra_complete_prefix": meta}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/footprint-run-window-analysis.test.mjs"]
    process = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=900)
    if process.returncode:
        raise AssertionError(process.stdout[-28000:] + process.stderr[-2000:])
    summary, details = {}, {}
    for v in process.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", v)
        if match: summary[match.group(1)] = int(match.group(2))
        for prefix, key in [("cut_points", "cross_runtime"), ("empty_frame_count", "actual_budgets"), ("maximum_actual_face_expansions", "maximum_work"), ("warm_reframe_maximum_absolute_error", "warm_reframe")]:
            if v.startswith('# {"' + prefix + '":'): details[key] = json.loads(v[2:])
    assert summary.get("tests") == summary.get("pass") and not summary.get("fail") and len(details) == 4
    return {"status": "passed", "summary": summary, "details": details, "command": " ".join(command), "node": subprocess.check_output(["node", "--version"], text=True).strip(), "source_sha256": hashlib.sha256((ROOT / "web/footprint-run-window-analysis.test.mjs").read_bytes()).hexdigest(), "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(), "stdout_sha256": hashlib.sha256(process.stdout.encode()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/footprint-run-window-analysis-results.json")
    args = parser.parse_args(); binary = args.binary.resolve(); started = time.perf_counter()
    version = reference.toolchain_version(); assert "0.10.18" in str(version), version
    result = {"format_version": "1", "fixtures": "deterministic", "command": " ".join(shlex.quote(v) for v in [sys.executable] + sys.argv), "python": platform.python_version(), "toolchain": version, "pinned_moon_home": os.environ.get("MOON_HOME"), "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "run_reference_sha256": hashlib.sha256(Path(run_reference.__file__).read_bytes()).hexdigest(), "window_reference_sha256": hashlib.sha256(Path(window_reference.__file__).read_bytes()).hexdigest(), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "independent_reference": "Original motion stream/checkpoint plus v25 evidence, v26 backward suffix oracle and v29 Python bigint grouping; complete frames and checkpoints", "scope": "observed_report_frame_run_confirmations_and_endings_not_visits_or_physical_dwell"}
    result["component_reference"] = replay_checks(binary)
    result["strict_restore_and_raw"] = strict_checks(binary)
    result["atomic_failed_candidate"] = atomic_checks(binary)
    result["overflow"] = overflow_checks(binary)
    result["transport_and_preview"] = transport_checks(binary)
    if args.web: result["web_interchange"] = web_checks(binary)
    result.update(status="passed", elapsed_seconds=time.perf_counter() - started)
    with args.output.open("w", encoding="utf-8", newline="\n") as f: f.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "cases": result["component_reference"]["cases"], "frames": result["component_reference"]["frames"], "cuts": result["component_reference"]["cut_points"], "rejects": result["strict_restore_and_raw"]["rejected_cases"], "output": str(args.output)}))


if __name__ == "__main__": main()
