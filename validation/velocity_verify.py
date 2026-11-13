#!/usr/bin/env python3
"""Independent directed velocity bands: Decimal exact binary64 and NumPy.

The axis follows the public one-time scaled binary64 normalization contract.
No production LDL factorization or dot compensation is used. Real motion
outputs are projected after old checkpoint continuations; every
velocity request is independent, including repeated and reordered frames.
"""

import argparse
import copy
import decimal
import hashlib
import json
import math
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
import gates_verify as gates
import reframe_verify as reframe_reference
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
MODE = "--velocity-evidence"
SEED = 20261130
MAX = 9223372036854775807
encode, native, run = gates.encode, gates.native, gates.execute
D = decimal.Decimal


def probe(identity="forward", direction=(1, 0), threshold=0, multiplier=2):
    return {"probe_id": identity, "direction": list(direction),
        "threshold_mps": threshold, "sigma_multiplier": multiplier}


def configuration(name="velocity-reference", probes=None, capacity=32):
    return {"session_id": name, "probes": probes or [probe()], "max_tracks": capacity}


def measured(config, timestamp=0, vector=(1, 0), covariance=(.01, 0, .01), identity=1, segment="1", status="ready"):
    item = gates.track(identity, (0, 0), timestamp, segment=segment, status=status)
    if status in ("ready", "uncertain"):
        norm = math.hypot(*vector)
        item.update(velocity_mps=list(vector), velocity_covariance=list(covariance),
            velocity_std_mps=math.sqrt(max(covariance[0], covariance[2])),
            speed_mps=(norm if math.isfinite(norm) else 0) if status == "ready" else None)
    return gates.measurement(timestamp, [item], name=config["session_id"])


def exact_band(config, vector, covariance):
    # The model direction is the constructor's binary64 axis, rather than an
    # ideal real-number axis: a one-ULP change matters for nearly zero dots.
    scaled = np.asarray(config["direction"], dtype=float)
    scaled /= max(abs(scaled))
    axis = scaled / math.hypot(*scaled)
    with decimal.localcontext() as context:
        context.prec = 180
        x, y = [D.from_float(float(value)) for value in axis]
        vx, vy = [D.from_float(float(value)) for value in vector]
        xx, xy, yy = [D.from_float(float(value)) for value in covariance]
        component = x * vx + y * vy
        variance = x*x*xx + 2*x*y*xy + y*y*yy
        assert variance > 0
        sigma = variance.sqrt()
        radius = D.from_float(float(config.get("sigma_multiplier", 2))) * sigma
        lower, upper = component - radius, component + radius
        # Decisions compare the represented closed band. Keep the high-precision
        # numbers for accuracy, then round its endpoints to the public Double.
        threshold = float(config["threshold_mps"])
        decision = "above" if float(lower) > threshold else "at_or_below" if float(upper) <= threshold else "indeterminate"
        return {"probe_id": config["probe_id"], "component_mps": float(component),
            "axis_std_mps": float(sigma), "lower_mps": float(lower), "upper_mps": float(upper),
            "threshold_mps": config["threshold_mps"], "sigma_multiplier": config.get("sigma_multiplier", 2),
            "decision": decision}


def oracle(config, frame):
    evidence, unavailable = [], []
    for item in sorted(frame["tracks"], key=lambda value: value["track_id"]):
        if item["status"] != "ready":
            unavailable.append({"track_id": item["track_id"], "segment_id": item["segment_id"], "reason": item["status"]})
        else:
            for selected in config["probes"]:
                evidence.append(dict(track_id=item["track_id"], segment_id=item["segment_id"],
                    **exact_band(selected, item["velocity_mps"], item["velocity_covariance"])))
    return {"schema_version": "0.1.0", "kind": "velocity_evidence_frame",
        "evidence_scope": "model_velocity_component_band", "session_id": frame["session_id"],
        "timestamp_us": frame["timestamp_us"], "evidence": evidence, "unavailable": unavailable}


def compare(actual, expected, absolute, relative):
    for key in expected:
        if key not in ("evidence",):
            assert actual[key] == expected[key], (key, actual[key], expected[key])
    assert set(actual) == set(expected) and len(actual["evidence"]) == len(expected["evidence"])
    for left, right in zip(actual["evidence"], expected["evidence"]):
        assert set(left) == set(right)
        for key, value in right.items():
            if key in ("component_mps", "axis_std_mps", "lower_mps", "upper_mps"):
                error = abs(left[key] - value)
                scaled = error / max(abs(value), 1e-300)
                absolute[key] = max(absolute.get(key, 0), error)
                relative[key] = max(relative.get(key, 0), scaled)
                assert error <= 4e-10 * max(abs(value), 1e-300), (key, left[key], value)
            else:
                assert left[key] == value, (key, left[key], value)


