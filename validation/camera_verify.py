#!/usr/bin/env python3
"""Independent Brown-Conrady and uncertainty-gate verification for v0.2.

The Brown forward model, Newton inverse and Jacobians below use NumPy only.
The established v0.1 NumPy Kalman reference is imported without modifying it.
All implementation comparisons execute the supplied native CLI.
"""

import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import time

import numpy as np

import verify as baseline


ROOT = Path(__file__).resolve().parents[1]
SEED = 20261112
TOLERANCE = 2.0e-8
HOMOGRAPHY = np.array([
    [0.018, 0.0015, -6.0],
    [-0.0008, 0.021, -3.0],
    [0.00008, -0.00005, 1.0],
])
ROI = [[200.0, 100.0], [1080.0, 100.0], [1080.0, 650.0], [200.0, 650.0]]
CAMERAS = [
    {"fx": 850.0, "fy": 610.0, "cx": 640.0, "cy": 360.0,
     "k1": 0.035, "k2": -0.006, "p1": 0.002, "p2": -0.0015,
     "k3": 0.001, "max_normalized_radius": 0.8},
    {"fx": 920.0, "fy": 680.0, "cx": 640.0, "cy": 360.0,
     "k1": -0.07, "k2": 0.012, "p1": -0.001, "p2": 0.002,
     "k3": -0.0008, "max_normalized_radius": 0.9},
]


def forward_normalized(point, camera):
    """Brown-Conrady x,y distortion and its analytic normalized Jacobian."""
    x, y = np.asarray(point, dtype=float)
    k1, k2, k3 = (camera.get(name, 0.0) for name in ("k1", "k2", "k3"))
    p1, p2 = camera.get("p1", 0.0), camera.get("p2", 0.0)
    radius2 = x * x + y * y
    radial = 1.0 + k1 * radius2 + k2 * radius2 ** 2 + k3 * radius2 ** 3
    radial_derivative = k1 + 2.0 * k2 * radius2 + 3.0 * k3 * radius2 ** 2
    distorted = np.array([
        x * radial + 2.0 * p1 * x * y + p2 * (radius2 + 2.0 * x * x),
        y * radial + p1 * (radius2 + 2.0 * y * y) + 2.0 * p2 * x * y,
    ])
    cross = 2.0 * x * y * radial_derivative + 2.0 * p1 * x + 2.0 * p2 * y
    jacobian = np.array([
        [radial + 2.0 * x * x * radial_derivative + 2.0 * p1 * y + 6.0 * p2 * x, cross],
        [cross, radial + 2.0 * y * y * radial_derivative + 6.0 * p1 * y + 2.0 * p2 * x],
    ])
    return distorted, jacobian


def uniqueness_bound(camera):
    radius = camera.get("max_normalized_radius", 1.0)
    return (3.0 * abs(camera.get("k1", 0.0)) * radius ** 2
            + 5.0 * abs(camera.get("k2", 0.0)) * radius ** 4
            + 7.0 * abs(camera.get("k3", 0.0)) * radius ** 6
            + 6.0 * radius * math.hypot(camera.get("p1", 0.0), camera.get("p2", 0.0)))


def distort_pixel(ideal_pixel, camera):
    focal = np.array([camera["fx"], camera["fy"]])
    center = np.array([camera["cx"], camera["cy"]])
    normalized = (np.asarray(ideal_pixel, dtype=float) - center) / focal
    distorted, _ = forward_normalized(normalized, camera)
    return distorted * focal + center


def rectify_reference(raw_pixel, camera):
    """Newton inversion, independent of the production contraction solver."""
    if not 0.0 <= uniqueness_bound(camera) < 1.0:
        raise ValueError("camera lacks the bounded injectivity certificate")
    focal = np.array([camera["fx"], camera["fy"]])
    center = np.array([camera["cx"], camera["cy"]])
    radius = camera.get("max_normalized_radius", 1.0)
    target = (np.asarray(raw_pixel, dtype=float) - center) / focal
    normalized = target.copy()
    for _ in range(40):
        distorted, jacobian = forward_normalized(normalized, camera)
        residual = distorted - target
        if np.linalg.norm(residual, ord=np.inf) / radius < 2.0e-15:
            break
        normalized -= np.linalg.solve(jacobian, residual)
    else:
        raise ValueError("independent Newton inverse did not converge")
    if np.linalg.norm(normalized) / radius > 1.0 + 1.0e-12:
        raise ValueError("ideal normalized point lies outside the configured radius")
    _, forward_jacobian = forward_normalized(normalized, camera)
    pixel_jacobian = np.diag(focal) @ np.linalg.inv(forward_jacobian) @ np.diag(1.0 / focal)
    return normalized * focal + center, pixel_jacobian


