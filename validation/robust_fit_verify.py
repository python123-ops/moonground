#!/usr/bin/env python3
"""Independent numerical checks for robust ground-control calibration.

Known transforms create the observations. NumPy refits the returned final
inliers; it never reproduces the production sampler or consensus search.
"""
import argparse
import copy
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
import camera_verify as camera_ref
import verify as baseline

ROOT = Path(__file__).resolve().parents[1]
SEED = 20261114
TOLERANCE = 2e-8
H = np.array([[0.020, 0.0021, -4.0], [-0.001, 0.023, -2.0],
              [0.00012, -0.00006, 1.0]])
ROI = [[200, 100], [1080, 100], [1080, 650], [200, 650]]
OPTIONS = {"inlier_threshold_m": 0.025, "min_inlier_ratio": 0.6,
           "max_trials": 512, "seed": 17}


def encode(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=True, allow_nan=False)


def run(binary, request, mode="--calibrate", expected_exit=0):
    source = request if isinstance(request, str) else encode(request)
    process = subprocess.run([str(binary), mode], input=(source + "\n").encode("utf-8"),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120, cwd=str(ROOT))
    stderr = process.stderr.decode("utf-8")
    if process.returncode != expected_exit:
        raise AssertionError("{} exit {} instead of {}: {}".format(mode, process.returncode, expected_exit, stderr[:1800]))
    if expected_exit:
        if process.stdout:
            raise AssertionError("a rejected fit emitted partial stdout")
        return {"exit_code": process.returncode, "stderr": stderr.strip(), "stdout_bytes": 0}
    if stderr or not process.stdout.endswith(b"\n"):
        raise AssertionError("successful native fit emitted stderr or incomplete JSON")
    return json.loads(process.stdout.decode("utf-8"))


def project(matrix, points):
    points = np.asarray(points, dtype=float)
    mapped = np.c_[points, np.ones(len(points))] @ np.asarray(matrix).reshape(3, 3).T
    return mapped[:, :2] / mapped[:, 2:]


def normalize(points):
    center = np.mean(points, axis=0)
    rms = np.sqrt(np.mean(np.sum((points - center) ** 2, axis=1)))
    scale = np.sqrt(2.0) / rms
    transform = np.array([[scale, 0, -scale * center[0]],
                          [0, scale, -scale * center[1]], [0, 0, 1]])
    return (points - center) * scale, transform


def least_squares_refit(pixels, world):
    """Independent SVD-backed least squares for the normalized eight unknowns."""
    source, source_transform = normalize(np.asarray(pixels))
    target, target_transform = normalize(np.asarray(world))
    a, b = [], []
    for (x, y), (u, v) in zip(source, target):
        a += [[x, y, 1, 0, 0, 0, -u * x, -u * y],
              [0, 0, 0, x, y, 1, -v * x, -v * y]]
        b += [u, v]
    coefficients, _, rank, _ = np.linalg.lstsq(np.asarray(a), np.asarray(b), rcond=None)
    if rank != 8:
        raise AssertionError("returned inlier set does not determine a homography")
    model = np.r_[coefficients, 1.0].reshape(3, 3)
    return np.linalg.solve(target_transform, model) @ source_transform


def fixture(camera=True, small=False):
    rng = np.random.default_rng(SEED)
    pixels = np.array([[x, y] for y in np.linspace(130, 610, 6)
                       for x in np.linspace(230, 1050, 6)], dtype=float)
    bad = np.arange(2, len(pixels), 4)
    if small:
        pixels = np.array([[250, 160], [400, 160], [550, 160], [700, 160],
                           [300, 310], [900, 310], [1050, 610], [280, 610],
                           [640, 450], [840, 580]], dtype=float)
        bad = np.array([4, 8])
    truth = project(H, pixels)
    clean_world = truth + (0 if small else rng.normal(0, 0.002, truth.shape))
    contaminated = clean_world.copy()
    contaminated[bad] += [1.2, -0.9]
    checks = np.array([[310, 210], [450, 470], [760, 260], [970, 530],
                       [610, 390], [870, 570]], dtype=float)
    model_camera = copy.deepcopy(camera_ref.CAMERAS[0]) if camera else None
    def raw(points):
        return [camera_ref.distort_pixel(point, model_camera).tolist() for point in points] if camera else points.tolist()
    request = {"control_pixels": raw(pixels), "control_world": contaminated.tolist(),
               "check_pixels": raw(checks), "check_world": project(H, checks).tolist(),
               "roi": ROI, "max_fit_error_m": 0.02, "max_check_error_m": 0.02,
               "max_meters_per_pixel": 0.5, "ground_noise_floor_m": 0.001,
               "robust": dict(OPTIONS)}
    if camera:
        request["camera"] = model_camera
    clean_mask = np.ones(len(pixels), dtype=bool)
    clean_mask[bad] = False
    return request, {"ideal_pixels": pixels, "clean_world": clean_world,
                     "clean_mask": clean_mask, "truth_h": H, "world_scale": 1.0}