def fixtures():
    result = []
    selected = [probe("forward", (1, 0), .5), probe("backward", (-1, 0), -.5),
        probe("diagonal", (3, 4), -.25), probe("vertical", (0, 1), 0)]
    head = configuration(probes=selected)
    result.append(("anisotropic_axis_not_worst_direction", head, [measured(head, vector=(1, 0), covariance=(1e-6, 0, 1e6))]))
    for scale in (1e-150, 1, 1e150):
        for sign in (-1, 1):
            p = probe("correlated", (3, 4), 0)
            head = configuration("correlation-{}-{}".format(scale, sign), [p])
            result.append((head["session_id"], head, [measured(head, vector=(3*scale, scale), covariance=(scale*scale, sign*.9*scale*scale, scale*scale))]))
        p = probe("near-supported", (1, 1), 0)
        head = configuration("supported-correlation-{}".format(scale), [p])
        result.append((head["session_id"], head, [measured(head, vector=(scale, scale), covariance=(scale*scale, -(1-1e-10)*scale*scale, scale*scale))]))
    for direction in ((1e308, 1e308), (5e-324, 5e-324), (1e-300, 2e-300), (3, 4), (3e250, 4e250), (-3, -4)):
        head = configuration("normalization-{}".format(len(result)), [probe(direction=direction)])
        result.append((head["session_id"], head, [measured(head, vector=(1, 2), covariance=(4, 1.8, 1))]))
    for name, direction, vector, multiplier in [
        ("exact_orthogonal_zero", (1, 1), (1, -1), 2),
        ("ordinary_compensated_near_orthogonal", (.6, .8), (4, -3), 2),
        ("huge_compensated_dot_k_zero", (.6, .8), (1e300, -7.5e299), 0),
        ("minimum_subnormal_component_k_zero", (1, 0), (5e-324, 0), 0),
    ]:
        head = configuration(name, [probe(direction=direction, multiplier=multiplier)])
        result.append((name, head, [measured(head, vector=vector, covariance=(1, 0, 1))]))
    head = configuration("optional_configuration_defaults")
    del head["max_tracks"]
    del head["probes"][0]["sigma_multiplier"]
    result.append(("optional_configuration_defaults", head, [measured(head)]))
    for k in (0, 2):
        for velocity in (0, 1, float(np.nextafter(1., 0.)), float(np.nextafter(1., 2.)), -1):
            head = configuration("closed-equality-{}-{}".format(k, len(result)), [probe(threshold=1 if k == 0 else .5, multiplier=k)])
            result.append((head["session_id"], head, [measured(head, vector=(velocity, 0), covariance=(.0625, 0, .0625))]))
    head = configuration("lifecycle")
    statuses = ("initializing", "ready", "uncertain", "rejected_innovation", "numerical_failure", "rejected_projection")
    frames = [measured(head, 10+i, status=status) for i, status in enumerate(statuses)]
    frames += [gates.measurement(3, name=head["session_id"]), measured(head, MAX), measured(head, 9007199254740993)]
    result.append(("all_statuses_empty_and_exact_clock", head, frames))
    head = configuration("configured_probe_and_identity_order", [probe(str(i), (1, i % 2), i/10) for i in range(16)])
    frame = measured(head, 7)
    frame["tracks"] = [dict(copy.deepcopy(frame["tracks"][0]), track_id=i, segment_id=str(i)) for i in (9, 2, 5)]
    result.append(("sixteen_probes_sorted_targets", head, [frame]))
    return result