def project_reference(raw_pixel, raw_covariance, camera, matrix=HOMOGRAPHY, floor=0.001):
    ideal, rectify_jacobian = rectify_reference(raw_pixel, camera)
    position, _, homography_jacobian = baseline.project_reference(
        matrix, ideal, raw_covariance, noise_floor_m=0.0
    )
    combined = homography_jacobian @ rectify_jacobian
    covariance = combined @ baseline.covariance_matrix(raw_covariance) @ combined.T
    covariance += np.eye(2) * floor ** 2
    return position, covariance, combined, ideal


def calibration(matrix=HOMOGRAPHY, floor=0.001):
    return {"matrix": np.asarray(matrix).ravel().tolist(), "roi": ROI,
            "max_meters_per_pixel": 0.5, "ground_noise_floor_m": floor}


def run_cli(binary, arguments, records, expected_exit=0):
    payload = "\n".join(json.dumps(x, ensure_ascii=True) for x in records) + "\n"
    completed = subprocess.run([str(binary)] + arguments, input=payload, text=True,
                               encoding="utf-8", stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               cwd=str(ROOT), timeout=90)
    if completed.returncode != expected_exit:
        raise AssertionError("{} returned {} instead of {}: {}".format(
            arguments, completed.returncode, expected_exit, completed.stderr[:1600]))
    if expected_exit:
        if completed.stdout:
            raise AssertionError("invalid camera/configuration produced partial stdout")
        return {"exit_code": completed.returncode, "stderr": completed.stderr.strip()}
    if completed.stderr:
        raise AssertionError("successful native request emitted stderr: {}".format(completed.stderr))
    return [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]


def compare(actual, expected, label, errors, tolerance=TOLERANCE):
    actual = np.asarray(actual, dtype=float)
    expected = np.asarray(expected, dtype=float)
    if actual.shape != expected.shape or not np.isfinite(actual).all():
        raise AssertionError("{} has an invalid shape/value".format(label))
    difference = float(np.max(np.abs(actual - expected))) if actual.size else 0.0
    errors[label] = max(errors.get(label, 0.0), difference)
    if not np.allclose(actual, expected, rtol=tolerance, atol=tolerance):
        raise AssertionError("{} differs by {}".format(label, difference))


