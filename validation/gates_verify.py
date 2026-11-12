#!/usr/bin/env python3
"""Independent finite-line crossing and durable protocol checks for v0.6.

The oracle uses a Cartesian normal and a two-column NumPy linear solve for
intersection parameters. It consumes measured positions; it does not rerun or
make an accuracy claim about the detector, tracker, calibration or filter.
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

import verify as reference


ROOT = Path(__file__).resolve().parents[1]
SEED = 20261116
TOLERANCE = 2.0e-10
SCOPE = "conditional_on_fixed_calibration_camera_and_anchor"


def encode(value):
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), allow_nan=False)


def lines(records):
    return "\n".join(value if isinstance(value, str) else encode(value) for value in records) + "\n"


def execute(binary, mode, records=(), status=0, count=None, payload=None, extra=()):
    payload = lines(records).encode() if payload is None else payload
    result = subprocess.run([str(binary), mode] + list(extra), input=payload,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=str(ROOT), timeout=120)
    stderr = result.stderr.decode("utf-8")
    if result.returncode != status:
        raise AssertionError("{} exit {} != {}: {}".format(mode, result.returncode, status, stderr[:1600]))
    if result.stdout and not result.stdout.endswith(b"\n"):
        raise AssertionError("partial native output line")
    values = [json.loads(value) for value in result.stdout.splitlines()]
    if count is not None and len(values) != count:
        raise AssertionError("{} output lines {} != {}".format(mode, len(values), count))
    if status == 0 and stderr:
        raise AssertionError("successful request emitted stderr: " + stderr)
    return values, {"exit_code": result.returncode, "complete_output_lines": len(values),
        "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
        "stdout_bytes": len(result.stdout), "stderr": stderr.strip()}


def native(binary, mode, records, **kwargs):
    return execute(binary, mode, records, **kwargs)[0]


def gate(identity="entrance", start=(-1, 0), end=(1, 0), deadband=0.05):
    return {"gate_id": identity, "start_m": list(start), "end_m": list(end), "deadband_m": deadband}


def configuration(gates=None, name="gate-reference", quality=None):
    result = {"session_id": name, "gates": gates or [gate()], "max_gap_us": "500000", "max_tracks": 100}
    if quality is not None:
        result["max_position_std_m"] = quality
    return result


def track(identity, point, timestamp, segment="1", status="ready", std=0.1):
    if status == "rejected_projection":
        return {"track_id": identity, "segment_id": None, "status": status,
            "reason": "outside calibration roi", "position_m": None,
            "position_covariance": None, "velocity_mps": None, "velocity_covariance": None,
            "position_std_m": None, "velocity_std_mps": None, "speed_mps": None}
    accepted = status in ("initializing", "ready", "uncertain")
    initializing = status == "initializing"
    return {"track_id": identity, "segment_id": segment, "status": status,
        "position_m": list(point) if accepted else None,
        "position_covariance": [0.01, 0, 0.01] if accepted else None,
        "velocity_mps": [0, 0] if accepted and not initializing else None,
        "velocity_covariance": [0.04, 0, 0.04] if accepted and not initializing else None,
        "position_std_m": std if accepted else None,
        "velocity_std_mps": None if initializing or not accepted else 0.2,
        "speed_mps": 0.0 if status == "ready" else None,
        "observed_path_length_m": 0.0, "net_displacement_m": 0.0,
        "accepted_count": 1 if initializing else 3,
        "last_accepted_timestamp_us": str(timestamp if accepted else timestamp - 1)}


def measurement(timestamp, points=(), closed=(), name="gate-reference"):
    return {"schema_version": "0.2.0", "session_id": name, "timestamp_us": str(timestamp),
        "tracks": list(points), "closed_segment_ids": list(closed), "uncertainty_scope": SCOPE}


def samples(points, *, step=100000, start=0, status="ready", segment="1", identity=1, name="gate-reference"):
    return [measurement(start + i * step,
        [track(identity, point, start + i * step, segment=segment, status=status)], name=name)
        for i, point in enumerate(points)]


class Oracle:
    """Finite segment intersections with explicit sampled-position hysteresis."""

    def __init__(self, config):
        self.config = config
        self.gates = []
        for value in config["gates"]:
            a, b = np.asarray(value["start_m"], float), np.asarray(value["end_m"], float)
            tangent = b - a
            length = np.linalg.norm(tangent)
            normal = np.array([-tangent[1], tangent[0]]) / length
            self.gates.append((a, tangent, normal, value.get("deadband_m", 0.05)))
        self.counts = [[0, 0] for _ in self.gates]
        self.tracks = {}
        self.time = None

    def update(self, frame):
        timestamp = int(frame["timestamp_us"])
        gap = int(self.config.get("max_gap_us", "500000"))
        if self.time is not None and timestamp - self.time >= gap:
            self.tracks.clear()
        present = {item["track_id"] for item in frame["tracks"]}
        for identity in list(self.tracks):
            if identity not in present or self.tracks[identity][0] in frame["closed_segment_ids"]:
                del self.tracks[identity]
        events = []
        for item in sorted(frame["tracks"], key=lambda value: value["track_id"]):
            identity, segment = item["track_id"], item["segment_id"]
            quality = self.config.get("max_position_std_m")
            acceptable = item["status"] in ("initializing", "ready", "uncertain")
            acceptable = acceptable and item["position_m"] is not None
            acceptable = acceptable and int(item.get("last_accepted_timestamp_us", "-1")) == timestamp
            if quality is not None:
                std = item["position_std_m"]
                acceptable = acceptable and std is not None and std <= quality
            if not acceptable:
                self.tracks.pop(identity, None)
                continue
            if identity not in self.tracks or self.tracks[identity][0] != segment:
                self.tracks[identity] = (segment, [None] * len(self.gates))
            anchors = self.tracks[identity][1]
            point = np.asarray(item["position_m"], float)
            for index, (a, tangent, normal, band) in enumerate(self.gates):
                anchor = anchors[index]
                if anchor is not None and timestamp - anchor[0] >= gap:
                    anchor = anchors[index] = None
                signed = np.dot(normal, point - a)
                if abs(signed) <= band:
                    continue
                side = 1 if signed > 0 else -1
                if anchor is not None and anchor[2] != side:
                    before = anchor[1]
                    # before + alpha * (point-before) = a + beta * tangent.
                    alpha, beta = np.linalg.solve(np.column_stack((point - before, -tangent)), a - before)
                    if 0 <= beta <= 1:
                        direction = "negative_to_positive" if side > 0 else "positive_to_negative"
                        self.counts[index][0 if side > 0 else 1] += 1
                        crossing = before + alpha * (point - before)
                        events.append({"gate_id": self.config["gates"][index]["gate_id"],
                            "track_id": identity, "segment_id": segment, "direction": direction,
                            "from_timestamp_us": str(anchor[0]), "to_timestamp_us": str(timestamp),
                            "from_position_m": before.tolist(), "to_position_m": point.tolist(),
                            "position_m": crossing.tolist(), "crossing_fraction": float(alpha)})
                anchors[index] = (timestamp, point.copy(), side)
        self.time = timestamp
        return {"schema_version": "0.1.0", "kind": "gate_events", "session_id": self.config["session_id"],
            "timestamp_us": str(timestamp), "crossings": events,
            "counts": [{"gate_id": value["gate_id"], "negative_to_positive": str(self.counts[i][0]),
                "positive_to_negative": str(self.counts[i][1])} for i, value in enumerate(self.config["gates"])],
            "event_scope": "filtered_ground_positions"}


def tree_close(actual, expected, errors, location="$"):
    if isinstance(expected, dict):
        if set(actual) != set(expected):
            raise AssertionError("{} fields {} != {}".format(location, set(actual), set(expected)))
        for key, value in expected.items():
            tree_close(actual[key], value, errors, location + "." + key)
    elif isinstance(expected, list):
        if len(actual) != len(expected):
            raise AssertionError("{} length {} != {}".format(location, len(actual), len(expected)))
        for index, value in enumerate(expected):
            tree_close(actual[index], value, errors, location + "[{}]".format(index))
    elif isinstance(expected, float):
        label = re.sub(r"\[\d+\]", "[]", location)
        reference.compare(actual, expected, label, errors, tolerance=TOLERANCE)
    elif actual != expected:
        raise AssertionError("{}: {!r} != {!r}".format(location, actual, expected))


def reference_checks(binary, rng):
    cases = []
    cases.append(("directions", configuration(), samples([(0, -1), (0, 1), (0, -1)]), 2))
    cases.append(("finite_extension_then_endpoint", configuration(), samples([(2, -1), (2, 1), (1, 1), (1, -1), (1, 1)]), 2))
    rotated = configuration([gate(start=(0, 0), end=(1, 6), deadband=0)])
    cases.append(("integer_rotated_end_included", rotated, samples([(-5, 7), (7, 5)]), 1))
    cases.append(("integer_rotated_start_included", rotated, samples([(-6, 1), (6, -1)]), 1))
    floating_start = (-56.09727223062044, 29.24953864130191)
    floating_end = (-62.36115774854238, -67.48476557615874)
    floating_gate = configuration([gate(start=floating_start, end=floating_end, deadband=0)])
    cases.append(("floating_rotated_end_included", floating_gate,
        samples([(floating_end[0] - 1, floating_end[1]), (floating_end[0] + 1, floating_end[1])]), 1))
    for epsilon, expected in ((-1e-9, 1), (1e-9, 0)):
        center = np.array([1, 6]) * (1 + epsilon)
        cases.append(("rotated_near_endpoint_{}".format(epsilon), rotated,
            samples([center + [-6, 1], center - [-6, 1]]), expected))
    cases.append(("closed_deadband_and_chord", configuration(), samples([(0, -1), (0, -0.05),
        (4, 0), (0, 0.05), (0, 1), (0, -0.04), (0, 1)]), 1))
    cases.append(("latest_same_side_anchor", configuration(), samples([(-0.8, -2), (0.4, -1), (0.8, 1)]), 1))
    cases.append(("initializing_and_uncertain", configuration(), samples([(0, -1), (0, 1)], status="initializing") +
        samples([(0, -1)], start=200000, status="uncertain"), 2))
    cases.append(("exact_int64_time", configuration(), samples([(0, -1), (0, 1), (0, -1)],
        start=9007199254740993), 2))
    cases.append(("exact_int64_max_time", configuration(), samples([(0, -1), (0, 1)],
        start=9223372036854575807), 1))
    # Every interruption independently breaks the geometrical reference.
    for interruption in ("missing", "rejected_projection", "rejected_innovation", "numerical_failure", "closed", "segment"):
        frames = samples([(0, -1)])
        middle = [] if interruption == "missing" else [track(1, (0, 1), 100000,
            status=interruption if interruption.startswith("rejected") or interruption == "numerical_failure" else "ready",
            segment="2" if interruption == "segment" else "1")]
        if interruption == "closed":
            middle = [track(1, (0, 1), 100000, segment="2")]
        frames.append(measurement(100000, middle, closed=["1"] if interruption == "closed" else []))
        frames.append(measurement(200000, [track(1, (0, 1), 200000, segment="2" if interruption in ("closed", "segment") else "1")]))
        cases.append((interruption + "_breaks_reference", configuration(), frames, 0))
    for delta, expected in ((499999, 1), (500000, 0), (500001, 0)):
        cases.append(("frame_gap_{}".format(delta), configuration(), samples([(0, -1), (0, 1)], step=delta), expected))
    stale = samples([(0, -1), (0, 0), (0, 0), (0, 1)], step=200000)
    cases.append(("deadband_anchor_expires", configuration(), stale, 0))
    quality = samples([(0, -1), (0, 1), (0, -1), (0, 1), (0, -1)])
    quality[1]["tracks"][0]["position_std_m"] = 0.51
    quality[3]["tracks"][0]["position_std_m"] = 0.51
    cases.append(("position_quality_breaks_reference", configuration(quality=0.5), quality, 0))
    equal_quality = samples([(0, -1), (0, 1)])
    for item in equal_quality:
        item["tracks"][0]["position_std_m"] = 0.5
    cases.append(("inclusive_quality_boundary", configuration(quality=0.5), equal_quality, 1))
    # Random rotations and translations avoid a horizontal-only oracle. Pairwise
    # trajectories cross the chosen finite gate at uniformly sampled fractions.
    for index in range(24):
        angle = rng.uniform(-np.pi, np.pi)
        tangent = np.array([np.cos(angle), np.sin(angle)])
        normal = np.array([-tangent[1], tangent[0]])
        center = rng.uniform(-5, 5, 2)
        length = rng.uniform(0.5, 5)
        selected = gate("rotated", center - tangent * length, center + tangent * length, 0.01)
        other = gate("other", center - normal * length, center + normal * length, 0.01)
        config = configuration([selected, other])
        frames = []
        for step in range(12):
            positions = []
            for identity in (7, 2, 19):
                along = rng.uniform(-1.5, 1.5) * length
                across = (-1 if step % 2 == 0 else 1) * rng.uniform(0.1, 2)
                positions.append(track(identity, center + tangent * along + normal * across,
                    step * 30000, segment=str(identity)))
            frames.append(measurement(step * 30000, positions))
        cases.append(("rotated_multigate_{}".format(index), config, frames, None))
    errors, event_count, frame_count = {}, 0, 0
    names = []
    for name, config, frames, manual_count in cases:
        oracle = Oracle(config)
        expected = [oracle.update(value) for value in frames]
        total = sum(len(value["crossings"]) for value in expected)
        if manual_count is not None and total != manual_count:
            raise AssertionError("manual oracle self-check {}: {} != {}".format(name, total, manual_count))
        actual = native(binary, "--count", [config] + frames, count=len(frames))
        tree_close(actual, expected, errors)
        event_count += total
        frame_count += len(frames)
        names.append({"name": name, "frames": len(frames), "crossings": total})
    return {"cases": len(cases), "frames": frame_count, "crossings": event_count,
        "intersection_reference": "NumPy solve of P0 + alpha*(P1-P0) = A + beta*(B-A), beta in [0,1]",
        "maximum_errors": errors, "details": names}


def continuation_checks(binary):
    config = configuration([gate(), gate("vertical", (0, -1), (0, 1))])
    frames = samples([(0.6, -1), (-0.6, 1), (0.2, 0), (0.4, -1), (-0.8, 1),
        (-0.7, 0.01), (0.5, -1), (0, 1)], start=9007199254740993)
    baseline = native(binary, "--count", [config] + frames)
    final = native(binary, "--count-checkpoint", [config] + frames, count=1)[0]
    cuts, errors = 0, {}
    for cut in range(len(frames) + 1):
        saved = native(binary, "--count-checkpoint", [config] + frames[:cut], count=1)[0]
        future = [{"resume": saved}] + frames[cut:]
        tree_close(native(binary, "--count", future), baseline[cut:], errors)
        tree_close(native(binary, "--count-checkpoint", future, count=1)[0], final, errors)
        cuts += 1
    # Durable counters must remain exact beyond Number's integer range.
    large = native(binary, "--count-checkpoint", [config] + frames[:1], count=1)[0]
    large["state"]["counts"][0]["negative_to_positive"] = "9007199254740993"
    counted = native(binary, "--count", [{"resume": large}, frames[1]])[0]
    if counted["counts"][0]["negative_to_positive"] != "9007199254740994":
        raise AssertionError("checkpoint counter lost integer precision")
    # A real pixel -> calibrated measurement stream supplies its unmodified wire
    # output to the independently tested event oracle.
    source = [json.loads(value) for value in (ROOT / "examples/warehouse.ndjson").read_text(encoding="utf-8").splitlines()]
    source[0]["diagnostics"] = True
    measured = native(binary, "--stream", source)
    actual_config = configuration([gate("warehouse", (2.5, -10), (2.5, 10), 0.01)], source[0]["session_id"])
    oracle = Oracle(actual_config)
    expected = [oracle.update(value) for value in measured]
    tree_close(native(binary, "--count", [actual_config] + measured), expected, errors)
    return {"resume_cut_points": cuts, "exact_counter_after_increment": counted["counts"][0]["negative_to_positive"],
        "pixel_measurement_frames": len(measured), "pixel_measurement_crossings": sum(len(v["crossings"]) for v in expected),
        "maximum_errors": errors}


def rejection_checks(binary):
    config = configuration()
    good = samples([(0, -1)])[0]
    later = samples([(0, 1)], start=100000)[0]
    prefix = native(binary, "--count", [config, good])
    cases = {}

    def bad(name, records, expected=(), mode="--count", payload=None, extra=()):
        found, detail = execute(binary, mode, records, status=2, payload=payload, extra=extra)
        if found != list(expected):
            raise AssertionError(name + " exposed a changed or partial output prefix")
        if not detail["stderr"]:
            raise AssertionError(name + " omitted an error explanation")
        cases[name] = detail

    bad("empty_stream", [], payload=b"")
    for name, value in {
        "empty_gates": dict(config, gates=[]),
        "too_many_gates": dict(config, gates=[gate(str(i)) for i in range(17)]),
        "duplicate_gate_id": dict(config, gates=[gate(), gate()]),
        "zero_length_gate": dict(config, gates=[gate(start=(1, 1), end=(1, 1))]),
        "negative_deadband": dict(config, gates=[gate(deadband=-0.1)]),
        "zero_tracks": dict(config, max_tracks=0),
        "tracks_above_bound": dict(config, max_tracks=10001),
        "anchor_budget": dict(config, gates=[gate(str(i)) for i in range(16)], max_tracks=4097),
        "unknown_config": dict(config, extra=True),
        "zero_gap": dict(config, max_gap_us="0"),
        "empty_gate_id": dict(config, gates=[gate("")]),
        "long_gate_id": dict(config, gates=[gate("x" * 129)]),
        "unknown_gate": dict(config, gates=[dict(gate(), extra=1)]),
        "zero_quality": dict(config, max_position_std_m=0),
    }.items():
        bad(name, [value])
    bad("fractional_config_integer", [encode(config).replace('"max_tracks":100', '"max_tracks":100.0000000000000001')])
    bad("duplicate_config_key", ['{"session_id":"gate-reference",' + encode(config)[1:]])
    bad_frames = {
        "session_change": dict(later, session_id="different"),
        "schema_change": dict(later, schema_version="0.3.0"),
        "scope_change": dict(later, uncertainty_scope="different"),
        "same_time": good,
        "unknown_frame": dict(later, extra=True),
        "duplicate_track": dict(later, tracks=later["tracks"] * 2),
        "duplicate_closed_segment": dict(later, closed_segment_ids=["2", "2"]),
    }
    for name, value in bad_frames.items():
        bad(name, [config, good, value], prefix)
    for name, key, value in [
        ("fractional_track", "track_id", 1.5),
        ("negative_track", "track_id", -1),
        ("unknown_status", "status", "predicted"),
        ("missing_accepted_position", "position_m", None),
        ("missing_accepted_std", "position_std_m", None),
        ("bad_covariance", "position_covariance", [1, 2, 1]),
        ("unknown_track_field", "extra", True),
        ("bad_diagnostics_shape", "filter_state", [0, 0]),
    ]:
        invalid = copy.deepcopy(later)
        invalid["tracks"][0][key] = value
        bad(name, [config, good, invalid], prefix)
    bad("fractional_track_token", [config, good, encode(later).replace('"track_id":1', '"track_id":1.0000000000000001')], prefix)
    bad("duplicate_measurement_key", [config, good, '{"timestamp_us":"100000",' + encode(later)[1:]], prefix)
    bad("invalid_utf8", [], prefix, payload=lines([config, good]).encode() + b"\xff\n")
    bad("blank_measurement", [config, good, ""], prefix)
    bad("measurement_payload_limit", [config, good, encode(later) + " " * 1048576], prefix,
        extra=["--max-line-bytes", "16777216"])
    bad("default_physical_limit", [encode(config) + " " * 1048576])
    saved = native(binary, "--count-checkpoint", [config, good], count=1)[0]
    mutations = {
        "checkpoint_format": ("format", "other"),
        "checkpoint_version": ("checkpoint_version", "2"),
        "checkpoint_unknown": ("extra", True),
    }
    for name, (key, value) in mutations.items():
        invalid = copy.deepcopy(saved)
        invalid[key] = value
        bad(name, [{"resume": invalid}])
    for name, mutate in [
        ("negative_counter", lambda v: v["state"]["counts"][0].update(negative_to_positive="-1")),
        ("counter_overflow", lambda v: v["state"]["counts"][0].update(negative_to_positive="9223372036854775808")),
        ("checkpoint_duplicate_track", lambda v: v["state"]["tracks"].append(copy.deepcopy(v["state"]["tracks"][0]))),
        ("checkpoint_future_anchor", lambda v: v["state"]["tracks"][0]["anchors"][0].update(timestamp_us="1")),
        ("checkpoint_anchor_on_gate", lambda v: v["state"]["tracks"][0]["anchors"][0].update(point_m=[0, 0])),
        ("checkpoint_anchor_count", lambda v: v["state"]["tracks"][0].update(anchors=[])),
    ]:
        invalid = copy.deepcopy(saved)
        mutate(invalid)
        bad(name, [{"resume": invalid}])
    bad("resume_override", [{"resume": saved, "session_id": "override"}])
    saturated = copy.deepcopy(saved)
    saturated["state"]["counts"][0]["negative_to_positive"] = "9223372036854775807"
    bad("counter_overflow_on_event", [{"resume": saturated}, later])
    unrepresentable = configuration([gate(start=(0, -1), end=(0, 1), deadband=0)])
    extreme_frames = samples([(1e308, 0), (-1, 0)])
    extreme_prefix = native(binary, "--count", [unrepresentable, extreme_frames[0]])
    bad("unrepresentable_open_crossing_fraction", [unrepresentable] + extreme_frames, extreme_prefix)
    # Checkpoint mode exports a single complete document only on successful EOF.
    bad("checkpoint_mode_late_error", [config, good, dict(later, extra=True)], mode="--count-checkpoint")
    expected = native(binary, "--count", [config, good, later])
    for ending in (b"\n", b"\r\n"):
        actual = execute(binary, "--count", payload=ending.join(encode(v).encode() for v in [config, good, later]))[0]
        if actual != expected:
            raise AssertionError("CRLF or unterminated EOF changed results")
    maximum = max(len(encode(value).encode()) for value in [config, good, later])
    actual = native(binary, "--count", [config, good, later], extra=["--max-line-bytes", str(maximum)])
    if actual != expected:
        raise AssertionError("exact physical line boundary changed results")
    padded_later = encode(later) + " " * 128
    bad("physical_limit_one_byte_below_measurement", [config, good, padded_later], prefix,
        extra=["--max-line-bytes", str(len(padded_later.encode()) - 1)])
    return {"rejected_cases": len(cases), "cases": cases, "complete_prefix_preserved": True,
        "crlf_and_unterminated_eof": "passed", "exact_physical_line_boundary_bytes": maximum}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/gates.test.mjs"]
    environment = dict(os.environ, MOONGROUND_CLI=str(binary))
    run = subprocess.run(command, cwd=str(ROOT), env=environment, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=240)
    if run.returncode:
        raise AssertionError("Node gate verification failed:\n" + run.stdout[-14000:] + run.stderr[-2000:])
    summary = {}
    for value in run.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", value)
        if match:
            summary[match.group(1)] = int(match.group(2))
    if not summary.get("tests") or summary.get("pass") != summary["tests"] or summary.get("fail"):
        raise AssertionError("incomplete Node summary")
    return {"status": "passed", "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "command": " ".join(command), "summary": summary,
        "test_script_sha256": hashlib.sha256((ROOT / "web/gates.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(run.stdout.encode()).hexdigest(), "stderr": run.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/gates-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "seed": SEED, "tolerance": TOLERANCE,
        "command": " ".join(shlex.quote(value) for value in [sys.executable] + sys.argv),
        "python": platform.python_version(), "numpy": np.__version__, "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["finite_segment_reference"] = reference_checks(binary, np.random.default_rng(SEED))
    result["durable_continuation"] = continuation_checks(binary)
    result["strict_transport"] = rejection_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    result["status"] = "passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(result, ensure_ascii=True, indent=2) + "\n")
    print(encode({"status": "passed", "output": str(args.output),
        "reference_cases": result["finite_segment_reference"]["cases"],
        "reference_crossings": result["finite_segment_reference"]["crossings"],
        "resume_cut_points": result["durable_continuation"]["resume_cut_points"],
        "strict_rejections": result["strict_transport"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