def numeric_checks(binary):
    absolute, relative, numpy_errors, rows, records, decisions = {}, {}, {}, 0, [], set()
    for name, head, frames in fixtures():
        actual = native(binary, MODE, [head] + frames)
        assert len(actual) == len(frames)
        for frame, output in zip(frames, actual):
            compare(output, oracle(head, frame), absolute, relative)
            rows += len(output["evidence"])
            decisions.update(value["decision"] for value in output["evidence"])
            for item in frame["tracks"]:
                if item["status"] != "ready": continue
                for selected in head["probes"]:
                    direction = np.asarray(selected["direction"], float)
                    direction /= max(abs(direction))
                    direction /= np.linalg.norm(direction)
                    matrix = reference.covariance_matrix(item["velocity_covariance"])
                    # NumPy is a second oracle only in a well-conditioned domain.
                    if np.linalg.cond(matrix) < 1e6 and np.max(abs(matrix)) < 1e200:
                        expected = exact_band(selected, item["velocity_mps"], item["velocity_covariance"])
                        reference.compare(float(np.sqrt(direction @ matrix @ direction)), expected["axis_std_mps"], "axis_std_mps", numpy_errors, tolerance=1e-9)
        order = list(reversed(range(len(frames)))) + list(range(len(frames)))
        assert native(binary, MODE, [head] + [frames[index] for index in order]) == [actual[index] for index in order]
        records.append({"name": name, "frames": len(frames), "evidence_rows": sum(len(value["evidence"]) for value in actual)})
    assert decisions == {"above", "at_or_below", "indeterminate"}
    return {"cases": len(records), "frames": sum(value["frames"] for value in records), "evidence_rows": rows,
        "maximum_absolute_decimal_errors": absolute, "maximum_relative_or_scaled_decimal_errors": relative,
        "maximum_absolute_numpy_vs_decimal_errors": numpy_errors, "repeat_and_reordering_exact": True, "records": records}


def real_frame_checks(binary):
    records, statuses, absolute, relative = [], set(), {}, {}
    cuts = 0
    for name, measurement, _, frames in analysis_reference.fixtures():
        produced = native(binary, "--stream", [measurement] + frames)
        head = configuration(measurement["session_id"], [probe(), probe("across", (0, 1), -.1), probe("diagonal", (3, 4), .2)])
        expected = native(binary, MODE, [head] + produced)
        for frame, output in zip(produced, expected):
            compare(output, oracle(head, frame), absolute, relative)
            statuses.update(item["status"] for item in frame["tracks"])
        for cut in range(len(frames) + 1):
            saved = native(binary, "--checkpoint", [measurement] + frames[:cut], count=1)[0]
            continued = native(binary, "--stream", [{"resume": saved}] + frames[cut:])
            assert continued == produced[cut:]
            assert native(binary, MODE, [head] + continued) == expected[cut:]
            cuts += 1
        records.append({"name": name, "frames": len(frames), "old_checkpoint_cut_points": len(frames)+1,
            "evidence_rows": sum(len(value["evidence"]) for value in expected)})
    required = {"initializing", "ready", "uncertain", "rejected_innovation", "numerical_failure", "rejected_projection"}
    assert required.issubset(statuses), required - statuses
    return {"cases": len(records), "frames": sum(value["frames"] for value in records), "old_checkpoint_cut_points": cuts,
        "statuses": sorted(statuses), "old_checkpoint_continuation_exact": True,
        "independent_authored_motion_numpy": checkpoints.independent_reference_checks(binary),
        "maximum_absolute_decimal_errors": absolute, "maximum_relative_or_scaled_decimal_errors": relative, "records": records}