def dense_projection_checks(binary, rng):
    errors = {}
    reference_inverse_error = 0.0
    finite_difference_error = 0.0
    count = 0
    for camera in CAMERAS:
        ideals = np.array([[x, y] for x in np.linspace(230.0, 1050.0, 35)
                           for y in np.linspace(120.0, 630.0, 29)])
        ideals = np.vstack((ideals, rng.uniform([235.0, 125.0], [1045.0, 625.0], (160, 2))))
        requests = []
        for ideal in ideals:
            raw = distort_pixel(ideal, camera)
            variance = rng.uniform(0.2, 8.0, 2)
            covariance = [float(variance[0]), float(0.35 * np.sqrt(np.prod(variance))), float(variance[1])]
            requests.append({"point": raw.tolist(), "covariance": covariance})
        actual = []
        for first in range(0, len(requests), 1000):
            actual.extend(run_cli(binary, ["--project"], [{
                "camera": camera, "calibration": calibration(),
                "points": requests[first:first + 1000],
            }])[0]["points"])
        if len(actual) != len(requests):
            raise AssertionError("dense projection dropped points")
        for index, item in enumerate(requests):
            expected, covariance, jacobian, recovered = project_reference(item["point"], item["covariance"], camera)
            reference_inverse_error = max(reference_inverse_error, float(np.max(np.abs(recovered - ideals[index]))))
            compare(actual[index]["position_m"], expected, "raw_to_world_position", errors)
            compare(actual[index]["covariance"], baseline.compact_covariance(covariance), "raw_to_world_covariance", errors)
            compare(actual[index]["jacobian"], jacobian.ravel(), "raw_to_world_jacobian", errors)
            if index % 11 == 0:
                step = 1.0e-3
                numerical = np.empty((2, 2))
                for axis in (0, 1):
                    delta = np.zeros(2)
                    delta[axis] = step
                    plus = project_reference(np.asarray(item["point"]) + delta, item["covariance"], camera)[0]
                    minus = project_reference(np.asarray(item["point"]) - delta, item["covariance"], camera)[0]
                    numerical[:, axis] = (plus - minus) / (2 * step)
                finite_difference_error = max(finite_difference_error, float(np.max(np.abs(jacobian - numerical))))
            count += 1
    if reference_inverse_error > 2.0e-9 or finite_difference_error > 2.0e-8:
        raise AssertionError("independent inverse/Jacobian reference failed its analytic checks")
    # The floor is added after the entire raw->ideal->ground transform, once.
    item = {"point": distort_pixel([640.0, 360.0], CAMERAS[0]).tolist(),
            "covariance": [4.0, 0.5, 9.0]}
    floor_variances = []
    for floor in (0.001, 0.02):
        output = run_cli(binary, ["--project"], [{"camera": CAMERAS[0],
            "calibration": calibration(floor=floor), "points": [item]}])[0]["points"][0]
        floor_variances.append(baseline.covariance_matrix(output["covariance"]))
    compare(floor_variances[1] - floor_variances[0], np.eye(2) * (0.02 ** 2 - 0.001 ** 2),
            "single_ground_floor_increment", errors)
    return {"points": count, "cameras": CAMERAS,
            "injectivity_bounds": [uniqueness_bound(camera) for camera in CAMERAS],
            "maximum_absolute_errors": errors,
            "reference_inverse_pixel_maximum_error": reference_inverse_error,
            "composition_finite_difference_maximum_error": finite_difference_error,
            "ground_floor_applied_once": True}