def rectified(request, key):
    if "camera" not in request:
        return np.asarray(request[key])
    return np.array([camera_ref.rectify_reference(point, request["camera"])[0]
                     for point in request[key]])


def check_success(binary, request, truth, name):
    actual = run(binary, request)
    report = actual["robust_report"]
    count = len(request["control_pixels"])
    mask = np.asarray(report["inlier_mask"])
    if mask.shape != (count,) or mask.dtype != np.dtype(bool):
        raise AssertionError(name + ": mask is not one Boolean per original control")
    if truth["clean_mask"] is not None and not np.array_equal(mask, truth["clean_mask"]):
        raise AssertionError(name + ": clear-margin contamination was not identified")
    if np.any(mask[truth.get("known_outlier_indices", [])]):
        raise AssertionError(name + ": a known gross annotation error survived refinement")
    pixels = rectified(request, "control_pixels")
    world = np.asarray(request["control_world"])
    matrix = np.asarray(actual["calibration"]["matrix"]).reshape(3, 3)
    difference = project(matrix, pixels) - world
    errors = np.hypot(difference[:, 0], difference[:, 1])
    reported_errors = np.asarray(report["control_errors_m"])
    if reported_errors.shape != errors.shape or not np.allclose(reported_errors, errors, rtol=TOLERANCE, atol=TOLERANCE):
        raise AssertionError(name + ": reported errors are detached from the returned H")
    if not np.array_equal(mask, errors <= request["robust"]["inlier_threshold_m"]):
        raise AssertionError(name + ": final-H threshold and mask disagree")
    expected_outliers = np.flatnonzero(~mask).tolist()
    if report["outlier_indices"] != expected_outliers:
        raise AssertionError(name + ": outlier indices do not preserve original ordering")
    selected = int(mask.sum())
    if report["control_count"] != count or report["inlier_count"] != selected or actual["report"]["fit_count"] != selected:
        raise AssertionError(name + ": counts do not describe final inliers")
    if selected < max(6, math.ceil(count * request["robust"]["min_inlier_ratio"])):
        raise AssertionError(name + ": minimum consensus requirement was bypassed")
    if report["options"] != request["robust"]:
        raise AssertionError(name + ": effective robust options changed")
    if not (1 <= report["valid_hypotheses"] <= report["trials_run"] <= request["robust"]["max_trials"]):
        raise AssertionError(name + ": trial accounting exceeds its explicit budget")
    if not (1 <= report["refinement_steps"] <= 8):
        raise AssertionError(name + ": refinement accounting is unbounded")
    summary = actual["report"]
    if summary["check_count"] != len(request["check_pixels"]):
        raise AssertionError(name + ": not all independent holdout pairs were counted")
    for key, expected in (("fit_rms_m", np.sqrt(np.mean(errors[mask] ** 2))),
                          ("fit_max_error_m", np.max(errors[mask]))):
        if not np.isclose(summary[key], expected, rtol=TOLERANCE, atol=TOLERANCE):
            raise AssertionError(name + ": " + key + " does not use final inliers")
    checks = rectified(request, "check_pixels")
    delta = project(matrix, checks) - request["check_world"]
    check_errors = np.hypot(delta[:, 0], delta[:, 1])
    for key, expected in (("check_rms_m", np.sqrt(np.mean(check_errors ** 2))),
                          ("check_max_error_m", np.max(check_errors))):
        if not np.isclose(summary[key], expected, rtol=TOLERANCE, atol=TOLERANCE):
            raise AssertionError(name + ": holdout report differs from returned H")
    independent = least_squares_refit(pixels[mask], world[mask])
    roi = np.asarray(request["roi"])
    grid = np.array([[x, y] for x in np.linspace(roi[:, 0].min(), roi[:, 0].max(), 21)
                     for y in np.linspace(roi[:, 1].min(), roi[:, 1].max(), 17)])
    refit_error = float(np.max(np.linalg.norm(project(matrix, grid) - project(independent, grid), axis=1)))
    truth_error = float(np.max(np.linalg.norm(project(matrix, grid) - project(truth["truth_h"], grid), axis=1)))
    scale = truth["world_scale"]
    if refit_error / scale > 2e-7 or truth_error / scale > truth.get("dense_tolerance_m", 0.01):
        raise AssertionError(name + ": dense projection disagrees with NumPy refit/known scene")
    projected = run(binary, {"calibration": actual["calibration"],
        "points": [{"point": point.tolist(), "covariance": [4, 0, 4]} for point in grid]}, mode="--project")
    cli_positions = np.array([item["position_m"] for item in projected["points"]])
    if not np.allclose(cli_positions, project(matrix, grid), rtol=TOLERANCE, atol=TOLERANCE):
        raise AssertionError(name + ": exported calibration is not reusable through --project")
    if "camera" in request and actual.get("camera") != request["camera"]:
        raise AssertionError(name + ": raw-camera definition was lost")
    return actual, {"name": name, "controls": count, "inliers": selected,
        "outlier_indices": expected_outliers, "dense_points": len(grid),
        "options": report["options"],
        "max_fit_error_m": request["max_fit_error_m"],
        "max_check_error_m": request["max_check_error_m"],
        "request_sha256": hashlib.sha256(encode(request).encode("utf-8")).hexdigest(),
        "returned_matrix": actual["calibration"]["matrix"],
        "returned_inlier_mask": report["inlier_mask"],
        "returned_control_errors_m": report["control_errors_m"],
        "numpy_refit_matrix": (independent / np.max(np.abs(independent))).ravel().tolist(),
        "numpy_refit_dense_max_error_m": refit_error,
        "known_truth_dense_max_error_m": truth_error,
        "world_scale": scale, "trials_run": report["trials_run"],
        "valid_hypotheses": report["valid_hypotheses"], "refinement_steps": report["refinement_steps"],
        "control_error_max_relative_difference": float(np.max(np.abs(reported_errors - errors) / np.maximum(1, errors))),
        "final_mask_matches_returned_h": True}