def rejection_checks(binary):
    head = configuration()
    frame = measured(head, 100)
    prefix = native(binary, MODE, [head, frame])
    records = []
    def bad(name, source=head, value=None, payload=None):
        values, metadata = run(binary, MODE, [source, frame, value] if value is not None else [source], status=2, payload=payload)
        assert values == (prefix if value is not None or payload is not None else []), name
        records.append(dict(name=name, **metadata))
    for name, mutate in [
        ("empty_probes", lambda v: v.update(probes=[])), ("seventeen_probes", lambda v: v.update(probes=[probe(str(i)) for i in range(17)])),
        ("duplicate_probe_ids", lambda v: v.update(probes=[probe(), probe()])), ("zero_direction", lambda v: v["probes"][0].update(direction=[0, 0])),
        ("direction_component_underflow", lambda v: v["probes"][0].update(direction=[1e-300, 1e300])),
        ("negative_multiplier", lambda v: v["probes"][0].update(sigma_multiplier=-1)), ("empty_probe_id", lambda v: v["probes"][0].update(probe_id="")),
        ("long_probe_id", lambda v: v["probes"][0].update(probe_id="x"*129)), ("unknown_probe_key", lambda v: v["probes"][0].update(extra=0)),
        ("empty_session", lambda v: v.update(session_id="")), ("zero_capacity", lambda v: v.update(max_tracks=0)),
        ("too_large_capacity", lambda v: v.update(max_tracks=10001)), ("unknown_source_key", lambda v: v.update(extra=0)),
        ("resume_not_supported", lambda v: v.update(resume={})),
    ]:
        value = copy.deepcopy(head); mutate(value); bad(name, value)
    for name, source in [("fractional_capacity", encode(head).replace('"max_tracks":32', '"max_tracks":32.000000000000001')),
        ("duplicate_source", '{"session_id":"other",'+encode(head)[1:]),
        ("duplicate_probe_number", encode(head).replace('"threshold_mps":0', '"threshold_mps":0,"threshold_mps":1')),
        ("nonfinite_threshold", encode(head).replace('"threshold_mps":0', '"threshold_mps":1e999'))]:
        bad(name, source)
    for name, mutate in [
        ("wrong_session", lambda v: v.update(session_id="other")), ("future_accepted_time", lambda v: v["tracks"][0].update(last_accepted_timestamp_us="101")),
        ("stale_ready_time", lambda v: v["tracks"][0].update(last_accepted_timestamp_us="99")),
        ("missing_ready_velocity", lambda v: v["tracks"][0].update(velocity_mps=None)), ("missing_ready_covariance", lambda v: v["tracks"][0].update(velocity_covariance=None)),
        ("non_spd_velocity_covariance", lambda v: v["tracks"][0].update(velocity_covariance=[1, 2, 1])),
        ("duplicate_track", lambda v: v["tracks"].append(copy.deepcopy(v["tracks"][0]))),
        ("duplicate_segment", lambda v: v["tracks"].append(dict(copy.deepcopy(v["tracks"][0]), track_id=2))),
        ("noncanonical_segment", lambda v: v["tracks"][0].update(segment_id="01")),
        ("zero_segment", lambda v: v["tracks"][0].update(segment_id="0")),
        ("accepted_segment_also_closed", lambda v: v.update(closed_segment_ids=["1"])),
        ("duplicate_closed_segment", lambda v: v.update(closed_segment_ids=["2", "2"])),
        ("unknown_measurement_key", lambda v: v.update(extra=True)),
    ]:
        value = copy.deepcopy(frame); mutate(value); bad(name, value=value)
    bad("fractional_track_token", value=encode(frame).replace('"track_id":1', '"track_id":1.0000000000000001'))
    bad("duplicate_raw_measurement", value='{"timestamp_us":"100",'+encode(frame)[1:])
    for name, vector, covariance, selected in [
        ("near_singular_correlation", (1, 1), (1, float(np.nextafter(1., 0.)), 1), probe(direction=(1, -1))),
        ("radius_overflow", (1, 0), (1e308, 0, 1e308), probe(multiplier=1e308)),
        ("radius_underflow", (0, 0), (5e-324, 0, 5e-324), probe(multiplier=5e-324)),
        ("endpoint_swallowing", (1e300, 0), (1, 0, 1), probe()),
        ("nonrepresentable_dot", (1.7e308, 1.7e308), (1, 0, 1), probe(direction=(1, 1))),
        ("compensated_dot_counterexample", (1e300, -7.5e299), (1, 0, 1), probe(direction=(.6, .8))),
        ("dot_scaling_loses_nonzero_term", (1e-300, 1e300), (1, 0, 1), probe()),
    ]:
        source = configuration(probes=[selected]); value = measured(source, 100, vector, covariance)
        # Every successful earlier line must survive a later numerical error.
        good = measured(source, 100, (0, 0), (1, 0, 1))
        if name == "radius_overflow": good = measured(source, 100, (0, 0), (1e-300, 0, 1e-300))
        if name == "radius_underflow":
            values, metadata = run(binary, MODE, [source, value], status=2)
            assert not values
        else:
            prior = native(binary, MODE, [source, good])
            values, metadata = run(binary, MODE, [source, good, value], status=2)
            assert values == prior
        records.append(dict(name=name, **metadata))
    bad("invalid_utf8_tail", payload=gates.lines([head, frame]).encode()+b"\xff\n")
    _, missing = run(binary, MODE, [], status=2, payload=b"")
    records.append(dict(name="missing_header", **missing))
    # Exact raw integer, despite noncanonical numeric token spelling, is legal.
    legal = encode(frame).replace('"track_id":1', '"track_id":10e-1')
    assert native(binary, MODE, [head, legal]) == prefix
    return {"rejected_cases": len(records), "cases": records, "complete_prefix_preserved": True,
        "mathematically_integral_id_token": "passed", "no_persistent_checkpoint_or_watermark": True}