def camera_default_and_radius_checks(binary):
    errors = {}
    points = [{"point": point, "covariance": [4.0, 0.5, 9.0]}
              for point in ([300.0, 200.0], [640.0, 360.0], [950.0, 550.0])]
    default_camera = {name: CAMERAS[0][name] for name in ("fx", "fy", "cx", "cy")}
    without = run_cli(binary, ["--project"], [{"calibration": calibration(), "points": points}])[0]["points"]
    with_zero = run_cli(binary, ["--project"], [{"camera": default_camera, "calibration": calibration(), "points": points}])[0]["points"]
    for left, right in zip(without, with_zero):
        for key in ("position_m", "covariance", "jacobian"):
            compare(left[key], right[key], "zero_camera_compatibility_" + key, errors)
    # A pincushion camera can have raw radius > R while its ideal point is
    # inside R. The inverse-domain limit must apply to the ideal point.
    camera = CAMERAS[0]
    normalized = np.array([camera["max_normalized_radius"] * (1.0 - 1.0e-8), 0.0])
    ideal = normalized * np.array([camera["fx"], camera["fy"]]) + [camera["cx"], camera["cy"]]
    raw = distort_pixel(ideal, camera)
    raw_radius = float(np.linalg.norm((raw - [camera["cx"], camera["cy"]]) / [camera["fx"], camera["fy"]]))
    if raw_radius <= camera["max_normalized_radius"]:
        raise AssertionError("the raw-outside/ideal-inside fixture is invalid")
    extended = calibration(np.diag([0.001, 0.001, 1.0]))
    extended["roi"] = [[0.0, 0.0], [2000.0, 0.0], [2000.0, 1000.0], [0.0, 1000.0]]
    actual = run_cli(binary, ["--project"], [{"camera": camera, "calibration": extended,
        "points": [{"point": raw.tolist(), "covariance": [4.0, 0.0, 4.0]}]}])[0]["points"][0]
    compare(actual["position_m"], ideal * 0.001, "ideal_radius_boundary_acceptance", errors)
    # A normalized radius far below an absolute 1e-12 tolerance must still
    # constrain its domain. Large focal lengths keep pixel values ordinary.
    tiny_camera = {"fx": 1.0e15, "fy": 8.0e14, "cx": 0.0, "cy": 0.0,
                   "max_normalized_radius": 1.0e-15}
    tiny_calibration = calibration(np.diag([0.001, 0.001, 1.0]))
    tiny_calibration["roi"] = [[-10.0, -10.0], [10.0, -10.0], [10.0, 10.0], [-10.0, 10.0]]
    tiny_points = [{"point": [value, 0.0], "covariance": [4.0, 0.0, 4.0]}
                   for value in (0.5, 1.0)]
    tiny_output = run_cli(binary, ["--project"], [{"camera": tiny_camera,
        "calibration": tiny_calibration, "points": tiny_points}])[0]["points"]
    for item, output in zip(tiny_points, tiny_output):
        compare(output["position_m"], np.asarray(item["point"]) * 0.001,
                "tiny_radius_inside_and_boundary", errors, 1.0e-12)
    tiny_rejections = []
    for multiple in (1.0 + 1.0e-8, 2.0):
        outside_point = [multiple, 0.0]
        try:
            rectify_reference(outside_point, tiny_camera)
        except ValueError:
            pass
        else:
            raise AssertionError("independent inverse accepted a tiny-radius outside point")
        tiny_rejections.append({"ideal_radius_multiple": multiple,
            **run_cli(binary, ["--project"], [{"camera": tiny_camera,
                "calibration": tiny_calibration, "points": [{"point": outside_point,
                    "covariance": [4.0, 0.0, 4.0]}]}], expected_exit=2)})
    return {"zero_coefficient_defaults_match_v01_projection": True,
            "default_max_normalized_radius": 1.0,
            "inside_ideal_radius": float(np.linalg.norm(normalized)),
            "corresponding_raw_radius": raw_radius,
            "configured_radius": camera["max_normalized_radius"],
            "raw_outside_ideal_inside_accepted": True,
            "tiny_radius": {"configured_radius": tiny_camera["max_normalized_radius"],
                "inside_and_boundary_accepted": True, "outside_rejections": tiny_rejections,
                "domain_tolerance_scales_with_radius": True},
            "maximum_absolute_errors": errors}


def fit_checks(binary, rng):
    camera = CAMERAS[0]
    control = np.array([[300.0, 160.0], [960.0, 180.0], [1000.0, 620.0], [280.0, 590.0],
                        [640.0, 150.0], [640.0, 620.0], [350.0, 370.0], [980.0, 380.0]])
    held_out = rng.uniform([320.0, 190.0], [950.0, 570.0], (28, 2))
    def world(points):
        return [baseline.project_reference(HOMOGRAPHY, point, [1.0, 0.0, 1.0], 0.0)[0].tolist()
                for point in points]
    request = {"camera": camera, "control_pixels": [distort_pixel(p, camera).tolist() for p in control],
               "control_world": world(control),
               "check_pixels": [distort_pixel(p, camera).tolist() for p in held_out],
               "check_world": world(held_out), "roi": ROI,
               "max_fit_error_m": 1.0e-6, "max_check_error_m": 1.0e-6,
               "max_meters_per_pixel": 0.5, "ground_noise_floor_m": 0.001}
    output = run_cli(binary, ["--calibrate"], [request])[0]
    if "camera" not in output:
        raise AssertionError("fitted calibration dropped its raw-camera definition")
    for key, value in camera.items():
        if output["camera"].get(key) != value:
            raise AssertionError("fit changed camera parameter {}".format(key))
    errors = {}
    fitted = np.asarray(output["calibration"]["matrix"]).reshape(3, 3)
    compare(fitted / fitted[2, 2], HOMOGRAPHY / HOMOGRAPHY[2, 2], "fitted_rectified_homography", errors, 2.0e-7)
    projected = run_cli(binary, ["--project"], [{"camera": output["camera"],
        "calibration": output["calibration"],
        "points": [{"point": raw, "covariance": [4.0, 0.0, 4.0]} for raw in request["check_pixels"]]}])[0]["points"]
    for actual, expected in zip(projected, request["check_world"]):
        compare(actual["position_m"], expected, "held_out_world_position", errors, 2.0e-7)
    mismatched = copy.deepcopy(request)
    mismatched["check_world"][0][0] += 0.5
    rejection = run_cli(binary, ["--calibrate"], [mismatched], expected_exit=2)
    return {"control_points": len(control), "held_out_points": len(held_out),
            "maximum_absolute_errors": errors, "report": output["report"],
            "camera_roundtrip_preserved": True, "incorrect_held_out_rejected": rejection,
            "truth": "independent synthetic correspondences from a known rectified homography and forward Brown camera"}


