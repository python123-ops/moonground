#!/usr/bin/env python3
"""Check health-controlled windows against old guarded and window owners.

NumPy health, Decimal covariance evidence and Fraction transit timing come from
the existing independent guarded reference. Statistics are regrouped offline
with Python integers. Joint restoration is tested with independently valid
components whose saved health samples cannot fit their observed window frames.
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

import evidence_guarded_transit_verify as upstream
import evidence_transit_window_analysis_verify as joint
import gates_verify as gates
import transit_windows_verify as windows
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
MAX = windows.MAX
STREAM, CHECKPOINT = "--guarded-transit-windows", "--guarded-transit-windows-checkpoint"
OLD_STREAM, OLD_CHECKPOINT = "--guarded-transit-evidence", "--guarded-transit-evidence-checkpoint"
encode, native, run = gates.encode, gates.native, gates.execute
options = joint.options


def source(guarded, strategy=None):
    return {"guarded": guarded if isinstance(guarded, str) else encode(guarded),
        "windows": strategy if isinstance(strategy, str) else encode(options() if strategy is None else strategy)}


def combined(guarded, statistics):
    return {"format": "moonground.evidence-guarded-transit-windows", "checkpoint_version": "1",
        "guarded": guarded, "windows": statistics}


def host(binary, guarded, strategy, frames):
    initial = native(binary, OLD_CHECKPOINT, [guarded], count=1)[0]
    outputs = native(binary, OLD_STREAM, [guarded] + frames)
    final_guarded = native(binary, OLD_CHECKPOINT, [guarded] + frames, count=1)[0]
    transits = [value["analysis"]["transit"] for value in outputs]
    header = strategy if "resume" in strategy else dict(strategy, transit=encode({"resume": initial["analysis"]["transit"]}))
    grouped = native(binary, windows.STREAM, [header] + transits)
    statistics = native(binary, windows.CHECKPOINT, [header] + transits, count=1)[0]
    if "resume" not in strategy:
        expected, checkpoint = windows.oracle(initial["analysis"]["transit"], strategy, transits)
        assert grouped == expected and statistics == checkpoint
    return ([{"schema_version": "0.1.0", "kind": "evidence_guarded_transit_window_frame", "guarded": left, "windows": right}
        for left, right in zip(outputs, grouped)], combined(final_guarded, statistics), initial)


def check_case(binary, name, guarded, strategy, frames, numeric=None):
    expected, final, initial = host(binary, guarded, strategy, frames)
    header = source(guarded, strategy)
    assert native(binary, STREAM, [header] + frames) == expected, name
    assert native(binary, CHECKPOINT, [header] + frames, count=1)[0] == final, name
    for cut in range(len(frames) + 1):
        saved = native(binary, CHECKPOINT, [header] + frames[:cut], count=1)[0]
        guard_prefix = native(binary, OLD_CHECKPOINT, [guarded] + frames[:cut], count=1)[0]
        if "resume" not in strategy:
            window_prefix = windows.oracle(initial["analysis"]["transit"], strategy,
                [value["guarded"]["analysis"]["transit"] for value in expected[:cut]])[1]
            assert saved == combined(guard_prefix, window_prefix), (name, cut)
        for resumed in [{"resume": saved}, source({"resume": saved["guarded"]}, {"resume": saved["windows"]})]:
            assert native(binary, STREAM, [resumed] + frames[cut:]) == expected[cut:], (name, cut)
            assert native(binary, CHECKPOINT, [resumed] + frames[cut:], count=1)[0] == final, (name, cut)
    return {"name": name, "frames": len(frames), "resume_cut_points": len(frames) + 1,
        "blocked": sum(value["guarded"]["decision"] == "blocked" for value in expected),
        "replacement_barriers": sum(value["guarded"]["kind"] == "evidence_guarded_transit_projection_replaced" for value in expected),
        "passages": sum(len(value["guarded"]["analysis"]["transit"]["passages"]) for value in expected),
        "cancellations": sum(len(value["guarded"]["analysis"]["transit"]["cancellations"]) for value in expected),
        "closed_windows": sum(value["windows"]["closed_window"] is not None for value in expected),
        "numeric_reference": numeric, "checkpoint_sha256": hashlib.sha256(encode(final).encode()).hexdigest()}


def health_fixture(name, times, minimum=1, gap=10, insufficient=()):
    old, config = upstream.replacement_reference.configuration(name, immediate=True)
    config["health"].update(min_observations=minimum, confirmation_us="0", max_gap_us=str(gap))
    old["health"] = encode(config)
    frames = []
    for timestamp in times:
        frame = upstream.replacement_reference.observation_frame(config, timestamp, y=1)
        measurement = json.loads(frame["measurement"])
        measurement["observations"] = []
        frame["measurement"] = encode(measurement)
        if timestamp in insufficient:
            health = json.loads(frame["health"])
            health["observations"] = []
            frame["health"] = encode(health)
        frames.append(frame)
    return upstream.header(old), frames


def reference_checks(binary):
    records = []
    for name, guarded, frames in upstream.fixtures():
        independent, snapshots, absolute, relative, elapsed = upstream.host_reference(binary, guarded, frames)
        assert native(binary, OLD_STREAM, [guarded] + frames) == independent
        records.append(check_case(binary, name, guarded, options(MAX if "int64_final" in name else 250000), frames,
            {"maximum_absolute_oracle_errors": absolute, "maximum_relative_or_scaled_evidence_errors": relative,
                "elapsed_errors_against_exact_fraction_interpolation": elapsed,
                "independent_final_guarded_sha256": hashlib.sha256(encode(snapshots[-1]).encode()).hexdigest()}))
    name, guarded, frames = upstream.pending_replacement_fixture()
    prior = native(binary, OLD_CHECKPOINT, [guarded] + frames[:4], count=1)[0]
    assert prior["analysis"]["transit"]["pending"]
    records.append(check_case(binary, "started_pending_and_old_health_before_statistics_origin", {"resume": prior}, options(100000, origin=1), frames[4:]))
    guarded, frames = health_fixture("window-old-streak-before-origin", [0, 8, 16, 20])
    prior = native(binary, OLD_CHECKPOINT, [guarded] + frames[:2], count=1)[0]
    assert prior["health"]["state"]["streak"]["since_us"] == "0"
    records.append(check_case(binary, "existing_health_streak_before_origin_and_baseline_is_allowed", {"resume": prior}, options(100, origin=1), frames[2:]))
    guarded, frames = health_fixture("window-saturated-long-healthy-streak", list(range(0, 118, 9)) + [118])
    records.append(check_case(binary, "clamped_health_count_preserves_long_continuous_streak", guarded, options(100), frames))
    return {"cases": len(records), **{key: sum(value[key] for value in records) for key in
        ["frames", "resume_cut_points", "blocked", "replacement_barriers", "passages", "cancellations", "closed_windows"]},
        "resume_source_forms": 2, "full_health_measurement_evidence_pending_and_windows_equal": True,
        "offline_integer_statistics_exact": True, "records": records}


def strict_checks(binary):
    cases, relations = [], []

    def bad(name, records, prefix=(), mode=STREAM, payload=None, extra=()):
        result, detail = run(binary, mode, records, status=2, payload=payload, extra=extra)
        assert result == list(prefix), name + ": partial/lost output prefix"
        cases.append(dict(name=name, **detail))

    def incompatible(name, value):
        assert native(binary, OLD_CHECKPOINT, [{"resume": value["guarded"]}], count=1)[0] == value["guarded"]
        raw = joint.combined(value["guarded"]["analysis"], value["windows"])
        assert native(binary, joint.CHECKPOINT, [{"resume": raw}], count=1)[0] == raw
        bad(name, [{"resume": value}])
        relations.append(name)

    def snapshot(name, times, minimum=1, gap=10, width=100, insufficient=()):
        guarded, frames = health_fixture(name, times, minimum, gap, insufficient)
        return native(binary, CHECKPOINT, [source(guarded, options(width))] + frames, count=1)[0]

    # Each old owner restores successfully before the new cross-health rejection.
    value = snapshot("health-since-known", [0, 8, 16, 20])
    value["windows"]["current_window"].update(first_timestamp_us="8", input_frames="3")
    incompatible("known_health_start_before_first_statistics_frame", value)
    value["windows"].update(origin_us="1")
    value["windows"]["current_window"].update(start_us="1", end_exclusive_us="101")
    incompatible("unstarted_health_evidence_before_window_origin", value)
    value = snapshot("health-clamp-gap", [0, 9, 18])
    value["windows"]["current_window"]["input_frames"] = "2"
    incompatible("saturated_streak_requires_unstored_intermediate_health_sample", value)
    value = snapshot("health-cut-bridge", list(range(0, 118, 9)) + [118])
    value["windows"]["current_window"]["first_timestamp_us"] = "109"
    incompatible("continuous_streak_cannot_bridge_unobserved_bucket_prefix", value)
    value = snapshot("health-before-streak-budget", [0, 2, 6, 10], minimum=3, gap=100, insufficient=[0])
    value["windows"]["current_window"]["input_frames"] = "3"
    incompatible("known_pre_streak_frame_cannot_supply_clamped_health_sample", value)
    value = snapshot("health-exact-count-equal-first", [0, 2], minimum=4)
    value["windows"]["current_window"]["input_frames"] = "3"
    incompatible("unsaturated_exact_health_count_cannot_cover_extra_window_frame", value)
    value = snapshot("health-exact-count-before-first", [0, 9, 18], minimum=5, width=10)
    value["windows"]["current_window"].update(first_timestamp_us="17", input_frames="2")
    incompatible("unsaturated_health_count_must_include_old_continuous_samples", value)
    value = snapshot("health-exact-count-after-first", [0, 2, 6], minimum=4, insufficient=[0])
    value["windows"]["current_window"]["input_frames"] = "5"
    incompatible("unsaturated_count_after_first_uses_limited_pre_streak_slots", value)
    # A saved hidden object at t=10 and health start=20 add distinct frame times.
    guarded, frames = health_fixture("health-union-hidden", [0, 10, 20, 25])
    old, config = upstream.replacement_reference.configuration("health-union-hidden", immediate=True)
    for index, identities in enumerate([[1], [2], [], [1]]):
        template = json.loads(upstream.replacement_reference.observation_frame(config, [0, 10, 20, 25][index], y=1)["measurement"])
        observation = template["observations"][0]
        template["observations"] = [dict(observation, track_id=identity) for identity in identities]
        frames[index]["measurement"] = encode(template)
    value = native(binary, CHECKPOINT, [source(guarded, options(100))] + frames, count=1)[0]
    assert value["guarded"]["health"]["state"]["streak"]["since_us"] == "20"
    value["windows"]["current_window"]["input_frames"] = "3"
    incompatible("health_start_must_join_hidden_motion_timestamp_union", value)
    # The middle object sample subdivides an otherwise feasible health gap budget.
    guarded, frames = health_fixture("health-gap-known-object", [0, 8, 17, 18])
    template = upstream.replacement_reference.observation_frame(config, 8, y=1)
    frames[1]["measurement"] = template["measurement"]
    value = native(binary, CHECKPOINT, [source(guarded, options(100))] + frames, count=1)[0]
    value["windows"]["current_window"]["input_frames"] = "3"
    incompatible("known_middle_object_sample_requires_an_extra_health_sample", value)
    guarded, frames = health_fixture("window-guarded-wire", [0, 100000, 200000], minimum=3, gap=500000)
    header = source(guarded)
    for name, value in [
        ("missing_windows", {"guarded": header["guarded"]}),
        ("guarded_not_raw", dict(header, guarded=guarded)),
        ("windows_not_raw", dict(header, windows=options())),
        ("duplicate_source", '{"guarded":"bad",' + encode(header)[1:]),
        ("unknown_source_field", dict(header, extra=True)),
        ("empty_windows", source(guarded, {})),
        ("number_width", source(guarded, dict(options(), window_us=100))),
        ("raw_window_duplicate", source(guarded, '{"window_us":"1",' + encode(options())[1:])),
    ]:
        bad(name, [value])
    initial = native(binary, CHECKPOINT, [header], count=1)[0]
    for name, mutate in [
        ("wrong_format", lambda v: v.update(format="moonground.evidence-guarded-transit")),
        ("wrong_version", lambda v: v.update(checkpoint_version="2")),
        ("unknown_checkpoint_key", lambda v: v.update(extra=True)),
        ("missing_health_config", lambda v: v["guarded"]["health"]["configuration"]["health"].pop("min_observations")),
        ("missing_window_deadband", lambda v: v["windows"]["gates"][0].pop("deadband_m")),
        ("projection_mismatch", lambda v: v["guarded"]["health"]["configuration"]["calibration"].update(ground_noise_floor_m=.02)),
    ]:
        value = copy.deepcopy(initial)
        mutate(value)
        bad(name, [{"resume": value}])
    prefix = native(binary, STREAM, [header, frames[0]])
    invalid = copy.deepcopy(frames[1])
    obj = json.loads(invalid["measurement"])
    obj["observations"] = [upstream.checkpoints.observation(1, [8, 8], [1, 2, 1])]
    invalid["measurement"] = encode(obj)
    bad("blocked_invalid_covariance_still_fatal", [header, frames[0], invalid], prefix)
    bad("unknown_paired_field", [header, frames[0], dict(frames[1], extra=True)], prefix)
    bad("late_failure_no_checkpoint", [header, frames[0], dict(frames[1], extra=True)], mode=CHECKPOINT)
    bad("invalid_utf8_tail", [], prefix, payload=gates.lines([header, frames[0]]).encode() + b"\xff\n")
    origin_header = source(guarded, options(origin=100))
    early = copy.deepcopy(frames[0])
    for key in ["health", "measurement"]:
        item = json.loads(early[key]); item["timestamp_us"] = "99"; early[key] = encode(item)
    origin_initial = native(binary, CHECKPOINT, [origin_header], count=1)[0]
    bad("blocked_candidate_before_window_origin", [origin_header, early])
    for key in ["health", "measurement"]:
        item = json.loads(early[key]); item["timestamp_us"] = "100"; early[key] = encode(item)
    after = native(binary, CHECKPOINT, [{"resume": origin_initial}, early], count=1)[0]
    assert after["guarded"]["health"]["state"]["streak"]["observations"] == 1
    assert after["windows"]["current_window"]["input_frames"] == "1"
    # Confirming health is staged before covariance-normal evaluation fails.
    old, _ = upstream.replacement_reference.configuration("health-confirm-window-rollback")
    huge = upstream.header(old, 1e308)
    _, config = upstream.replacement_reference.configuration("health-confirm-window-rollback")
    proposed = [upstream.replacement_reference.observation_frame(config, stamp, y=1) for stamp in [0, 100000, 200000]]
    huge_header = source(huge)
    pending = native(binary, CHECKPOINT, [huge_header] + proposed[:2], count=1)[0]
    invalid = copy.deepcopy(proposed[2])
    obj = json.loads(invalid["measurement"])
    for observation in obj["observations"]:
        observation["covariance"] = [1e6, 0, 1e6]
    invalid["measurement"] = encode(obj)
    bad("first_healthy_numeric_failure", [huge_header] + proposed[:2] + [invalid], native(binary, STREAM, [huge_header] + proposed[:2]))
    bad("first_healthy_numeric_failure_no_checkpoint", [{"resume": pending}, invalid], mode=CHECKPOINT)
    corrected = native(binary, CHECKPOINT, [{"resume": pending}, proposed[2]], count=1)[0]
    assert corrected["guarded"]["health"]["state"]["streak"]["observations"] == 3
    assert corrected["guarded"]["analysis"]["measurement"]["motion"]["tracks"][0]["segment_id"] == "1"
    assert corrected["windows"]["current_window"]["input_frames"] == "3"
    return {"rejected_cases": len(cases), "independently_valid_incompatible_component_pairs": len(relations),
        "incompatible_pair_names": relations, "cases": cases, "complete_prefix_preserved": True,
        "health_confirmation_and_segment_allocation_same_time_retry_from_saved_state": True,
        "origin_correction_changes_time_not_same_timestamp": True,
        "no_unproved_reachable_window_overflow_claim": True}


def reframe_checks(binary):
    old, _, frames = upstream.guarded.fixture(upstream.camera_reference.CAMERAS[0], "health-window-reframe")
    guarded = upstream.header(old, 3.5)
    header = source(guarded)
    baseline = native(binary, STREAM, [header] + frames)
    cut = 4
    saved = native(binary, CHECKPOINT, [header] + frames[:cut], count=1)[0]
    transform = {"scale_x": .6, "scale_y": 1.3, "offset_x": -40, "offset_y": 16}
    measurement_frames = [json.loads(value["measurement"]) for value in frames[cut:]]
    converted = native(binary, "--reframe", [{"source": {"resume": saved["guarded"]["analysis"]["measurement"]}, "transform": transform}] + measurement_frames)
    changed = copy.deepcopy(saved)
    changed["guarded"]["analysis"]["measurement"] = converted[0]["resume"]
    upstream.replacement_reference.change_projection(changed["guarded"]["health"]["configuration"], converted[0]["resume"]["configuration"])
    future = []
    for old_frame, measured in zip(frames[cut:], converted[1:]):
        health = json.loads(old_frame["health"])
        for observation in health["observations"]:
            observation["point"] = [observation["point"][0] * .6 - 40, observation["point"][1] * 1.3 + 16]
            if "covariance" not in observation: observation["covariance"] = [4, 0, 4]
            xx, xy, yy = observation["covariance"]
            observation["covariance"] = [xx * .6 ** 2, xy * .6 * 1.3, yy * 1.3 ** 2]
        future.append({"measurement": encode(measured), "health": encode(health)})
    expected, final, _ = host(binary, {"resume": changed["guarded"]}, {"resume": changed["windows"]}, future)
    actual = native(binary, STREAM, [{"resume": changed}] + future)
    assert actual == expected
    assert native(binary, CHECKPOINT, [{"resume": changed}] + future, count=1)[0] == final
    assert [value["windows"] for value in actual] == [value["windows"] for value in baseline[cut:]]
    errors = {}; gates.tree_close(actual, baseline[cut:], errors)
    return {"status": "passed", "brown_prefix_frames": cut, "continuation_frames": len(actual),
        "complete_windows_health_streak_pending_and_metric_state_preserved": True,
        "future_integer_windows_exact": True, "maximum_absolute_reframe_differences": errors}


def transport_checks(binary):
    _, guarded, frames = upstream.fixtures()[0]
    header = source(guarded)
    expected = native(binary, STREAM, [header] + frames[:3])
    for ending in [b"\n", b"\r\n"]:
        assert run(binary, STREAM, payload=ending.join(encode(value).encode() for value in [header] + frames[:3]))[0] == expected
    saved = native(binary, CHECKPOINT, [header], count=1)[0]
    exact = encode({"resume": saved}).ljust(8388619)
    assert native(binary, CHECKPOINT, [exact], count=1, extra=["--max-line-bytes", "16777216"])[0] == saved
    _, rejected = run(binary, CHECKPOINT, [exact + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    return {"crlf_and_unterminated_eof": "passed", "exact_resume_utf16_units": len(exact), "source_overflow": rejected}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/evidence-guarded-transit-window.test.mjs"]
    result = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=360)
    if result.returncode:
        raise AssertionError("Node guarded windows failed:\n" + result.stdout[-18000:] + result.stderr[-2000:])
    summary, directions, batch = {}, None, None
    for value in result.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", value)
        if match: summary[match.group(1)] = int(match.group(2))
        if value.startswith('# {"cut_points":'): directions = json.loads(value[2:])
        if value.startswith('# {"successful_empty_frames":'): batch = json.loads(value[2:])
    assert summary.get("tests") and summary["pass"] == summary["tests"] and not summary["fail"] and directions is not None and batch is not None
    return {"status": "passed", "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "command": " ".join(command), "summary": summary, "cross_runtime": directions, "measured_bounded_batch": batch,
        "test_script_sha256": hashlib.sha256((ROOT / "web/evidence-guarded-transit-window.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(result.stdout.encode()).hexdigest(), "stderr": result.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True); parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/evidence-guarded-transit-window-results.json")
    args = parser.parse_args(); binary = args.binary.resolve(); started = time.perf_counter()
    if not binary.is_file(): parser.error("native binary does not exist")
    result = {"format_version": "1", "fixtures": "deterministic", "command": " ".join(shlex.quote(value) for value in [sys.executable] + sys.argv),
        "python": platform.python_version(), "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "guarded_reference_sha256": hashlib.sha256(Path(upstream.__file__).read_bytes()).hexdigest(),
        "window_reference_sha256": hashlib.sha256(Path(windows.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "classification_scope": windows.SCOPE}
    result["independent_guarded_window_and_integer_grouping"] = reference_checks(binary)
    result["strict_health_window_relations"] = strict_checks(binary)
    result["warm_brown_reframe"] = reframe_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    if args.web: result["web_interchange"] = web_checks(binary)
    result.update(status="passed", elapsed_seconds=time.perf_counter() - started)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "output": str(args.output),
        "cases": result["independent_guarded_window_and_integer_grouping"]["cases"],
        "frames": result["independent_guarded_window_and_integer_grouping"]["frames"],
        "resume_cut_points": result["independent_guarded_window_and_integer_grouping"]["resume_cut_points"],
        "strict_rejections": result["strict_health_window_relations"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