def reframe_checks(binary):
    measurement_source = reframe_reference.configuration(camera_reference.CAMERAS[0], "velocity-warm-brown")
    measurement_source["motion"].update(min_observations=2, min_span_us="100000", max_velocity_std_mps=1e5, max_position_std_m=1e5)
    frames = [checkpoints.frame(index*100000, [checkpoints.observation(1,
        camera_reference.distort_pixel([580+index*2, 330+index*.5], camera_reference.CAMERAS[0]), [4, .7, 6])]) for index in range(8)]
    prefix = native(binary, "--checkpoint", [measurement_source]+frames[:4], count=1)[0]
    expected_measurements = native(binary, "--stream", [{"resume": prefix}]+frames[4:])
    changed = reframe_reference.reframe(binary, [{"resume": prefix}]+frames[4:], reframe_reference.TRANSFORMS[1])
    actual_measurements = native(binary, "--stream", changed)
    head = configuration(measurement_source["session_id"], [probe(), probe("diag", (3, 4), -.1)])
    expected, actual = native(binary, MODE, [head]+expected_measurements), native(binary, MODE, [head]+actual_measurements)
    errors = {}; gates.tree_close(actual, expected, errors)
    assert sum(len(value["evidence"]) for value in actual) > 0
    return {"status": "passed", "brown_warm_prefix_frames": 4, "continuation_frames": 4,
        "maximum_absolute_metric_reframe_differences": errors}


def transport_checks(binary):
    head, frame = configuration(), measured(configuration(), 5)
    expected = native(binary, MODE, [head, frame])
    for ending in (b"\n", b"\r\n"):
        assert run(binary, MODE, payload=ending.join(encode(v).encode() for v in [head, frame]))[0] == expected
    raw = encode(head).ljust(1048576)
    assert native(binary, MODE, [raw, frame]) == expected
    _, rejected = run(binary, MODE, [raw+" ", frame], status=2, extra=["--max-line-bytes", "16777216"])
    raw_frame = encode(frame).ljust(1048576)
    assert native(binary, MODE, [head, raw_frame]) == expected
    values, too_long = run(binary, MODE, [head, frame, raw_frame+" "], status=2, extra=["--max-line-bytes", "16777216"])
    assert values == expected
    return {"crlf_and_unterminated_eof": "passed", "source_and_frame_exact_units": 1048576,
        "source_overflow": rejected, "frame_overflow_complete_prefix": too_long}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/velocity.test.mjs"]
    result = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", timeout=360)
    if result.returncode: raise AssertionError("Node velocity failed:\n"+result.stdout[-16000:]+result.stderr[-2000:])
    summary, cross, batch = {}, None, None
    for line in result.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", line)
        if match: summary[match.group(1)] = int(match.group(2))
        if line.startswith('# {"cut_points":'): cross = json.loads(line[2:])
        if line.startswith('# {"successful_empty_frames":'): batch = json.loads(line[2:])
    assert summary.get("tests") and summary["pass"] == summary["tests"] and not summary["fail"] and cross and batch
    return {"status": "passed", "node": subprocess.check_output(["node", "--version"], text=True).strip(), "summary": summary,
        "command": " ".join(command), "old_checkpoint_cross_runtime": cross, "measured_bounded_batch": batch,
        "test_script_sha256": hashlib.sha256((ROOT/"web/velocity.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT/"_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(result.stdout.encode()).hexdigest(), "stderr": result.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True); parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT/"validation/velocity-results.json")
    args = parser.parse_args(); binary = args.binary.resolve(); started = time.perf_counter()
    result = {"format_version": "1", "fixtures": "deterministic", "seed": SEED, "command": " ".join(shlex.quote(v) for v in [sys.executable]+sys.argv),
        "python": platform.python_version(), "numpy": np.__version__, "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "evidence_scope": "model_velocity_component_band", "scaled_error_denominator": "max(abs(reference),1e-300)", "decision_reference": "compare independently computed band endpoints after rounding to binary64", "independent_reference": "Public scaled binary64 axis normalization; Decimal.from_float at 180 digits for direct dot and quadratic form; NumPy secondary well-conditioned oracle"}
    result["numeric_reference"] = numeric_checks(binary)
    result["original_motion_and_checkpoint_continuations"] = real_frame_checks(binary)
    result["strict_and_numerical_rejections"] = rejection_checks(binary)
    result["warm_brown_reframe"] = reframe_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    if args.web: result["web_interchange"] = web_checks(binary)
    result.update(status="passed", elapsed_seconds=time.perf_counter()-started)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as f: f.write(json.dumps(result, indent=2, ensure_ascii=True)+"\n")
    print(encode({"status": "passed", "numeric_cases": result["numeric_reference"]["cases"], "real_cases": result["original_motion_and_checkpoint_continuations"]["cases"],
        "strict_rejections": result["strict_and_numerical_rejections"]["rejected_cases"], "output": str(args.output)}))


if __name__ == "__main__":
    main()