def scalar_standard_deviation(covariance):
    return math.sqrt(max(0.0, float(np.linalg.eigvalsh(covariance)[-1])))


def motion_configuration(camera=None, thresholds=None):
    result = {"session_id": "camera-reference", "mode": "pixel" if camera is not None else "ground",
              "diagnostics": True, "motion": {"q": 0.15, "gate": 9.21034,
              "max_gap_us": "500000", "min_observations": 3, "min_span_us": "300000",
              "initial_velocity_std": 5.0}}
    if camera is not None:
        result.update({"camera": camera, "calibration": calibration()})
    if thresholds:
        result["motion"].update(thresholds)
    return result


def check_estimate(actual, reference, accepted, ready, errors, prefix):
    if actual["accepted_count"] != reference.accepted_count:
        raise AssertionError("uncertainty decision changed accepted observations")
    if int(actual["last_accepted_timestamp_us"]) != reference.timestamp_us:
        raise AssertionError("uncertainty decision changed last accepted time")
    if not accepted:
        if actual["position_std_m"] is not None or actual["velocity_std_mps"] is not None:
            raise AssertionError("rejected observation leaked stale standard deviations")
        return
    compare(actual["filter_state"], reference.state, prefix + "_state", errors)
    compare(actual["filter_covariance"], reference.covariance.ravel(), prefix + "_covariance", errors)
    compare(actual["position_std_m"], scalar_standard_deviation(reference.covariance[:2, :2]),
            prefix + "_position_std", errors)
    if ready:
        compare(actual["velocity_std_mps"], scalar_standard_deviation(reference.covariance[2:, 2:]),
                prefix + "_velocity_std", errors)
    elif actual["velocity_std_mps"] is not None:
        raise AssertionError("initialization published velocity uncertainty as a ready measurement")


def raw_stream_checks(binary, rng):
    camera = CAMERAS[1]
    frames = []
    expected_observations = []
    timestamps = np.r_[0, np.cumsum(rng.choice([60000, 100000, 140000, 180000], 79))]
    raw_covariance = np.array([[4.0, 0.9], [0.9, 6.25]])
    for index, timestamp in enumerate(timestamps):
        seconds = timestamp / 1e6
        ideal = np.array([550.0 + 9.0 * seconds, 320.0 + 3.0 * seconds])
        raw = distort_pixel(ideal, camera) + rng.multivariate_normal([0.0, 0.0], raw_covariance)
        if index == 32:
            raw += [110.0, -80.0]
        cov = baseline.compact_covariance(raw_covariance)
        position, propagated, _, _ = project_reference(raw, cov, camera)
        frames.append({"timestamp_us": str(int(timestamp)), "observations": [{
            "track_id": 1, "point": raw.tolist(), "covariance": cov}]})
        expected_observations.append((position, baseline.compact_covariance(propagated)))
    outputs = run_cli(binary, ["--stream"], [motion_configuration(camera)] + frames)
    if len(outputs) != len(frames):
        raise AssertionError("raw-camera stream lost complete frames")
    errors = {}
    reference = None
    rejected = []
    for index, (frame, expected, output) in enumerate(zip(frames, expected_observations, outputs)):
        point, covariance = expected
        if reference is None or int(frame["timestamp_us"]) - reference.timestamp_us > 500000:
            reference = baseline.KalmanReference(point, covariance, frame["timestamp_us"], q=0.15)
            accepted = True
        else:
            accepted, _ = reference.update(point, covariance, frame["timestamp_us"])
        ready = reference.accepted_count >= 3 and reference.timestamp_us - reference.first_timestamp_us >= 300000
        actual = output["tracks"][0]
        expected_status = "rejected_innovation" if not accepted else ("ready" if ready else "initializing")
        if actual["status"] != expected_status:
            raise AssertionError("raw camera stream status differs at frame {}".format(index))
        if not accepted:
            rejected.append(index)
        check_estimate(actual, reference, accepted, ready, errors, "raw_stream")
    if 32 not in rejected:
        raise AssertionError("the deliberate raw-camera outlier was accepted")
    return {"frames": len(frames), "rejected_indices": rejected,
            "maximum_absolute_errors": errors,
            "old_kalman_reference_unchanged": True}