def numerical_checks(binary):
    request, truth = fixture()
    results = []
    output, report = check_success(binary, request, truth, "raw_camera_contamination")
    results.append(report)
    strict = copy.deepcopy(request)
    strict.pop("robust")
    strict_rejection = run(binary, strict, expected_exit=2)
    for name, camera, small in (("rectified_contamination", False, False),
                                 ("first_four_collinear_small_set", True, True)):
        item, expected = fixture(camera=camera, small=small)
        _, report = check_success(binary, item, expected, name)
        results.append(report)
    clean = copy.deepcopy(request)
    clean["control_world"] = truth["clean_world"].tolist()
    clean_truth = dict(truth, clean_mask=np.ones(len(truth["clean_mask"]), dtype=bool))
    clean_output, report = check_success(binary, clean, clean_truth, "all_clean")
    results.append(report)
    clean.pop("robust")
    strict_clean = run(binary, clean)
    if "robust_report" in strict_clean:
        raise AssertionError("the unchanged strict path unexpectedly added robust diagnostics")
    if strict_clean["calibration"] != clean_output["calibration"]:
        raise AssertionError("robust all-inlier refit differs from the unchanged strict solver")
    huge = copy.deepcopy(request)
    huge["control_world"][2] = [1e250, -1e250]
    _, report = check_success(binary, huge, truth, "huge_finite_outlier")
    results.append(report)
    borderline, borderline_truth = fixture(camera=False)
    edge_rng = np.random.default_rng(SEED + 23)
    noisy_world = project(H, borderline_truth["ideal_pixels"]) + edge_rng.normal(0, 0.007, (36, 2))
    noisy_world[~borderline_truth["clean_mask"]] += edge_rng.normal([0.08, -0.06], 0.02, (9, 2))
    borderline["control_world"] = noisy_world.tolist()
    borderline["robust"].update(inlier_threshold_m=0.015, min_inlier_ratio=0.6, max_trials=128)
    borderline["max_check_error_m"] = 0.05
    expected = dict(borderline_truth, clean_mask=None, dense_tolerance_m=0.03,
                    known_outlier_indices=np.flatnonzero(~borderline_truth["clean_mask"]).tolist())
    _, report = check_success(binary, borderline, expected, "noisy_mask_requires_multiple_refinements")
    if report["refinement_steps"] < 2:
        raise AssertionError("the deterministic noisy fixture no longer exercises iterative reclassification")
    report.update(control_noise_std_m=0.007, generator_seed=SEED + 23,
                  requires_multiple_refinement_steps=True)
    results.append(report)
    rng = np.random.default_rng(SEED + 1)
    for index in range(2):
        order = rng.permutation(len(request["control_pixels"]))
        item = copy.deepcopy(request)
        for key in ("control_pixels", "control_world"):
            item[key] = [item[key][int(i)] for i in order]
        expected = dict(truth, ideal_pixels=truth["ideal_pixels"][order], clean_mask=truth["clean_mask"][order])
        _, report = check_success(binary, item, expected, "control_permutation_" + str(index))
        results.append(report)
    for pixel_scale, world_scale in ((0.001, 1), (1000, 1000)):
        item = copy.deepcopy(request)
        for key in ("control_pixels", "check_pixels", "roi"):
            item[key] = (np.asarray(item[key]) * pixel_scale).tolist()
        for key in ("control_world", "check_world"):
            item[key] = (np.asarray(item[key]) * world_scale).tolist()
        for key in ("fx", "fy", "cx", "cy"):
            item["camera"][key] *= pixel_scale
        for key in ("max_fit_error_m", "max_check_error_m", "ground_noise_floor_m"):
            item[key] *= world_scale
        item["max_meters_per_pixel"] *= world_scale / pixel_scale
        item["robust"]["inlier_threshold_m"] *= world_scale
        transformed_h = np.diag([world_scale, world_scale, 1]) @ H @ np.diag([1 / pixel_scale, 1 / pixel_scale, 1])
        expected = dict(truth, truth_h=transformed_h, world_scale=world_scale)
        _, report = check_success(binary, item, expected, "coordinate_scale_{}_{}".format(pixel_scale, world_scale))
        results.append(report)
    return request, output, {"cases": results, "strict_contamination_rejection": strict_rejection,
        "all_clean_robust_matches_strict": True,
        "conditions": "Known projective scene; 0.002 m Gaussian control-label noise; fixed 25% gross mislabels, with clear residual margins. Permutation and scale checks concern these fixtures, not arbitrary budget-limited data."}


