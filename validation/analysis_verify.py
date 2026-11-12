#!/usr/bin/env python3
"""Check transactional measurement/counting against both existing CLI paths.

The intersection oracle is the separate NumPy implementation in gates_verify.
Full motion state, covariance, path, IDs, counters and anchors are compared with
the independent --stream/--checkpoint and --count/--count-checkpoint paths.
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

import checkpoint_verify as checkpoints
import gates_verify as gates
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
SEED = 20261117
TOLERANCE = 2.0e-10
encode = gates.encode
lines = gates.lines


def run(binary, mode, records=(), status=0, count=None, payload=None, extra=()):
    return gates.execute(binary, mode, records, status=status, count=count,
                         payload=payload, extra=extra)


def native(binary, mode, records=(), **kwargs):
    return run(binary, mode, records, **kwargs)[0]


def source(measurement, counting):
    return {"measurement": measurement if isinstance(measurement, str) else encode(measurement),
            "counting": counting if isinstance(counting, str) else encode(counting)}


def combined(measurement, counting):
    return {"format": "moonground.analysis", "checkpoint_version": "1",
            "measurement": measurement, "counting": counting}


def expected(binary, measurement, counting, frames):
    measured = native(binary, "--stream", [measurement] + frames)
    counted = native(binary, "--count", [counting] + measured)
    joined = [{"schema_version": "0.1.0", "kind": "analysis_frame",
               "measurement": left, "counting": right} for left, right in zip(measured, counted)]
    saved = combined(native(binary, "--checkpoint", [measurement] + frames, count=1)[0],
                     native(binary, "--count-checkpoint", [counting] + measured, count=1)[0])
    return joined, saved


def fixtures():
    result = []
    for name, measurement, frames in checkpoints.fixtures(np.random.default_rng(SEED)):
        counting = gates.configuration(name=measurement["session_id"], gates=[
            gates.gate("horizontal", (-100, 0.05), (100, 0.05), 0.005),
            gates.gate("vertical", (0.2, -100), (0.2, 100), 0.005)])
        result.append((name, measurement, counting, frames))
    for name in ("warehouse", "distorted-camera", "reframe"):
        records = [json.loads(value) for value in (ROOT / ("examples/" + name + ".ndjson")).read_text().splitlines()]
        records[0]["diagnostics"] = True
        counting = gates.configuration(name=records[0]["session_id"], gates=[
            gates.gate("horizontal", (-100, 3.8), (100, 3.8), 0.005),
            gates.gate("vertical", (1.2, -100), (1.2, 100), 0.005)])
        result.append((name, records[0], counting, records[1:]))
    measurement = checkpoints.config("analysis-crossings")
    measurement["motion"].update(gate=1e9, q=5.0, min_observations=2, min_span_us="100000")
    frames = [checkpoints.frame(i * 100000, [checkpoints.observation(1, [0, y]),
        checkpoints.observation(2, [y, 0.4])]) for i, y in enumerate([-1, -0.5, 0, 0.5, 1, 0.5, 0, -0.5, -1])]
    counting = gates.configuration(name=measurement["session_id"], gates=[gates.gate(),
        gates.gate("vertical", (0, -1), (0, 1))])
    result.append(("repeated_crossings", measurement, counting, frames))
    quality = copy.deepcopy(counting)
    quality["max_position_std_m"] = 0.05
    result.append(("quality_rejects_current_positions", measurement, quality, frames))
    return result


def reference_checks(binary):
    records, statuses, errors = [], set(), {}
    total_frames = total_crossings = restart_points = 0
    for name, measurement, counting, frames in fixtures():
        baseline, saved = expected(binary, measurement, counting, frames)
        actual = native(binary, "--analyze", [source(measurement, counting)] + frames)
        if actual != baseline:
            raise AssertionError(name + ": analysis differs from separate native paths")
        final = native(binary, "--analyze-checkpoint", [source(measurement, counting)] + frames, count=1)[0]
        if final != saved:
            raise AssertionError(name + ": full joint checkpoint differs from independent exports")
        oracle = gates.Oracle(counting)
        crossings = 0
        for frame in actual:
            gates.tree_close(frame["counting"], oracle.update(frame["measurement"]), errors)
            crossings += len(frame["counting"]["crossings"])
            statuses.update(value["status"] for value in frame["measurement"]["tracks"])
        for cut in range(len(frames) + 1):
            prefix = native(binary, "--analyze-checkpoint", [source(measurement, counting)] + frames[:cut], count=1)[0]
            # Nested legacy snapshots remain usable separately and can be joined.
            nested = source({"resume": prefix["measurement"]}, {"resume": prefix["counting"]})
            for entry in ({"resume": prefix}, nested):
                resumed = native(binary, "--analyze", [entry] + frames[cut:])
                if resumed != baseline[cut:]:
                    raise AssertionError("{} cut {} continuation differs".format(name, cut))
                continuation = native(binary, "--analyze-checkpoint", [entry] + frames[cut:], count=1)[0]
                if continuation != saved:
                    raise AssertionError("{} cut {} lost joint state".format(name, cut))
            restart_points += 1
        records.append({"name": name, "frames": len(frames), "crossings": crossings,
            "restart_points": len(frames) + 1,
            "checkpoint_sha256": hashlib.sha256(encode(saved).encode()).hexdigest()})
        total_frames += len(frames)
        total_crossings += crossings
    if total_crossings < 4:
        raise AssertionError("too few actual crossings exercised")
    required = {"initializing", "ready", "uncertain", "rejected_innovation", "rejected_projection", "numerical_failure"}
    if not required.issubset(statuses):
        raise AssertionError("missing lifecycle outcomes: " + str(required - statuses))
    return {"cases": len(records), "frames": total_frames, "crossings": total_crossings,
        "resume_cut_points": restart_points, "resume_source_forms": 2,
        "full_state_and_covariance_equal": True, "statuses": sorted(statuses),
        "maximum_absolute_oracle_errors": errors, "records": records}


def rejection_checks(binary):
    measurement = checkpoints.config("analysis-strict")
    measurement["motion"].update(gate=1e9, min_observations=2, min_span_us="100000")
    counting = gates.configuration(name=measurement["session_id"])
    first = checkpoints.frame(100000, [checkpoints.observation(1, [0, -1])])
    later = checkpoints.frame(200000, [checkpoints.observation(1, [0, 1])])
    head = source(measurement, counting)
    prefix = native(binary, "--analyze", [head, first])
    saved = native(binary, "--analyze-checkpoint", [head, first], count=1)[0]
    records = []

    def bad(name, values, expected_prefix=(), mode="--analyze", payload=None, extra=()):
        actual, evidence = run(binary, mode, values, status=2, payload=payload, extra=extra)
        if actual != list(expected_prefix):
            raise AssertionError(name + ": error changed complete prefix or exposed checkpoint")
        records.append(dict(name=name, **evidence))

    for name, value in [
        ("source_missing_counting", {"measurement": encode(measurement)}),
        ("source_object_instead_raw_text", {"measurement": measurement, "counting": encode(counting)}),
        ("source_unknown_field", dict(head, extra=True)),
        ("source_duplicate_key", '{"measurement":"bad",' + encode(head)[1:]),
        ("measurement_duplicate_key", source('{"mode":"ground",' + encode(measurement)[1:], counting)),
        ("gate_duplicate_key", source(measurement, '{"max_tracks":1,' + encode(counting)[1:])),
        ("gate_fractional_capacity_token", source(measurement, encode(counting).replace('"max_tracks":100', '"max_tracks":100.000000000000001'))),
        ("different_initial_session", source(measurement, dict(counting, session_id="other"))),
        ("measurement_only_warm_start", source({"resume": saved["measurement"]}, counting)),
        ("counting_only_warm_start", source(measurement, {"resume": saved["counting"]})),
    ]:
        bad(name, [value])
    mutations = [
        ("joint_wrong_format", lambda v: v.update(format="other")),
        ("joint_wrong_version", lambda v: v.update(checkpoint_version="2")),
        ("joint_unknown_field", lambda v: v.update(extra=True)),
        ("checkpoint_session_mismatch", lambda v: v["counting"]["configuration"].update(session_id="other")),
        ("checkpoint_watermark_mismatch", lambda v: v["counting"]["state"].update(last_timestamp_us="100001")),
        ("checkpoint_missing_gate_track", lambda v: v["counting"]["state"].update(tracks=[])),
        ("checkpoint_extra_gate_track", lambda v: v["counting"]["state"]["tracks"].append(dict(copy.deepcopy(v["counting"]["state"]["tracks"][0]), track_id=2))),
        ("checkpoint_wrong_segment", lambda v: v["counting"]["state"]["tracks"][0].update(segment_id="2")),
        ("checkpoint_missing_stable_anchor", lambda v: v["counting"]["state"]["tracks"][0].update(anchors=[None])),
        ("checkpoint_anchor_current_position_mismatch", lambda v: v["counting"]["state"]["tracks"][0]["anchors"][0].update(point_m=[0.25, -1])),
        ("checkpoint_anchor_predates_motion_segment", lambda v: v["counting"]["state"]["tracks"][0]["anchors"][0].update(timestamp_us="99999")),
        ("checkpoint_quality_forged_track", lambda v: v["counting"]["configuration"].update(max_position_std_m=0.01)),
    ]
    for name, mutate in mutations:
        value = copy.deepcopy(saved)
        mutate(value)
        bad(name, [{"resume": value}])
    bad("resume_override", [{"resume": saved, "measurement": encode(measurement)}])
    bad("raw_fractional_track_token", [head, first, encode(later).replace('"track_id":1', '"track_id":1.0000000000000001')], prefix)
    bad("duplicate_observation_key", [head, first, '{"timestamp_us":"200000",' + encode(later)[1:]], prefix)
    for name, invalid in [("same_timestamp", first), ("unknown_frame_key", dict(later, extra=True)),
        ("duplicate_observation", dict(later, observations=later["observations"] * 2)),
        ("conflicting_lost_identity", dict(later, lost=[1]))]:
        bad(name, [head, first, invalid], prefix)
    bad("blank_observation", [head, first, ""], prefix)
    bad("invalid_utf8", [], prefix, payload=lines([head, first]).encode() + b"\xff\n")
    bad("checkpoint_mode_late_failure", [head, first, dict(later, extra=True)], mode="--analyze-checkpoint")
    # Saturation is valid durable state; the next crossing must fail atomically.
    saturated = copy.deepcopy(saved)
    saturated["counting"]["state"]["counts"][0]["negative_to_positive"] = "9223372036854775807"
    resumed_head = {"resume": saturated}
    bad("counter_overflow_on_crossing", [resumed_head, later])
    bad("counter_overflow_no_checkpoint", [resumed_head, later], mode="--analyze-checkpoint")
    numerical_head = source({"session_id": "analysis-numerical", "mode": "ground"},
        gates.configuration(name="analysis-numerical", gates=[
            gates.gate("far", (1e308, 0), (1e308, 1), 0)]))
    empty = checkpoints.frame(0)
    numerical = checkpoints.frame(100000, [checkpoints.observation(1, [-1e308, 0], [1, 0, 1])])
    numerical_prefix = native(binary, "--analyze", [numerical_head, empty])
    bad("late_gate_geometry_failure_preserves_prefix", [numerical_head, empty, numerical], numerical_prefix)
    bad("late_gate_geometry_failure_no_checkpoint", [numerical_head, empty, numerical], mode="--analyze-checkpoint")
    correction = checkpoints.frame(200000, [checkpoints.observation(1, [0, -0.5])])
    corrected = native(binary, "--analyze-checkpoint", [resumed_head, correction], count=1)[0]
    if corrected["counting"]["state"]["last_timestamp_us"] != "200000":
        raise AssertionError("same-timestamp correction did not commit both watermarks")
    if corrected["measurement"]["motion"]["last_timestamp_us"] != "200000":
        raise AssertionError("measurement watermark differs after correction")
    if corrected["counting"]["state"]["counts"] != saturated["counting"]["state"]["counts"]:
        raise AssertionError("saturated totals changed without crossing")
    # Integral lexical forms must survive the same raw-text validation.
    integral = encode(later).replace('"track_id":1', '"track_id":10e-1')
    if native(binary, "--analyze", [head, first, integral]) != native(binary, "--analyze", [head, first, later]):
        raise AssertionError("mathematically integral raw token changed identity")
    return {"rejected_cases": len(records), "cases": records,
        "complete_prefix_preserved": True, "failed_checkpoint_has_no_output": True,
        "saturated_checkpoint_same_time_correction": "passed",
        "mathematical_integer_token": "passed"}


def anchor_and_counter_checks(binary):
    measurement = checkpoints.config("analysis-anchor")
    measurement["motion"].update(gate=1e9, initial_velocity_std=1000)
    counting = gates.configuration(name=measurement["session_id"], gates=[gates.gate(deadband=0.3)])
    first = checkpoints.frame(100000, [checkpoints.observation(1, [0, -1], [1e-8, 0, 1e-8])])
    middle = checkpoints.frame(200000, [checkpoints.observation(1, [0, 0], [1e-8, 0, 1e-8])])
    last = checkpoints.frame(300000, [checkpoints.observation(1, [0, 1], [1e-8, 0, 1e-8])])
    head = source(measurement, counting)
    saved = native(binary, "--analyze-checkpoint", [head, first, middle], count=1)[0]
    anchor = saved["counting"]["state"]["tracks"][0]["anchors"][0]
    if anchor["timestamp_us"] != "100000":
        raise AssertionError("band fixture did not retain the preceding stable anchor")
    saved["counting"]["state"]["counts"][0]["negative_to_positive"] = "9007199254740993"
    resumed = native(binary, "--analyze", [{"resume": saved}, last], count=1)[0]
    if resumed["counting"]["counts"][0]["negative_to_positive"] != "9007199254740994":
        raise AssertionError("crossing count lost exact Int64 precision above 2^53")
    if resumed["counting"]["crossings"][0]["from_timestamp_us"] != "100000":
        raise AssertionError("restored band crossing lost older stable anchor")
    exported = native(binary, "--analyze-checkpoint", [{"resume": saved}, last], count=1)[0]
    if exported["counting"]["state"]["counts"] != resumed["counting"]["counts"]:
        raise AssertionError("exported large counters differ from frame counters")
    return {"legal_band_anchor_timestamp_us": anchor["timestamp_us"],
        "current_motion_timestamp_us": saved["measurement"]["motion"]["last_timestamp_us"],
        "before_negative_to_positive": "9007199254740993",
        "after_negative_to_positive": "9007199254740994",
        "crossing_continues_from_retained_anchor": True}


def transport_checks(binary):
    measurement = checkpoints.config("analysis-transport")
    counting = gates.configuration(name=measurement["session_id"])
    head = source(measurement, counting)
    first = checkpoints.frame(100000, [checkpoints.observation(1, [0, -1])])
    later = checkpoints.frame(200000, [checkpoints.observation(1, [0, -0.5])])
    baseline = native(binary, "--analyze", [head, first, later])
    for ending in (b"\n", b"\r\n"):
        actual = run(binary, "--analyze", payload=ending.join(encode(v).encode() for v in [head, first, later]))[0]
        if actual != baseline:
            raise AssertionError("CRLF or unterminated EOF changed analysis")
    exact = max(len(encode(value).encode()) for value in [head, first, later])
    if native(binary, "--analyze", [head, first, later], extra=["--max-line-bytes", str(exact)]) != baseline:
        raise AssertionError("exact physical line bound rejected valid input")
    padded = encode(later) + " " * (exact + 128)
    prefix, failure = run(binary, "--analyze", [head, first, padded], status=2,
        extra=["--max-line-bytes", str(len(padded) - 1)])
    if prefix != baseline[:1]:
        raise AssertionError("physical one-byte overflow lost prefix")
    _, line_failure = run(binary, "--analyze", [head, first, encode(later) + " " * 1048576], status=2,
        extra=["--max-line-bytes", "16777216"])
    saved = native(binary, "--analyze-checkpoint", [head], count=1)[0]
    resume = encode({"resume": saved})
    exact_source = resume + " " * (8388619 - len(resume))
    if native(binary, "--analyze-checkpoint", [exact_source], count=1,
            extra=["--max-line-bytes", "16777216"])[0] != saved:
        raise AssertionError("exact source UTF-16 boundary did not roundtrip")
    _, source_failure = run(binary, "--analyze-checkpoint", [exact_source + " "], status=2,
        count=0, extra=["--max-line-bytes", "16777216"])
    # A complete joint checkpoint has a shared 8 Mi budget, even though each
    # nested legacy checkpoint has its own 8 Mi allowance.
    edge = copy.deepcopy(saved)
    edge["measurement"]["configuration"]["session_id"] = ""
    edge["counting"]["configuration"]["session_id"] = ""
    remaining = 8388608 - len(encode(edge))
    # Equal session IDs consume two code units per added ASCII character.
    name = "x" * (remaining // 2)
    edge["measurement"]["configuration"]["session_id"] = name
    edge["counting"]["configuration"]["session_id"] = name
    size = len(encode(edge))
    exported = native(binary, "--analyze-checkpoint", [{"resume": edge}], count=1,
        extra=["--max-line-bytes", "16777216"])[0]
    if exported != edge:
        raise AssertionError("joint checkpoint near exact budget did not roundtrip")
    edge["measurement"]["configuration"]["session_id"] += "x"
    edge["counting"]["configuration"]["session_id"] += "x"
    _, checkpoint_failure = run(binary, "--analyze-checkpoint", [{"resume": edge}], status=2,
        count=0, extra=["--max-line-bytes", "16777216"])
    return {"crlf_and_unterminated_eof": "passed", "exact_physical_line_bytes": exact,
        "physical_one_byte_overflow": failure, "observation_text_limit": line_failure,
        "exact_source_utf16_units": 8388619, "source_one_unit_overflow": source_failure,
        "joint_checkpoint_near_boundary_utf16_units": size,
        "joint_checkpoint_two_unit_overflow": checkpoint_failure}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/analysis.test.mjs"]
    environment = dict(os.environ, MOONGROUND_CLI=str(binary))
    completed = subprocess.run(command, cwd=str(ROOT), env=environment,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=300)
    if completed.returncode:
        raise AssertionError("Node analysis verification failed:\n" + completed.stdout[-18000:] + completed.stderr[-2000:])
    summary, directions = {}, None
    for line in completed.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", line)
        if match:
            summary[match.group(1)] = int(match.group(2))
        if line.startswith('# {"cut_points":'):
            directions = json.loads(line[2:])
    if not summary.get("tests") or summary.get("pass") != summary["tests"] or summary.get("fail"):
        raise AssertionError("incomplete Node test summary")
    if directions is None or len(directions["directions"]) != 4:
        raise AssertionError("Node suite did not record four runtime directions")
    return {"status": "passed", "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "command": " ".join(command), "summary": summary, "cross_runtime": directions,
        "test_script_sha256": hashlib.sha256((ROOT / "web/analysis.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(), "stderr": completed.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/analysis-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "seed": SEED, "tolerance": TOLERANCE,
        "command": " ".join(shlex.quote(value) for value in [sys.executable] + sys.argv),
        "python": platform.python_version(), "numpy": np.__version__,
        "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "oracle_sha256": hashlib.sha256(Path(gates.__file__).read_bytes()).hexdigest(),
        "fixture_source_sha256": hashlib.sha256(Path(checkpoints.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["separate_paths_and_reference"] = reference_checks(binary)
    result["strict_transport"] = rejection_checks(binary)
    result["anchors_and_int64_counters"] = anchor_and_counter_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    result["status"] = "passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "output": str(args.output),
        "reference_cases": result["separate_paths_and_reference"]["cases"],
        "reference_frames": result["separate_paths_and_reference"]["frames"],
        "resume_cut_points": result["separate_paths_and_reference"]["resume_cut_points"],
        "strict_rejections": result["strict_transport"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