def uncertainty_gate_checks(binary, rng):
    frames = []
    for index in range(64):
        covariance = np.array([[4.0, 0.5], [0.5, 2.25]]) if 16 <= index < 32 else np.array([[0.0004, 0.00008], [0.00008, 0.0009]])
        seconds = index * 0.1
        point = np.array([1.0 + 0.35 * seconds, 2.0 - 0.1 * seconds]) + rng.multivariate_normal([0, 0], covariance)
        frames.append({"timestamp_us": str(index * 100000), "observations": [{
            "track_id": 1, "point": point.tolist(),
            "covariance": baseline.compact_covariance(covariance)}]})
    thresholds = {"max_position_std_m": 0.07, "max_velocity_std_mps": 0.35}
    baseline_outputs = run_cli(binary, ["--stream"], [motion_configuration()] + frames)
    gated_outputs = run_cli(binary, ["--stream"], [motion_configuration(thresholds=thresholds)] + frames)
    reference = None
    statuses = []
    errors = {}
    for index, (frame, before, after) in enumerate(zip(frames, baseline_outputs, gated_outputs)):
        item = frame["observations"][0]
        if reference is None or int(frame["timestamp_us"]) - reference.timestamp_us > 500000:
            reference = baseline.KalmanReference(item["point"], item["covariance"], frame["timestamp_us"], q=0.15)
            accepted = True
        else:
            accepted, _ = reference.update(item["point"], item["covariance"], frame["timestamp_us"])
        ready = reference.accepted_count >= 3 and reference.timestamp_us - reference.first_timestamp_us >= 300000
        ordinary, gated = before["tracks"][0], after["tracks"][0]
        for key in ("filter_state", "filter_covariance", "accepted_count", "last_accepted_timestamp_us",
                    "position_m", "position_covariance", "velocity_mps", "velocity_covariance",
                    "observed_path_length_m", "net_displacement_m"):
            if ordinary[key] != gated[key]:
                raise AssertionError("readiness thresholds changed {} at frame {}".format(key, index))
        check_estimate(gated, reference, accepted, ready, errors, "threshold")
        if not accepted:
            expected_status = "rejected_innovation"
        elif not ready:
            expected_status = "initializing"
        else:
            position_std = scalar_standard_deviation(reference.covariance[:2, :2])
            velocity_std = scalar_standard_deviation(reference.covariance[2:, 2:])
            expected_status = "uncertain" if position_std > thresholds["max_position_std_m"] or velocity_std > thresholds["max_velocity_std_mps"] else "ready"
        if gated["status"] != expected_status:
            raise AssertionError("uncertainty gate status differs at frame {}".format(index))
        if expected_status == "uncertain":
            if gated["speed_mps"] is not None or gated["velocity_mps"] is None:
                raise AssertionError("uncertain estimates must retain the velocity vector and suppress scalar speed")
        if expected_status == "ready":
            compare(gated["speed_mps"], np.linalg.norm(reference.state[2:]), "threshold_speed", errors)
        statuses.append(expected_status)
    first_ready = next(i for i, status in enumerate(statuses) if status == "ready")
    first_uncertain = next(i for i, status in enumerate(statuses) if status == "uncertain" and i > first_ready)
    recovered = next(i for i, status in enumerate(statuses) if status == "ready" and i > first_uncertain)
    stationary_frames = [{"timestamp_us": str(index * 100000), "observations": [{
        "track_id": 1, "point": [2.0, 3.0], "covariance": [0.01, 0.0, 0.01]}]} for index in range(8)]
    stationary = run_cli(binary, ["--stream"], [motion_configuration(thresholds={"max_velocity_std_mps": 0.001})] + stationary_frames)[-1]["tracks"][0]
    if stationary["status"] != "uncertain" or stationary["speed_mps"] is not None:
        raise AssertionError("a near-zero velocity mean bypassed the covariance gate")
    if np.linalg.norm(stationary["velocity_mps"]) > 1e-12 or stationary["velocity_std_mps"] <= 0.001:
        raise AssertionError("near-zero mean/covariance fixture is invalid")
    return {"frames": len(frames), "thresholds": thresholds,
            "first_ready_frame": first_ready, "first_uncertain_frame": first_uncertain,
            "recovered_ready_frame": recovered,
            "status_counts": {status: statuses.count(status) for status in sorted(set(statuses))},
            "thresholds_leave_filter_and_lifecycle_unchanged": True,
            "maximum_absolute_errors": errors,
            "near_zero_velocity": {"velocity_mps": stationary["velocity_mps"],
                "velocity_std_mps": stationary["velocity_std_mps"], "speed_mps": None,
                "interpretation": "Maximum vector-covariance principal standard deviation; not a scalar-speed confidence interval."}}


