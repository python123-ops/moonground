#!/usr/bin/env python3
"""Independent fixed-landmark calibration-health and durable protocol checks.

NumPy homogeneous projection, matrix covariance propagation, and the existing
Newton Brown inverse are the numerical reference. Temporal evidence uses Python
integers; it never derives absolute timestamps through floating-point values.
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

import camera_verify as camera_reference
import gates_verify as transport
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
TOLERANCE = 2.0e-8
encode = transport.encode
lines = transport.lines


def run(binary, mode, records=(), status=0, count=None, payload=None, extra=()):
    return transport.execute(binary, mode, records, status=status, count=count,
                             payload=payload, extra=extra)


def native(binary, mode, records=(), **kwargs):
    return run(binary, mode, records, **kwargs)[0]


def tree_close(actual, expected, errors, location="$"):
    if isinstance(expected, dict):
        if not isinstance(actual, dict) or set(actual) != set(expected):
            raise AssertionError(location + ": JSON fields differ")
        for key, value in expected.items():
            tree_close(actual[key], value, errors, location + "." + key)
    elif isinstance(expected, list):
        if not isinstance(actual, list) or len(actual) != len(expected):
            raise AssertionError(location + ": JSON array shape differs")
        for index, value in enumerate(expected):
            tree_close(actual[index], value, errors, location + "[{}]".format(index))
    elif isinstance(expected, (int, float)) and not isinstance(expected, bool):
        if re.search(r"\.(usable_count|streak_observations|min_observations|min_landmarks|observations)$", location):
            if actual != expected:
                raise AssertionError(location + ": integer changed")
        else:
            label = re.sub(r"\[\d+\]", "[]", location)
            reference.compare(actual, expected, label, errors, tolerance=TOLERANCE)
    elif actual != expected:
        raise AssertionError("{}: {!r} != {!r}".format(location, actual, expected))


def polygon_contains(vertices, point):
    """Independent triangle-fan membership, rather than production edge tests."""
    vertices = np.asarray(vertices, dtype=float)
    point = np.asarray(point, dtype=float)
    for index in range(1, len(vertices) - 1):
        basis = np.column_stack((vertices[index] - vertices[0], vertices[index + 1] - vertices[0]))
        weights = np.linalg.solve(basis, point - vertices[0])
        if np.all(weights >= -1e-12) and np.sum(weights) <= 1 + 1e-12:
            return True
    return False


def project(config, point, covariance):
    calibration = config["calibration"]
    matrix = np.asarray(calibration["matrix"], dtype=float).reshape(3, 3)
    floor = calibration.get("ground_noise_floor_m", 0.001)
    camera = config.get("camera")
    if camera is None:
        ideal = np.asarray(point, dtype=float)
        position, propagated, _ = reference.project_reference(matrix, point, covariance, floor)
    else:
        position, propagated, _, ideal = camera_reference.project_reference(point, covariance, camera, matrix, floor)
    if not polygon_contains(calibration["roi"], ideal):
        raise ValueError("outside calibration ROI")
    return position, propagated


def observation(identity, point, covariance=None):
    value = {"landmark_id": identity, "point": np.asarray(point).tolist()}
    if covariance is not None:
        value["covariance"] = list(covariance)
    return value


def frame(timestamp, observations=()):
    return {"timestamp_us": str(timestamp), "observations": list(observations)}


DEFAULTS = {"min_landmarks": 3, "rms_limit_m": 0.1, "max_error_m": 0.2,
    "confirmation_us": "300000", "min_observations": 3, "max_gap_us": "500000"}
SCOPE = "observed_fixed_landmarks_under_fixed_calibration"


def configuration(name="health-reference", camera=None):
    calibration = {"matrix": [0.125, 0, 0, 0, 0.125, 0, 0, 0, 1],
        "roi": [[-100, -100], [100, -100], [100, 100], [-100, 100]],
        "max_meters_per_pixel": 0.5, "ground_noise_floor_m": 0.001}
    ideals = [[8, 8], [24, 8], [8, 24], [24, 24]]
    if camera is not None:
        calibration = camera_reference.calibration()
        ideals = [[430, 250], [760, 250], [430, 480], [760, 480]]
    matrix = np.asarray(calibration["matrix"]).reshape(3, 3)
    landmarks = []
    for identity, ideal in zip("ABCD", ideals):
        homogeneous = matrix @ np.r_[ideal, 1.0]
        landmarks.append({"landmark_id": identity, "ground_m": (homogeneous[:2] / homogeneous[2]).tolist()})
    result = {"monitor_id": name, "calibration": calibration, "landmarks": landmarks,
        "health": dict(DEFAULTS, max_position_std_m=0.2)}
    if camera is not None:
        result["camera"] = copy.deepcopy(camera)
    return result, ideals


def observations(config, ideals, offset=(0, 0), covariance=(0.04, 0.008, 0.09)):
    values = []
    for landmark, ideal in zip(config["landmarks"], ideals):
        point = np.asarray(ideal, dtype=float) + offset
        if config.get("camera") is not None:
            point = camera_reference.distort_pixel(point, config["camera"])
        values.append(observation(landmark["landmark_id"], point, covariance))
    return values


class Oracle:
    """Recompute projection and a sampled evidence run with exact Python time."""

    def __init__(self, config):
        self.config = config
        self.health = dict(DEFAULTS, **config.get("health", {}))
        self.last = None
        self.evidence = None
        self.since = None
        self.count = 0

    def update(self, source):
        timestamp = int(source["timestamp_us"])
        supplied = {value["landmark_id"]: value for value in source["observations"]}
        results, errors = [], []
        for known in self.config["landmarks"]:
            result = {"landmark_id": known["landmark_id"], "projected_position_m": None,
                "projected_covariance": None, "residual_m": None, "error_m": None,
                "position_std_m": None, "rejection_reason": "missing"}
            current = supplied.get(known["landmark_id"])
            if current is not None:
                try:
                    point, covariance = project(self.config, current["point"], current.get("covariance", [4, 0, 4]))
                except ValueError:
                    result["rejection_reason"] = "__projection__"
                else:
                    deviation = math.sqrt(float(np.linalg.eigvalsh(covariance)[-1]))
                    result.update(projected_position_m=point.tolist(),
                        projected_covariance=reference.compact_covariance(covariance), position_std_m=deviation)
                    quality = self.health.get("max_position_std_m")
                    if quality is not None and deviation > quality:
                        result["rejection_reason"] = "position_uncertainty"
                    else:
                        residual = [float(point[axis]) - known["ground_m"][axis] for axis in (0, 1)]
                        error = math.hypot(*residual)
                        if not all(math.isfinite(value) for value in residual) or not math.isfinite(error):
                            result["rejection_reason"] = "__numerical__"
                        else:
                            result.update(residual_m=residual, error_m=error, rejection_reason=None)
                            errors.append(error)
            results.append(result)
        rms = None
        maximum = None
        if errors:
            # Decimal squaring is independent of production's scaled RMS and
            # remains finite when individual binary64 errors would square to inf.
            with decimal.localcontext() as context:
                context.prec = 70
                total = sum(decimal.Decimal.from_float(value) ** 2 for value in errors)
                rms = float((total / len(errors)).sqrt())
            maximum = max(errors)
        evidence = "insufficient"
        if len(errors) >= self.health["min_landmarks"]:
            evidence = "within_tolerance" if rms <= self.health["rms_limit_m"] and maximum <= self.health["max_error_m"] else "beyond_tolerance"
        if evidence == "insufficient":
            self.evidence, self.since, self.count = None, None, 0
            status = "insufficient"
        else:
            continuous = self.last is not None and timestamp - self.last < int(self.health["max_gap_us"])
            if self.evidence != evidence or not continuous:
                self.evidence, self.since, self.count = evidence, timestamp, 1
            else:
                self.count = min(self.count + 1, self.health["min_observations"])
            confirmed = self.count >= self.health["min_observations"] and timestamp - self.since >= int(self.health["confirmation_us"])
            status = ("healthy" if evidence == "within_tolerance" else "drift") if confirmed else "pending"
        self.last = timestamp
        return {"schema_version": "0.1.0", "kind": "calibration_health", "monitor_id": self.config["monitor_id"],
            "timestamp_us": str(timestamp), "landmarks": results, "usable_count": len(errors),
            "rms_error_m": rms, "max_error_m": maximum, "evidence": evidence, "status": status,
            "streak_since_us": None if self.since is None else str(self.since),
            "streak_observations": self.count, "scope": SCOPE}


def compare_report(actual, expected, errors):
    expected = copy.deepcopy(expected)
    for output, target in zip(actual["landmarks"], expected["landmarks"]):
        if target["rejection_reason"] in ("__projection__", "__numerical__"):
            prefix = "projection: " if target["rejection_reason"] == "__projection__" else "numerical: "
            if not isinstance(output["rejection_reason"], str) or not output["rejection_reason"].startswith(prefix) or len(output["rejection_reason"]) <= len(prefix):
                raise AssertionError("point rejection lost its reason category")
            target["rejection_reason"] = output["rejection_reason"]
    tree_close(actual, expected, errors)


def fixtures():
    config, ideals = configuration()
    good = observations(config, ideals)
    drift = observations(config, ideals, offset=(4, 0))
    partial = copy.deepcopy(good)
    partial[2]["point"] = [3000, 3000]
    partial[3]["point"] = [-3000, -3000]
    quality = copy.deepcopy(good)
    quality[0]["covariance"] = [100, 0, 100]
    records = [frame(0, good), frame(100000, good), frame(300000, good),
        frame(400000, drift), frame(500000, drift), frame(700000, drift), frame(800000),
        frame(900000, good[:3]), frame(1000000, partial), frame(1100000, good),
        frame(1200000, quality), frame(1400000, good), frame(1900000, good),
        frame(2000000, good), frame(2200000, good)]
    values = [("evidence_recovery_and_partial_rejection", config, records)]
    for index, camera in enumerate(camera_reference.CAMERAS):
        current, ideals = configuration("health-camera-{}".format(index), camera)
        frames = []
        for step in range(16):
            offset = (0.2 * math.sin(step), 0.2 * math.cos(step)) if step < 6 or step >= 12 else (12, -8)
            points = observations(current, ideals, offset, covariance=(4, 0.7, 6))
            if step == 5:
                points[0]["point"] = [4000, 3000]
            if step == 10:
                points = points[:2]
            frames.append(frame(step * 100000, points))
        values.append(("brown_camera_{}".format(index), current, frames))
    for name, start in [("exact_time_above_2pow53", 9007199254740993),
                        ("int64_maximum_time", 9223372036854775807 - 2200000)]:
        current = copy.deepcopy(config)
        current["monitor_id"] = name
        frames = [dict(copy.deepcopy(value), timestamp_us=str(start + int(value["timestamp_us"]))) for value in records]
        values.append((name, current, frames))
    for minimum, confirmation in [(1, "0"), (1, "300000"), (3, "0")]:
        current = copy.deepcopy(config)
        current["monitor_id"] = "minimum-{}-{}".format(minimum, confirmation)
        current["health"].update(min_observations=minimum, confirmation_us=confirmation)
        values.append((current["monitor_id"], current, records[:6]))
    boundary, ideals = configuration("health-exact-boundary")
    boundary["health"].update(rms_limit_m=0.125, max_error_m=0.125, min_observations=1, confirmation_us="0")
    values.append(("exact_metric_limits_included", boundary,
        [frame(0, observations(boundary, ideals, offset=(1, 0))),
         frame(1, observations(boundary, ideals, offset=(1.000001, 0)))]))
    independent = copy.deepcopy(boundary)
    independent["monitor_id"] = "health-independent-limits"
    independent["health"].update(rms_limit_m=0.2, max_error_m=0.125)
    only_one = observations(independent, ideals)
    only_one[0]["point"][0] += 2
    values.append(("max_limit_independent_from_rms", independent, [frame(0, only_one)]))
    zero = copy.deepcopy(boundary)
    zero["monitor_id"] = "health-zero-limits"
    zero["health"].update(rms_limit_m=0, max_error_m=0)
    values.append(("zero_metric_limits", zero, [frame(0, observations(zero, ideals))]))
    quality_boundary = copy.deepcopy(boundary)
    quality_boundary["monitor_id"] = "health-quality-boundary"
    quality_boundary["calibration"]["ground_noise_floor_m"] = 0.75
    quality_boundary["health"]["max_position_std_m"] = 1.0
    exact = observations(quality_boundary, ideals, covariance=(28, 0, 28))
    over = observations(quality_boundary, ideals, covariance=(28.000001, 0, 28.000001))
    values.append(("position_quality_equality", quality_boundary, [frame(0, exact), frame(1, over)]))
    huge, ideals = configuration("health-large-rms")
    huge["health"].update(rms_limit_m=1.1e200, max_error_m=1.1e200)
    for landmark in huge["landmarks"]:
        landmark["ground_m"] = [1e200, 0]
    values.append(("finite_errors_with_overflowing_squares", huge,
        [frame(step * 100000, observations(huge, ideals)) for step in range(4)]))
    numerical, ideals = configuration("health-numerical-point")
    numerical["health"].update(min_landmarks=1)
    numerical["landmarks"] = [{"landmark_id": "overflow", "ground_m": [-1.5e308, 0]}]
    numerical["calibration"].update(matrix=[1, 0, 0, 0, 1, 0, 0, 0, 1],
        roi=[[0, 0], [1.6e308, 0], [1.6e308, 1.6e308], [0, 1.6e308]], max_meters_per_pixel=2)
    numerical["health"].pop("max_position_std_m")
    values.append(("residual_overflow_is_local_rejection", numerical,
        [frame(0, [observation("overflow", [1.5e308, 1e307], [1, 0, 1])])]))
    long_run, ideals = configuration("health-clamped-long-run")
    values.append(("clamped_count_allows_long_confirmed_span", long_run,
        [frame(value, observations(long_run, ideals)) for value in [0, 499999, 999998, 1499997]]))
    default, ideals = configuration("health-default-pixel-noise")
    default["health"]["max_position_std_m"] = 1.0
    points = observations(default, ideals)
    for item in points:
        item.pop("covariance")
    values.append(("default_pixel_covariance_4I", default,
        [frame(value, points) for value in [0, 100000, 300000]]))
    return values


def reference_checks(binary):
    errors, records, statuses, reasons = {}, [], set(), set()
    frame_count = points = cuts = 0
    for name, config, frames in fixtures():
        oracle = Oracle(config)
        actual = native(binary, "--health", [config] + frames)
        if len(actual) != len(frames):
            raise AssertionError(name + ": a health frame was lost")
        for output, value in zip(actual, frames):
            compare_report(output, oracle.update(value), errors)
            statuses.add(output["status"])
            reasons.update(item["rejection_reason"].split(":")[0] for item in output["landmarks"] if item["rejection_reason"] is not None)
            points += len(output["landmarks"])
        saved = native(binary, "--health-checkpoint", [config] + frames, count=1)[0]
        expected_state = {"last_timestamp_us": str(oracle.last), "streak": None if oracle.evidence is None else
            {"evidence": oracle.evidence, "since_us": str(oracle.since), "observations": oracle.count}}
        if saved["state"] != expected_state:
            raise AssertionError(name + ": checkpoint evidence differs from independent state machine")
        for cut in range(len(frames) + 1):
            prefix = native(binary, "--health-checkpoint", [config] + frames[:cut], count=1)[0]
            if native(binary, "--health", [{"resume": prefix}] + frames[cut:]) != actual[cut:]:
                raise AssertionError("{} cut {} changed continuation".format(name, cut))
            if native(binary, "--health-checkpoint", [{"resume": prefix}] + frames[cut:], count=1)[0] != saved:
                raise AssertionError("{} cut {} changed final checkpoint".format(name, cut))
            cuts += 1
        records.append({"name": name, "frames": len(frames),
            "checkpoint_sha256": hashlib.sha256(encode(saved).encode()).hexdigest()})
        frame_count += len(frames)
    if statuses != {"insufficient", "pending", "healthy", "drift"}:
        raise AssertionError("health statuses not all exercised: " + str(statuses))
    if not {"missing", "projection", "position_uncertainty", "numerical"}.issubset(reasons):
        raise AssertionError("point rejection paths not all exercised: " + str(reasons))
    return {"cases": len(records), "frames": frame_count, "landmark_results": points,
        "resume_cut_points": cuts, "statuses": sorted(statuses), "rejection_categories": sorted(reasons),
        "maximum_absolute_oracle_errors": errors, "records": records}


def adaptation_checks(binary):
    errors, records = {}, []
    for name, config, frames in fixtures()[:3]:
        original = native(binary, "--health", [config] + frames)
        for sx, sy, tx, ty in [(0.5, 0.75, -40, 16), (2, 0.4, 231.25, -81.5)]:
            transform = np.array([[sx, 0, tx], [0, sy, ty], [0, 0, 1.0]])
            linear = transform[:2, :2]
            changed = copy.deepcopy(config)
            calibration = changed["calibration"]
            calibration["matrix"] = (np.asarray(calibration["matrix"]).reshape(3, 3) @ np.linalg.inv(transform)).ravel().tolist()
            calibration["roi"] = [(transform @ np.r_[value, 1])[:2].tolist() for value in calibration["roi"]]
            calibration["max_meters_per_pixel"] /= min(sx, sy)
            if changed.get("camera") is not None:
                camera = changed["camera"]
                camera.update(fx=sx * camera["fx"], fy=sy * camera["fy"], cx=sx * camera["cx"] + tx, cy=sy * camera["cy"] + ty)
            # Several fixture frames intentionally share immutable observations;
            # detach each frame before applying a pixel transform in place.
            mapped = [copy.deepcopy(value) for value in frames]
            for value in mapped:
                for item in value["observations"]:
                    item["point"] = (transform @ np.r_[item["point"], 1])[:2].tolist()
                    item["covariance"] = reference.compact_covariance(linear @ reference.covariance_matrix(item.get("covariance", [4, 0, 4])) @ linear.T)
            actual = native(binary, "--health", [changed] + mapped)
            tree_close(actual, original, errors)
            cut = len(frames) // 2
            saved = native(binary, "--health-checkpoint", [changed] + mapped[:cut], count=1)[0]
            tree_close(native(binary, "--health", [{"resume": saved}] + mapped[cut:]), original[cut:], errors)
            records.append({"name": name, "scale_x": sx, "scale_y": sy, "frames": len(frames), "resume_cut": cut})
    return {"cases": len(records), "records": records, "maximum_absolute_errors": errors,
        "scope": "independent_wire_coordinate_adaptation; typed_reframed_is_covered_by_core_tests"}


def rejection_checks(binary):
    config, ideals = configuration("health-strict")
    good = frame(100000, observations(config, ideals))
    later = frame(200000, observations(config, ideals))
    prefix = native(binary, "--health", [config, good])
    saved = native(binary, "--health-checkpoint", [config, good], count=1)[0]
    records = []

    def bad(name, values, expected=(), mode="--health", payload=None, extra=()):
        actual, evidence = run(binary, mode, values, status=2, payload=payload, extra=extra)
        if actual != list(expected):
            raise AssertionError(name + ": incomplete output or changed complete prefix")
        records.append(dict(name=name, **evidence))

    for name, mutate in [
        ("unknown_configuration", lambda v: v.update(extra=True)),
        ("empty_monitor_id", lambda v: v.update(monitor_id="")),
        ("empty_landmarks", lambda v: v.update(landmarks=[])),
        ("too_many_landmarks", lambda v: v.update(landmarks=[{"landmark_id": str(i), "ground_m": [0, 0]} for i in range(65)])),
        ("duplicate_landmark", lambda v: v["landmarks"].append(copy.deepcopy(v["landmarks"][0]))),
        ("unknown_landmark_field", lambda v: v["landmarks"][0].update(extra=True)),
        ("non_string_landmark_identity", lambda v: v["landmarks"][0].update(landmark_id=1)),
        ("min_landmarks_unavailable", lambda v: v["health"].update(min_landmarks=5)),
        ("negative_rms_limit", lambda v: v["health"].update(rms_limit_m=-1)),
        ("negative_max_limit", lambda v: v["health"].update(max_error_m=-1)),
        ("zero_min_observations", lambda v: v["health"].update(min_observations=0)),
        ("too_many_min_observations", lambda v: v["health"].update(min_observations=1000001)),
        ("negative_confirmation", lambda v: v["health"].update(confirmation_us="-1")),
        ("zero_gap", lambda v: v["health"].update(max_gap_us="0")),
        ("zero_quality_limit", lambda v: v["health"].update(max_position_std_m=0)),
    ]:
        invalid = copy.deepcopy(config)
        mutate(invalid)
        bad(name, [invalid])
    bad("raw_fractional_minimum", [encode(config).replace('"min_observations":3', '"min_observations":3.0000000000000001')])
    bad("duplicate_configuration_key", ['{"monitor_id":"dup",' + encode(config)[1:]])
    for name, mutate in [
        ("unknown_frame_field", lambda v: v.update(extra=True)),
        ("unknown_observation_field", lambda v: v["observations"][0].update(extra=True)),
        ("unknown_landmark_id", lambda v: v["observations"][0].update(landmark_id="unknown")),
        ("duplicate_observation", lambda v: v["observations"].append(copy.deepcopy(v["observations"][0]))),
        ("invalid_covariance", lambda v: v["observations"][0].update(covariance=[1, 2, 1])),
        ("same_timestamp", lambda v: v.update(timestamp_us="100000")),
        ("timestamp_number", lambda v: v.update(timestamp_us=200000)),
    ]:
        invalid = copy.deepcopy(later)
        mutate(invalid)
        bad(name, [config, good, invalid], prefix)
    bad("duplicate_frame_key", [config, good, '{"timestamp_us":"1",' + encode(later)[1:]], prefix)
    bad("blank_frame", [config, good, ""], prefix)
    bad("invalid_utf8", [], prefix, payload=lines([config, good]).encode() + b"\xff\n")
    bad("checkpoint_mode_late_failure", [config, good, dict(later, extra=True)], mode="--health-checkpoint")
    for name, mutate in [
        ("checkpoint_wrong_format", lambda v: v.update(format="other")),
        ("checkpoint_wrong_version", lambda v: v.update(checkpoint_version="2")),
        ("checkpoint_unknown_field", lambda v: v.update(extra=True)),
        ("streak_future", lambda v: v["state"]["streak"].update(since_us="100001")),
        ("streak_zero_count", lambda v: v["state"]["streak"].update(observations=0)),
        ("streak_count_over_clamp", lambda v: v["state"]["streak"].update(observations=4)),
        ("single_observation_stale_since", lambda v: v["state"]["streak"].update(since_us="99999")),
        ("streak_invalid_evidence", lambda v: v["state"]["streak"].update(evidence="insufficient")),
        ("unstarted_with_streak", lambda v: v["state"].update(last_timestamp_us=None)),
    ]:
        invalid = copy.deepcopy(saved)
        mutate(invalid)
        bad(name, [{"resume": invalid}])
    bad("resume_override", [{"resume": saved, "monitor_id": "override"}])
    for name, path in [
        ("checkpoint_missing_health", ["configuration", "health"]),
        ("checkpoint_missing_rms_limit", ["configuration", "health", "rms_limit_m"]),
        ("checkpoint_missing_min_observations", ["configuration", "health", "min_observations"]),
        ("checkpoint_missing_gap", ["configuration", "health", "max_gap_us"]),
        ("checkpoint_missing_noise_floor", ["configuration", "calibration", "ground_noise_floor_m"]),
        ("checkpoint_missing_maximum_scale", ["configuration", "calibration", "max_meters_per_pixel"]),
    ]:
        invalid = copy.deepcopy(saved)
        parent = invalid
        for key in path[:-1]:
            parent = parent[key]
        parent.pop(path[-1])
        bad(name, [{"resume": invalid}])
    brown, brown_ideals = configuration("health-strict-camera", camera_reference.CAMERAS[0])
    brown_saved = native(binary, "--health-checkpoint", [brown, frame(100000, observations(brown, brown_ideals))], count=1)[0]
    for key in ["k1", "k3", "max_normalized_radius"]:
        invalid = copy.deepcopy(brown_saved)
        invalid["configuration"]["camera"].pop(key)
        bad("checkpoint_missing_camera_" + key, [{"resume": invalid}])
    unreachable = copy.deepcopy(saved)
    unreachable["state"].update(last_timestamp_us="1000000")
    unreachable["state"]["streak"].update(since_us="0", observations=2)
    bad("unsaturated_count_unreachable_time_span", [{"resume": unreachable}])
    gap_one = copy.deepcopy(saved)
    gap_one["configuration"]["health"].update(max_gap_us="1", min_observations=1)
    gap_one["state"]["streak"].update(since_us="99999")
    bad("unit_gap_cannot_bridge_distinct_timestamps", [{"resume": gap_one}])
    raw = encode(saved).replace('"observations":1', '"observations":1.0000000000000001')
    bad("fractional_checkpoint_streak_count", ['{"resume":' + raw + '}'])
    integral = encode(config).replace('"min_observations":3', '"min_observations":30e-1')
    if native(binary, "--health", [integral, good]) != prefix:
        raise AssertionError("integral numeric form changed confirmation")
    return {"rejected_cases": len(records), "cases": records,
        "complete_prefix_preserved": True, "failed_checkpoint_has_no_output": True,
        "mathematical_integer_token": "passed"}


def transport_checks(binary):
    config, ideals = configuration("health-transport")
    first = frame(0, observations(config, ideals))
    second = frame(1, observations(config, ideals))
    baseline = native(binary, "--health", [config, first, second])
    for ending in (b"\n", b"\r\n"):
        actual = run(binary, "--health", payload=ending.join(encode(v).encode() for v in [config, first, second]))[0]
        if actual != baseline:
            raise AssertionError("line ending or unterminated EOF changed results")
    exact = max(len(encode(value).encode()) for value in [config, first, second])
    if native(binary, "--health", [config, first, second], extra=["--max-line-bytes", str(exact)]) != baseline:
        raise AssertionError("exact physical input bound failed")
    padded = encode(second) + " " * (exact + 10)
    actual, failure = run(binary, "--health", [config, first, padded], status=2,
        extra=["--max-line-bytes", str(len(padded) - 1)])
    if actual != baseline[:1]:
        raise AssertionError("physical input overflow lost complete prefix")
    saved = native(binary, "--health-checkpoint", [config], count=1)[0]
    resume = encode({"resume": saved}).ljust(8388619)
    if native(binary, "--health-checkpoint", [resume], count=1,
            extra=["--max-line-bytes", "16777216"])[0] != saved:
        raise AssertionError("exact resume source UTF-16 budget failed")
    _, source_over = run(binary, "--health-checkpoint", [resume + " "], status=2,
        count=0, extra=["--max-line-bytes", "16777216"])
    return {"crlf_and_unterminated_eof": "passed", "exact_physical_line_bytes": exact,
        "physical_one_byte_overflow": failure, "exact_source_utf16_units": 8388619,
        "source_one_unit_overflow": source_over}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/health.test.mjs"]
    completed = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=300)
    if completed.returncode:
        raise AssertionError("Node health verification failed:\n" + completed.stdout[-18000:] + completed.stderr[-2000:])
    summary, directions = {}, None
    for value in completed.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", value)
        if match:
            summary[match.group(1)] = int(match.group(2))
        if value.startswith('# {"cut_points":'):
            directions = json.loads(value[2:])
    if not summary.get("tests") or summary.get("pass") != summary["tests"] or summary.get("fail"):
        raise AssertionError("incomplete Node test summary")
    if directions is None or len(directions["directions"]) != 4:
        raise AssertionError("four runtime directions were not recorded")
    return {"status": "passed", "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "command": " ".join(command), "summary": summary, "cross_runtime": directions,
        "test_script_sha256": hashlib.sha256((ROOT / "web/health.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(), "stderr": completed.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/health-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "fixtures": "deterministic", "tolerance": TOLERANCE,
        "command": " ".join(shlex.quote(value) for value in [sys.executable] + sys.argv),
        "python": platform.python_version(), "numpy": np.__version__, "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "camera_reference_sha256": hashlib.sha256(Path(camera_reference.__file__).read_bytes()).hexdigest(),
        "projection_reference_sha256": hashlib.sha256(Path(reference.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["numerical_and_temporal_reference"] = reference_checks(binary)
    result["pixel_coordinate_adaptation"] = adaptation_checks(binary)
    result["strict_transport"] = rejection_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    result["status"] = "passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "output": str(args.output),
        "reference_cases": result["numerical_and_temporal_reference"]["cases"],
        "reference_frames": result["numerical_and_temporal_reference"]["frames"],
        "resume_cut_points": result["numerical_and_temporal_reference"]["resume_cut_points"],
        "strict_rejections": result["strict_transport"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