def holdout_checks(binary, request, original):
    changed = copy.deepcopy(request)
    changed["max_check_error_m"] = 0.2
    baseline_output = run(binary, changed)
    alternative = copy.deepcopy(changed)
    checks = np.array([[330, 290], [460, 510], [790, 310], [990, 560]])
    alternative["check_pixels"] = [camera_ref.distort_pixel(p, request["camera"]).tolist() for p in checks]
    alternative["check_world"] = (project(H, checks) + [0.04, -0.03]).tolist()
    alternate_output = run(binary, alternative)
    for key in ("calibration", "robust_report", "camera"):
        if baseline_output[key] != alternate_output[key] or baseline_output[key] != original[key]:
            raise AssertionError("holdout locations/labels changed search, ranking, refit, or camera")
    bad = copy.deepcopy(request)
    bad["check_world"][0][0] += 0.5
    rejected = run(binary, bad, expected_exit=2)
    return {"accepted_holdout_sets_leave_model_mask_and_search_exact": True,
            "alternate_holdout_label_bias_m": [0.04, -0.03],
            "bad_holdout_rejected_without_repair": rejected}


def rejection_checks(binary, request):
    cases = []
    def reject(name, item):
        cases.append({"name": name, **run(binary, item, expected_exit=2)})
    for field, value in (("inlier_threshold_m", 0), ("inlier_threshold_m", -1),
        ("min_inlier_ratio", 0), ("min_inlier_ratio", 1.01), ("max_trials", 0),
        ("max_trials", 4097), ("seed", 0), ("seed", 2147483648)):
        item = copy.deepcopy(request)
        item["robust"][field] = value
        reject(field + "_" + str(value), item)
    item = copy.deepcopy(request)
    item["robust"]["typo"] = 1
    reject("unknown_robust_option", item)
    item = copy.deepcopy(request)
    item["robust"] = "ransac"
    reject("wrong_robust_type", item)
    for field, token in (("max_trials", "512.0000000000000000001"),
                          ("seed", "17.0000000000000000001"),
                          ("inlier_threshold_m", "1e999")):
        source = re.sub(r'("' + field + r'":)[^,}]+', lambda m: m.group(1) + token, encode(request), count=1)
        reject("raw_invalid_" + field, source)
    source = encode(request)
    reject("duplicate_seed_key", source.replace('"seed":17', '"seed":17,"seed":18'))
    item = copy.deepcopy(request)
    item["control_world"].pop()
    reject("mismatched_controls", item)
    item = copy.deepcopy(request)
    item["check_pixels"][0] = item["control_pixels"][2]
    reject("holdout_reuses_rejected_control_pixel", item)
    item = copy.deepcopy(request)
    item["check_world"][0] = item["control_world"][2]
    reject("holdout_reuses_rejected_control_world", item)
    item = copy.deepcopy(request)
    item["control_pixels"][1] = item["control_pixels"][2]
    reject("duplicate_control_pixel", item)
    item = copy.deepcopy(request)
    item["control_world"][1] = item["control_world"][2]
    reject("duplicate_control_world", item)
    item = copy.deepcopy(request)
    item["camera"]["fx"] = 0
    reject("invalid_camera", item)
    item = copy.deepcopy(request)
    item["robust"].update(min_inlier_ratio=1.0, max_trials=1, inlier_threshold_m=1e-5)
    reject("one_trial_cannot_meet_impossible_full_consensus", item)
    return {"rejected_cases": len(cases), "cases": cases}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/robust-fit.test.mjs"]
    completed = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8", timeout=180)
    if completed.returncode:
        raise AssertionError("web robust fit failed:\n" + completed.stdout[-9000:] + completed.stderr[-1500:])
    summary = {key: int(value) for key, value in re.findall(r"^# (tests|pass|fail|skipped|cancelled) (\d+)$", completed.stdout, re.M)}
    if not summary.get("tests") or summary.get("tests") != summary.get("pass") or summary.get("fail"):
        raise AssertionError("Node summary is incomplete: " + completed.stdout[-1500:])
    return {"status": "passed", "command": " ".join(command),
        "node": subprocess.check_output(["node", "--version"], encoding="utf-8").strip(),
        "summary": summary, "stdout_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(),
        "test_script_sha256": hashlib.sha256((ROOT / "web/robust-fit.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/robust-fit-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "seed": SEED, "tolerance": TOLERANCE,
        "known_base_homography": H.ravel().tolist(), "base_roi": ROI,
        "base_camera": camera_ref.CAMERAS[0], "base_control_noise_std_m": 0.002,
        "command": " ".join(shlex.quote(value) for value in [sys.executable] + sys.argv),
        "python": platform.python_version(), "numpy": np.__version__,
        "toolchain": baseline.toolchain_version(), "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "camera_reference_sha256": hashlib.sha256(Path(camera_ref.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    request, output, result["numerical"] = numerical_checks(binary)
    result["holdout_isolation"] = holdout_checks(binary, request, output)
    result["strict_rejections"] = rejection_checks(binary, request)
    if args.web:
        result["web_parity_and_checkpoint"] = web_checks(binary)
    result.update(status="passed", elapsed_seconds=time.perf_counter() - started)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(encode({"status": "passed", "output": str(args.output),
        "numerical_cases": len(result["numerical"]["cases"]),
        "rejections": result["strict_rejections"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