def rejection_checks(binary):
    failures = []
    for name, changes in (("nonpositive_focal", {"fx": 0.0}),
                          ("noninjective_radius", {"k1": -1.0, "max_normalized_radius": 1.0}),
                          ("nonpositive_radius", {"max_normalized_radius": 0.0})):
        camera = dict(CAMERAS[0], **changes)
        request = {"camera": camera, "calibration": calibration(),
                   "points": [{"point": [640.0, 360.0], "covariance": [4.0, 0.0, 4.0]}]}
        failures.append({"name": name, **run_cli(binary, ["--project"], [request], expected_exit=2)})
    camera = CAMERAS[1]
    ideal_outside = np.array([camera["cx"] + camera["fx"] * 1.02 * camera["max_normalized_radius"], camera["cy"]])
    extended = calibration(np.diag([0.001, 0.001, 1.0]))
    extended["roi"] = [[0.0, 0.0], [2000.0, 0.0], [2000.0, 1000.0], [0.0, 1000.0]]
    request = {"camera": camera, "calibration": extended,
               "points": [{"point": distort_pixel(ideal_outside, camera).tolist(), "covariance": [4.0, 0.0, 4.0]}]}
    failures.append({"name": "inverse_outside_unique_domain",
                     **run_cli(binary, ["--project"], [request], expected_exit=2)})
    for field, value in (("max_position_std_m", 0.0), ("max_velocity_std_mps", -1.0)):
        config = motion_configuration(thresholds={field: value})
        failures.append({"name": field + "_not_positive",
                         **run_cli(binary, ["--stream"], [config], expected_exit=2)})
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "validation" / "camera-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    rng = np.random.default_rng(SEED)
    result = {"format_version": "1", "seed": SEED, "tolerance": TOLERANCE,
              "command": " ".join(shlex.quote(value) for value in [sys.executable] + sys.argv),
              "python": platform.python_version(), "numpy": np.__version__,
              "toolchain": baseline.toolchain_version(),
              "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "v01_reference_sha256": hashlib.sha256(Path(baseline.__file__).read_bytes()).hexdigest(),
              "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["camera_projection"] = dense_projection_checks(binary, rng)
    result["camera_defaults_and_radius"] = camera_default_and_radius_checks(binary)
    result["raw_control_calibration"] = fit_checks(binary, rng)
    result["camera_motion"] = raw_stream_checks(binary, rng)
    result["uncertainty_thresholds"] = uncertainty_gate_checks(binary, rng)
    result["rejections"] = rejection_checks(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    result["status"] = "passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(json.dumps({"status": result["status"], "output": str(args.output),
                      "dense_points": result["camera_projection"]["points"],
                      "motion_frames": result["camera_motion"]["frames"],
                      "uncertainty_frames": result["uncertainty_thresholds"]["frames"]}, ensure_ascii=True))


if __name__ == "__main__":
    main()
