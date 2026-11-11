#!/usr/bin/env python3
"""Independent NumPy reference, native differential checks and ETH replay.

Run from the project root with Python 3.8+ and NumPy. Downloaded ETH research
data stays in ignored validation/data/. The ETH inverse-homography replay is
explicitly a controlled-noise round trip, not independent speed ground truth.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import io
import json
import math
from pathlib import Path
import platform
import shlex
import struct
import subprocess
import sys
import tarfile
import time
import urllib.request
import urllib.error

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
SEED = 20261111
TOLERANCE = 1.0e-8
ETH_URL = "https://data.vision.ee.ethz.ch/cvl/aem/ewap_dataset_full.tgz"
ETH_BYTES = 79753734
ETH_ARCHIVE_SHA256 = "403f0afc64f2635a28dd7960ede97fde947c38335f3c0fb131a260b4d2ffd203"
ETH_OBSMAT_SHA256 = "2b8577595204a6b780b80258fd50da35adb7293e3e06ad6f8e1b60965e7dde6e"
OBSERVATION = np.array([[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0]])


def covariance_matrix(value):
    """Expand the public symmetric [xx, xy, yy] representation."""
    xx, xy, yy = value
    return np.array([[xx, xy], [xy, yy]], dtype=float)


def compact_covariance(value):
    return [float(value[0, 0]), float(value[0, 1]), float(value[1, 1])]


def project_reference(matrix, point, covariance, noise_floor_m=0.001):
    """Homogeneous projection, its analytic derivative, and J R J^T.

    This implementation uses NumPy matrix products and linear algebra. It does
    not call MoonBit, moon-cv-geometry, or moon-kalman.
    """
    matrix = np.asarray(matrix, dtype=float).reshape(3, 3)
    point = np.asarray(point, dtype=float)
    homogeneous = matrix @ np.r_[point, 1.0]
    denominator = homogeneous[2]
    if not np.isfinite(homogeneous).all() or denominator == 0.0:
        raise ValueError("projection is undefined")
    position = homogeneous[:2] / denominator
    jacobian = (
        matrix[:2, :2] - np.outer(position, matrix[2, :2])
    ) / denominator
    propagated = jacobian @ covariance_matrix(covariance) @ jacobian.T
    propagated += np.eye(2) * noise_floor_m ** 2
    return position, propagated, jacobian


def constant_velocity_matrices(dt, spectral_density):
    """Continuous white acceleration, state order x,y,vx,vy.

    q has units m^2/s^3. Integrating white acceleration over dt gives position
    variance q*dt^3/3, position/velocity covariance q*dt^2/2, and velocity
    variance q*dt. This is not the discrete random-constant-acceleration model.
    """
    transition = np.eye(4)
    transition[0, 2] = transition[1, 3] = dt
    noise = np.zeros((4, 4))
    for axis in (0, 1):
        noise[axis, axis] = dt ** 3 / 3.0
        noise[axis, axis + 2] = noise[axis + 2, axis] = dt ** 2 / 2.0
        noise[axis + 2, axis + 2] = dt
    return transition, spectral_density * noise


class KalmanReference:
    """One segment; rejected observations do not commit predictions."""

    def __init__(self, point, covariance, timestamp_us, q=1.0,
                 initial_velocity_std=5.0, gate=9.21034):
        self.state = np.r_[np.asarray(point, dtype=float), 0.0, 0.0]
        self.covariance = np.zeros((4, 4))
        self.covariance[:2, :2] = covariance_matrix(covariance)
        self.covariance[2:, 2:] = np.eye(2) * initial_velocity_std ** 2
        self.timestamp_us = int(timestamp_us)
        self.first_timestamp_us = int(timestamp_us)
        self.accepted_count = 1
        self.path_length = 0.0
        self.first_position = self.state[:2].copy()
        self.last_observed = self.state[:2].copy()
        self.q = q
        self.gate = gate

    def update(self, point, covariance, timestamp_us):
        timestamp_us = int(timestamp_us)
        dt = (timestamp_us - self.timestamp_us) / 1_000_000.0
        if dt <= 0.0:
            raise ValueError("timestamps must increase")
        transition, process_noise = constant_velocity_matrices(dt, self.q)
        predicted_state = transition @ self.state
        predicted_covariance = transition @ self.covariance @ transition.T + process_noise
        measurement_noise = covariance_matrix(covariance)
        innovation = np.asarray(point) - OBSERVATION @ predicted_state
        innovation_covariance = OBSERVATION @ predicted_covariance @ OBSERVATION.T + measurement_noise
        normalized_innovation = float(innovation @ np.linalg.solve(innovation_covariance, innovation))
        if normalized_innovation > self.gate:
            return False, normalized_innovation
        gain = np.linalg.solve(
            innovation_covariance, OBSERVATION @ predicted_covariance
        ).T
        corrected_state = predicted_state + gain @ innovation
        complement = np.eye(4) - gain @ OBSERVATION
        corrected_covariance = (
            complement @ predicted_covariance @ complement.T
            + gain @ measurement_noise @ gain.T
        )
        corrected_covariance = (corrected_covariance + corrected_covariance.T) / 2.0
        self.path_length += float(np.linalg.norm(corrected_state[:2] - self.last_observed))
        self.last_observed = corrected_state[:2].copy()
        self.state = corrected_state
        self.covariance = corrected_covariance
        self.timestamp_us = timestamp_us
        self.accepted_count += 1
        return True, normalized_innovation


def run_json(binary, arguments, records):
    payload = "\n".join(json.dumps(record, ensure_ascii=True) for record in records) + "\n"
    result = subprocess.run(
        [str(binary)] + arguments, input=payload, text=True,
        encoding="utf-8", stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=str(ROOT), timeout=120,
    )
    if result.returncode != 0:
        raise AssertionError("CLI failed ({}): {}".format(result.returncode, result.stderr[:2000]))
    return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]


def compare(actual, expected, label, maximum, tolerance=TOLERANCE):
    actual = np.asarray(actual, dtype=float)
    expected = np.asarray(expected, dtype=float)
    if actual.shape != expected.shape or not np.isfinite(actual).all():
        raise AssertionError("{}: incorrect shape or non-finite result".format(label))
    error = float(np.max(np.abs(actual - expected))) if actual.size else 0.0
    maximum[label] = max(maximum.get(label, 0.0), error)
    if not np.allclose(actual, expected, rtol=tolerance, atol=tolerance):
        raise AssertionError("{}: maximum absolute error {}".format(label, error))


def projection_cases(rng):
    cases = []
    for index in range(48):
        matrix = np.array([
            [0.018 + rng.uniform(0.0, 0.007), rng.uniform(-0.002, 0.002), -3.0],
            [rng.uniform(-0.002, 0.002), 0.019 + rng.uniform(0.0, 0.006), -2.0],
            [rng.uniform(-0.00015, 0.00015), rng.uniform(-0.00015, 0.00015), 1.0],
        ])
        factor = (-1.0 if index % 3 == 0 else 1.0) * 10.0 ** ((index % 9) - 4)
        matrix *= factor
        points = []
        for _ in range(8):
            variances = rng.uniform(0.2, 9.0, 2)
            correlation = rng.uniform(-0.8, 0.8)
            points.append({
                "point": rng.uniform([1.0, 1.0], [639.0, 479.0]).tolist(),
                "covariance": [float(variances[0]), float(correlation * np.sqrt(variances.prod())), float(variances[1])],
            })
        cases.append({"calibration": {
            "matrix": matrix.ravel().tolist(),
            "roi": [[0, 0], [640, 0], [640, 480], [0, 480]],
            "max_meters_per_pixel": 0.5,
            "ground_noise_floor_m": 0.001,
        }, "points": points})
    return cases


def verify_projection(binary, rng):
    maximum = {}
    total = 0
    derivative_error = 0.0
    for case in projection_cases(rng):
        actual = run_json(binary, ["--project"], [case])[0]["points"] if binary else None
        for index, item in enumerate(case["points"]):
            position, covariance, jacobian = project_reference(
                case["calibration"]["matrix"], item["point"], item["covariance"]
            )
            # An independent numerical derivative also checks our analytic oracle.
            epsilon = 1.0e-3
            numerical = np.zeros((2, 2))
            for axis in (0, 1):
                delta = np.zeros(2)
                delta[axis] = epsilon
                plus = project_reference(case["calibration"]["matrix"], np.asarray(item["point"]) + delta, item["covariance"])[0]
                minus = project_reference(case["calibration"]["matrix"], np.asarray(item["point"]) - delta, item["covariance"])[0]
                numerical[:, axis] = (plus - minus) / (2 * epsilon)
            derivative_error = max(derivative_error, float(np.max(np.abs(jacobian - numerical))))
            if actual:
                compare(actual[index]["position_m"], position, "projection_position", maximum)
                compare(actual[index]["covariance"], compact_covariance(covariance), "projection_covariance", maximum)
                compare(actual[index]["jacobian"], jacobian.ravel(), "projection_jacobian", maximum)
            total += 1
    if derivative_error > 1.0e-8:
        raise AssertionError("analytic reference Jacobian failed finite differences")
    return {"cases": total, "maximum_absolute_errors": maximum,
            "reference_finite_difference_maximum_error": derivative_error,
            "implementation_compared": bool(binary)}


def verify_monte_carlo(binary):
    """Check the local covariance approximation with real CLI projections."""
    if binary is None:
        return {"status": "skipped", "reason": "requires the actual native CLI"}
    rng = np.random.default_rng(SEED)
    samples = 10000
    center = np.array([320.0, 240.0])
    pixel_covariance = np.array([[4.0, 1.0], [1.0, 9.0]])
    noise_floor = 0.001
    calibration = {
        "matrix": [0.025, 0.003, -4.0, -0.001, 0.018, -2.0, 0.00015, -0.0001, 1.0],
        "roi": [[0.0, 0.0], [640.0, 0.0], [640.0, 480.0], [0.0, 480.0]],
        "max_meters_per_pixel": 0.5,
        "ground_noise_floor_m": noise_floor,
    }
    pixels = rng.multivariate_normal(center, pixel_covariance, samples)
    projected = []
    for first in range(0, samples, 1000):
        request = {"calibration": calibration, "points": [
            {"point": point.tolist(), "covariance": compact_covariance(pixel_covariance)}
            for point in pixels[first:first + 1000]
        ]}
        actual = run_json(binary, ["--project"], [request])[0]["points"]
        if len(actual) != len(request["points"]):
            raise AssertionError("Monte Carlo CLI dropped projected samples")
        projected.extend(item["position_m"] for item in actual)
    observed = np.asarray(projected) + rng.normal(0.0, noise_floor, (samples, 2))
    empirical = np.cov(observed, rowvar=False, ddof=1)
    expected_mean, analytic, _ = project_reference(
        calibration["matrix"], center, compact_covariance(pixel_covariance), noise_floor
    )
    relative_error = float(np.linalg.norm(empirical - analytic, ord="fro") / np.linalg.norm(analytic, ord="fro"))
    maximum_entry_error = float(np.max(np.abs(empirical - analytic)))
    if not np.isfinite(observed).all() or relative_error >= 0.05:
        raise AssertionError("actual CLI Monte Carlo covariance differs by {}".format(relative_error))
    return {"status": "passed", "samples": samples, "cli_batches": 10,
            "seed": SEED, "center_pixel": center.tolist(),
            "calibration": calibration,
            "pixel_covariance": pixel_covariance.tolist(),
            "independent_ground_noise_std_m": noise_floor,
            "analytic_covariance_m2": analytic.tolist(),
            "empirical_covariance_m2": empirical.tolist(),
            "relative_frobenius_error": relative_error,
            "relative_frobenius_tolerance": 0.05,
            "maximum_absolute_covariance_entry_error_m2": maximum_entry_error,
            "mean_bias_norm_m": float(np.linalg.norm(np.mean(observed, axis=0) - expected_mean)),
            "implementation_compared": True,
            "conditions": "Gaussian pixel noise near an interior point under a moderate projective map; independent Gaussian ground floor added after actual CLI projections. This tests the local linear covariance approximation under the specified conditions."}


def synthetic_cases(rng):
    """Physical truth and noisy measurements; no MoonBit-generated inputs."""
    cases = []
    for name, velocity, acceleration in (
        ("stationary", [0.0, 0.0], [0.0, 0.0]),
        ("constant_velocity", [1.3, -0.4], [0.0, 0.0]),
        ("accelerating", [0.2, 0.4], [0.18, -0.07]),
        ("outlier_then_recovery", [0.8, 0.2], [0.0, 0.0]),
    ):
        timestamps = np.r_[0, np.cumsum(rng.choice([40000, 80000, 120000, 180000, 240000], 63))]
        covariance = np.array([[0.0025, 0.0007], [0.0007, 0.0064]])
        frames = []
        truth = []
        for index, timestamp_us in enumerate(timestamps):
            seconds = float(timestamp_us) / 1e6
            position = np.array([2.0, -1.0]) + np.asarray(velocity) * seconds + np.asarray(acceleration) * seconds ** 2 / 2.0
            measured = position + rng.multivariate_normal([0.0, 0.0], covariance)
            if name == "outlier_then_recovery" and index == 24:
                measured += [25.0, -20.0]
            frames.append({"timestamp_us": str(int(timestamp_us)), "observations": [{
                "track_id": 1, "point": measured.tolist(), "covariance": compact_covariance(covariance),
            }], "lost": [], "removed": []})
            truth.append({"position": position, "velocity": np.asarray(velocity) + np.asarray(acceleration) * seconds})
        cases.append((name, frames, truth))
    return cases


def stream_config(session_id="numpy-reference", mode="ground", calibration=None):
    result = {"session_id": session_id, "mode": mode, "diagnostics": True,
              "motion": {"max_gap_us": "500000", "min_observations": 3,
                         "min_span_us": "300000", "q": 1.0,
                         "initial_velocity_std": 5.0, "gate": 9.21034,
                         "max_tracks": 1000}}
    if calibration is not None:
        result["calibration"] = calibration
    return result


def verify_motion(binary, rng):
    maximum = {}
    reports = []
    for name, frames, truth in synthetic_cases(rng):
        outputs = run_json(binary, ["--stream"], [stream_config()] + frames) if binary else None
        if outputs is not None and len(outputs) != len(frames):
            raise AssertionError("stream returned the wrong number of frames")
        reference = None
        rejected = []
        velocity_errors = []
        raw_errors = []
        filtered_errors = []
        for index, frame in enumerate(frames):
            item = frame["observations"][0]
            if reference is None:
                reference = KalmanReference(item["point"], item["covariance"], frame["timestamp_us"])
                accepted = True
            else:
                accepted, _ = reference.update(item["point"], item["covariance"], frame["timestamp_us"])
            if not accepted:
                rejected.append(index)
            if accepted:
                raw_errors.append(float(np.linalg.norm(np.asarray(item["point"]) - truth[index]["position"]) ** 2))
                filtered_errors.append(float(np.linalg.norm(reference.state[:2] - truth[index]["position"]) ** 2))
                if reference.accepted_count >= 3 and reference.timestamp_us - reference.first_timestamp_us >= 300000:
                    velocity_errors.append(float(np.linalg.norm(reference.state[2:] - truth[index]["velocity"]) ** 2))
            if outputs is not None:
                actual = outputs[index]["tracks"][0]
                expected_status = "rejected_innovation" if not accepted else (
                    "ready" if reference.accepted_count >= 3 and reference.timestamp_us - reference.first_timestamp_us >= 300000 else "initializing"
                )
                if actual["status"] != expected_status:
                    raise AssertionError("{} frame {}: status {} != {}".format(name, index, actual["status"], expected_status))
                if accepted or actual["filter_state"] is not None:
                    compare(actual["filter_state"], reference.state, "filter_state", maximum)
                    compare(actual["filter_covariance"], reference.covariance.ravel(), "filter_covariance", maximum)
                if actual["accepted_count"] != reference.accepted_count:
                    raise AssertionError("accepted count differs")
                if int(actual["last_accepted_timestamp_us"]) != reference.timestamp_us:
                    raise AssertionError("rejected observation changed timestamp")
                compare(actual["observed_path_length_m"], reference.path_length, "observed_path_length", maximum)
                compare(actual["net_displacement_m"], np.linalg.norm(reference.last_observed - reference.first_position), "net_displacement", maximum)
                if expected_status == "ready":
                    compare(actual["velocity_mps"], reference.state[2:], "velocity", maximum)
                    compare(actual["speed_mps"], np.linalg.norm(reference.state[2:]), "speed", maximum)
                elif accepted and (actual["velocity_mps"] is not None or actual["speed_mps"] is not None):
                    raise AssertionError("warmup published a velocity")
            eigenvalues = np.linalg.eigvalsh(reference.covariance)
            if eigenvalues.min() < -1e-12:
                raise AssertionError("reference covariance lost positive semidefiniteness")
        if name == "outlier_then_recovery" and 24 not in rejected:
            raise AssertionError("the controlled outlier was not rejected")
        report = {"name": name, "observations": len(frames), "rejected_indices": rejected,
                        "accepted_count": reference.accepted_count,
                        "raw_position_rmse_m": math.sqrt(float(np.mean(raw_errors))),
                        "filtered_position_rmse_m": math.sqrt(float(np.mean(filtered_errors))),
                        "velocity_vector_rmse_mps": math.sqrt(float(np.mean(velocity_errors))),
                        "truth": "analytic physical trajectory; measurement noise generated with the recorded seed"}
        if name == "stationary":
            report.update({"observed_path_length_m": reference.path_length,
                           "true_path_length_m": 0.0,
                           "stationary_distance_bias_m": reference.path_length,
                           "distance_interpretation": "The accepted filtered-position polyline accumulates noise even for a stationary object. It is not true travelled distance."})
        reports.append(report)
    return {"cases": reports, "maximum_absolute_errors": maximum,
            "implementation_compared": bool(binary)}


def acquire_eth(data_directory):
    """Keep the official archive external and extract only allowlisted files."""
    data_directory.mkdir(parents=True, exist_ok=True)
    archive = data_directory / "ewap_dataset_full.tgz"
    if not archive.exists():
        temporary = data_directory / "ewap_dataset_full.tgz.part"
        checkpoint = data_directory / "ewap_dataset_full.download.json"
        # Bounded range requests avoid an indefinitely slow long response and
        # make every transferred chunk independently length-checkable.
        chunk_size = 1024 * 1024
        completed = set()
        if temporary.exists() and checkpoint.exists():
            saved = json.loads(checkpoint.read_text(encoding="utf-8"))
            if saved.get("url") == ETH_URL and saved.get("chunk_size") == chunk_size:
                completed = set(saved["completed"])

        def fetch_range(first):
            last = min(first + chunk_size, ETH_BYTES) - 1
            for attempt in range(4):
                try:
                    request = urllib.request.Request(
                        ETH_URL, headers={"Range": "bytes={}-{}".format(first, last)}
                    )
                    with urllib.request.urlopen(request, timeout=12) as response:
                        content = response.read(last - first + 2)
                        expected = "bytes {}-{}/{}".format(first, last, ETH_BYTES)
                        if response.status != 206 or response.headers.get("Content-Range") != expected or len(content) != last - first + 1:
                            raise AssertionError("ETH server returned an invalid byte range")
                    return first, content
                except (OSError, urllib.error.URLError):
                    if attempt == 3:
                        raise
            raise AssertionError("unreachable download retry")

        with temporary.open("r+b" if completed else "wb") as destination:
            transferred = sum(min(chunk_size, ETH_BYTES - first) for first in completed)
            failures = []
            with ThreadPoolExecutor(max_workers=4) as executor:
                futures = [executor.submit(fetch_range, first) for first in range(0, ETH_BYTES, chunk_size) if first not in completed]
                for index, future in enumerate(as_completed(futures)):
                    try:
                        first, content = future.result()
                    except Exception as error:
                        failures.append(str(error))
                        continue
                    destination.seek(first)
                    destination.write(content)
                    destination.flush()
                    completed.add(first)
                    checkpoint.write_text(json.dumps({"url": ETH_URL, "chunk_size": chunk_size, "completed": sorted(completed)}), encoding="utf-8")
                    transferred += len(content)
                    if index % 8 == 0 or transferred == ETH_BYTES:
                        print("ETH download: {}/{} bytes".format(transferred, ETH_BYTES), file=sys.stderr, flush=True)
            if failures:
                raise RuntimeError("ETH download retained {} successful ranges; retry the command for remaining ranges: {}".format(len(completed), failures[0]))
        if temporary.stat().st_size != ETH_BYTES:
            raise AssertionError("ETH archive length differs from the verified upstream release")
        temporary.replace(archive)
        if checkpoint.exists():
            checkpoint.unlink()
    archive_bytes = archive.read_bytes()
    if len(archive_bytes) != ETH_BYTES:
        raise AssertionError("ETH archive has an unexpected length")
    if hashlib.sha256(archive_bytes).hexdigest() != ETH_ARCHIVE_SHA256:
        raise AssertionError("ETH archive differs from the pinned official release")
    required = {"ewap_dataset/README.txt", "ewap_dataset/seq_hotel/info.txt",
                "ewap_dataset/seq_hotel/H.txt", "ewap_dataset/seq_hotel/obsmat.txt"}
    result = {"url": ETH_URL, "bytes": len(archive_bytes),
              "archive_sha256": hashlib.sha256(archive_bytes).hexdigest()}
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:gz") as source:
        names = set(source.getnames())
        if not required <= names:
            raise AssertionError("official ETH archive is missing required files")
        for name in sorted(required):
            content = source.extractfile(name).read()
            target = data_directory / name.rsplit("/", 1)[-1]
            target.write_bytes(content)
        video = source.extractfile("ewap_dataset/seq_hotel/seq_hotel.avi").read(65536)
        offset = video.find(b"avih")
        if offset < 0:
            raise AssertionError("AVI header not found")
        fields = struct.unpack("<14I", video[offset + 8:offset + 64])
        result["video"] = {"width": fields[8], "height": fields[9], "frames": fields[4],
                           "fps": 1e6 / fields[0], "duration_s": fields[4] * fields[0] / 1e6,
                           "bytes": source.getmember("ewap_dataset/seq_hotel/seq_hotel.avi").size}
    obsmat = (data_directory / "obsmat.txt").read_bytes()
    if hashlib.sha256(obsmat).hexdigest() != ETH_OBSMAT_SHA256:
        raise AssertionError("official seq_hotel annotations differ from the verified release")
    result["obsmat_sha256"] = ETH_OBSMAT_SHA256
    return result


def verify_eth(binary, rng, data_directory):
    metadata = acquire_eth(data_directory)
    observations = np.loadtxt(str(data_directory / "obsmat.txt"))
    original_matrix = np.loadtxt(str(data_directory / "H.txt"))
    # The original Hotel annotation transform takes [row, column, 1]. The
    # public API and OpenCV take [x=column, y=row, 1]. This conversion was also
    # checked by overlaying the ten first-frame annotation positions on video.
    swap = np.array([[0.0, 1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]])
    matrix = original_matrix @ swap
    inverse = np.linalg.inv(matrix)
    unique_ids, counts = np.unique(observations[:, 1].astype(int), return_counts=True)
    selected = unique_ids[np.argsort(-counts)[:8]]
    maximum_roundtrip_error = 0.0
    maximum_filter_errors = {}
    status_counts = {}
    retained = []
    for identity in selected:
        rows = observations[observations[:, 1] == identity]
        rows = rows[np.argsort(rows[:, 0])]
        # The published annotation is converted back through the same H solely
        # to exercise controlled-noise propagation and timestamps, not accuracy.
        frames = []
        for row in rows:
            world = row[[2, 4]]
            homogeneous = inverse @ np.r_[world, 1.0]
            pixel = homogeneous[:2] / homogeneous[2]
            restored = project_reference(matrix, pixel, [4.0, 0.0, 4.0])[0]
            maximum_roundtrip_error = max(maximum_roundtrip_error, float(np.max(np.abs(restored - world))))
            pixel = pixel + rng.normal(0.0, 2.0, 2)
            frames.append({"timestamp_us": str(int(round((row[0] - 1.0) / 25.0 * 1e6))),
                           "observations": [{"track_id": int(identity), "point": pixel.tolist(),
                                             "covariance": [4.0, 0.0, 4.0]}], "lost": [], "removed": []})
        config = stream_config("eth-hotel-controlled-roundtrip", "pixel", {
            "matrix": matrix.ravel().tolist(),
            "roi": [[0.0, 0.0], [720.0, 0.0], [720.0, 576.0], [0.0, 576.0]],
            "max_meters_per_pixel": 0.5, "ground_noise_floor_m": 0.001,
        })
        outputs = run_json(binary, ["--stream"], [config] + frames) if binary else None
        if outputs is not None and len(outputs) != len(frames):
            raise AssertionError("ETH replay did not return all frames")
        reference = None
        for index, frame in enumerate(frames):
            pixel = np.asarray(frame["observations"][0]["point"])
            timestamp_us = int(frame["timestamp_us"])
            actual = outputs[index]["tracks"][0] if outputs is not None else None
            if actual is not None:
                status_counts[actual["status"]] = status_counts.get(actual["status"], 0) + 1
            if (pixel < 0.0).any() or pixel[0] > 720.0 or pixel[1] > 576.0:
                if actual is not None and actual["status"] != "rejected_projection":
                    raise AssertionError("an out-of-domain ETH observation was accepted")
                continue
            position, covariance, _ = project_reference(matrix, pixel, [4.0, 0.0, 4.0])
            if reference is None or timestamp_us - reference.timestamp_us > 500000:
                reference = KalmanReference(position, compact_covariance(covariance), timestamp_us)
                accepted = True
            else:
                accepted, _ = reference.update(position, compact_covariance(covariance), timestamp_us)
            if actual is not None:
                expected_status = "rejected_innovation" if not accepted else (
                    "ready" if reference.accepted_count >= 3 and timestamp_us - reference.first_timestamp_us >= 300000 else "initializing"
                )
                if actual["status"] != expected_status:
                    raise AssertionError("ETH track {} frame {}: status differs from reference".format(int(identity), index))
                if accepted:
                    compare(actual["filter_state"], reference.state, "eth_filter_state", maximum_filter_errors)
                    compare(actual["filter_covariance"], reference.covariance.ravel(), "eth_filter_covariance", maximum_filter_errors)
        retained.append({"track_id": int(identity), "observations": len(rows),
                         "first_timestamp_us": frames[0]["timestamp_us"],
                         "last_timestamp_us": frames[-1]["timestamp_us"],
                         "implementation_frames": len(outputs) if outputs is not None else None})
    metadata.update({"sequence": "seq_hotel", "annotation_rows": len(observations),
                     "identities": len(unique_ids), "tracks_replayed": retained,
                     "maximum_roundtrip_error_m": maximum_roundtrip_error,
                     "maximum_filter_absolute_errors": maximum_filter_errors,
                     "implementation_status_counts": status_counts,
                     "pixel_noise_std": 2.0, "implementation_compared": bool(binary),
                     "pixel_axis_conversion": "H_xy = original_H @ [[0,1,0],[1,0,0],[0,0,1]]; original Hotel H expects row,column",
                     "effective_xy_homography": matrix.ravel().tolist(),
                     "validation_kind": "controlled-noise homography roundtrip on published real trajectories",
                     "independent_metric_ground_truth": False,
                     "limitations": "World annotations and velocities were obtained using the supplied homography. Inverting and reapplying it does not establish real calibration, position or speed accuracy. No raw pixel footpoint annotations are bundled. This replay does not run a detector or tracker.",
                     "terms": "ETH official dataset page specifies research use; archive remains external to the library package."})
    return metadata


def toolchain_version():
    try:
        completed = subprocess.run(["moon", "version", "--all", "--no-path"],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, encoding="utf-8", timeout=30)
        return completed.stdout.strip()
    except (OSError, subprocess.SubprocessError) as error:
        return "unavailable: {}".format(error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, help="built native MoonGround executable")
    parser.add_argument("--reference-only", action="store_true", help="check the oracle without claiming MoonBit verification")
    parser.add_argument("--eth", action="store_true", help="download the 76.1 MiB official archive and replay Hotel trajectories")
    parser.add_argument("--output", type=Path, default=ROOT / "validation" / "results.json")
    parser.add_argument("--data-dir", type=Path, default=ROOT / "validation" / "data")
    args = parser.parse_args()
    if args.binary is None and not args.reference_only:
        parser.error("provide --binary or explicitly choose --reference-only")
    binary = args.binary.resolve() if args.binary else None
    if binary is not None and not binary.is_file():
        parser.error("native binary does not exist: {}".format(binary))
    started = time.perf_counter()
    result = {"format_version": "1", "seed": SEED, "tolerance": {"absolute": TOLERANCE, "relative": TOLERANCE},
              "command": " ".join(shlex.quote(value) for value in [sys.executable] + sys.argv),
              "python": platform.python_version(), "numpy": np.__version__,
              "moonbit": toolchain_version(), "implementation_verified": bool(binary),
              "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest() if binary else None}
    rng = np.random.default_rng(SEED)
    result["projection"] = verify_projection(binary, rng)
    result["monte_carlo_covariance"] = verify_monte_carlo(binary)
    result["motion"] = verify_motion(binary, rng)
    if args.eth:
        result["eth_hotel"] = verify_eth(binary, rng, args.data_dir)
    result["elapsed_seconds"] = time.perf_counter() - started
    result["status"] = "passed" if binary else "reference_only_passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(json.dumps({"status": result["status"], "output": str(args.output),
                      "projection_cases": result["projection"]["cases"],
                      "motion_cases": len(result["motion"]["cases"]),
                      "implementation_verified": result["implementation_verified"]}, ensure_ascii=True))


if __name__ == "__main__":
    main()
