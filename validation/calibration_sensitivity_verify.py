#!/usr/bin/env python3
"""Independent first-order shared homography-mode reference.

Fraction differentiates the original projective quotient along each mode,
then forms the exact marginal/cross/relative moments. This is a numerical
comparison with a documented floating-point tolerance, not an interval proof.
Central finite differences of the nonlinear map provide a second derivative
check. Random fixtures use a fixed seed and never infer modes from fit residuals.
"""
import argparse
import copy
from fractions import Fraction
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

ROOT = Path(__file__).resolve().parents[1]
MODE = "--calibration-sensitivity"
SEED = 20261115
F = lambda value: Fraction.from_float(float(value))
EPS = F(2.0 ** -52)


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def native(binary, request):
    process = subprocess.run([str(binary), MODE], input=encode(request).encode("utf-8"),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    assert process.returncode == 0, process.stderr.decode("utf-8", "replace")
    assert not process.stderr and process.stdout.endswith(b"\n")
    return json.loads(process.stdout)


def quotient(matrix, point):
    p = tuple(map(F, point)) + (Fraction(1),)
    h = list(map(F, matrix))
    rows = [sum(h[3 * row + j] * p[j] for j in range(3)) for row in range(3)]
    return [rows[0] / rows[2], rows[1] / rows[2]], rows, p


def exact_responses(matrix, modes, point):
    position, rows, p = quotient(matrix, point)
    responses, tolerances = [], []
    for mode in modes:
        m = list(map(F, mode))
        d = [sum(m[3 * row + j] * p[j] for j in range(3)) for row in range(3)]
        response, tolerance = [], []
        for axis in range(2):
            response.append((d[axis] * rows[2] - rows[axis] * d[2]) / rows[2] ** 2)
            # Absolute term scale handles gauge cancellation without claiming
            # relative accuracy for a derivative close to zero. It is only
            # an acceptance tolerance for these fixtures, not a public bound.
            scale = sum(abs(m[3 * axis + j] * p[j] / rows[2]) for j in range(3))
            scale += sum(abs(rows[axis] * m[6 + j] * p[j] / rows[2] ** 2) for j in range(3))
            tolerance.append(256 * EPS * max(scale, F(1e-300)))
        responses.append(response)
        tolerances.append(tolerance)
    return position, responses, tolerances


def check_value(actual, expected, tolerance, stats):
    assert isinstance(actual, (int, float)) and math.isfinite(actual)
    error = abs(F(actual) - expected)
    tolerance = max(tolerance, F(1e-300))
    assert error <= tolerance, (actual, float(expected), float(error), float(tolerance))
    stats["scalars"] += 1
    stats["maximum_absolute_error"] = max(stats["maximum_absolute_error"], float(error))
    stats["maximum_tolerance_fraction"] = max(stats["maximum_tolerance_fraction"], float(error / tolerance))


def check_moment(actual, a, b, ea, eb, indices, stats):
    assert len(actual) == len(indices)
    for got, (i, j) in zip(actual, indices):
        expected = sum(x[i] * y[j] for x, y in zip(a, b))
        tolerance = sum(abs(x[i]) * dy[j] + abs(y[j]) * dx[i] + dx[i] * dy[j]
                        for x, y, dx, dy in zip(a, b, ea, eb))
        tolerance += 256 * EPS * sum(abs(x[i] * y[j]) for x, y in zip(a, b))
        check_value(got, expected, tolerance, stats)


def check_request(binary, request, stats, finite_difference=False):
    result = native(binary, request)
    assert result["schema_version"] == "0.1.0" and result["kind"] == "calibration_sensitivity"
    assert result["evidence_scope"] == "first_order_shared_homography_parameters"
    assert result["mode_count"] == len(request["modes"])
    matrix = request["calibration"]["matrix"]
    gauge = max(abs(v) for v in matrix)
    normalized = [float(v) / gauge for v in matrix]
    assert result["normalized_matrix"] == normalized
    assert len(result["probes"]) == len(request["probes"])
    for probe, row in zip(request["probes"], result["probes"]):
        assert row["probe_id"] == probe["probe_id"]
        a, da, ea = exact_responses(normalized, request["modes"], probe["first_pixel"])
        b, db, eb = exact_responses(normalized, request["modes"], probe["second_pixel"])
        for output, position, derivatives, errors in [(row["first"], a, da, ea), (row["second"], b, db, eb)]:
            assert len(output["position_m"]) == 2
            assert len(output["mode_responses_m"]) == len(derivatives)
            for got, want in zip(output["position_m"], position):
                check_value(got, want, 256 * EPS * max(abs(want), F(1)), stats)
            for got, want, tolerance in zip(output["mode_responses_m"], derivatives, errors):
                assert len(got) == 2
                for axis in range(2):
                    check_value(got[axis], want[axis], tolerance[axis], stats)
            check_moment(output["contribution_m2"], derivatives, derivatives, errors, errors,
                         [(0, 0), (0, 1), (1, 1)], stats)
        relative = [[y[i] - x[i] for i in range(2)] for x, y in zip(da, db)]
        erel = [[dx[i] + dy[i] for i in range(2)] for dx, dy in zip(ea, eb)]
        check_moment(row["cross_contribution_m2"], da, db, ea, eb,
                     [(0, 0), (0, 1), (1, 0), (1, 1)], stats)
        check_moment(row["displacement_contribution_m2"], relative, relative, erel, erel,
                     [(0, 0), (0, 1), (1, 1)], stats)
        assert len(row["displacement_m"]) == 2
        for i in range(2):
            check_value(row["displacement_m"][i], b[i] - a[i],
                        512 * EPS * max(abs(a[i]), abs(b[i]), F(1)), stats)
        if finite_difference:
            h = np.asarray(normalized).reshape(3, 3)
            for point, expected in [(probe["first_pixel"], da), (probe["second_pixel"], db)]:
                p = np.array([point[0], point[1], 1.0])
                for mode, want in zip(request["modes"], expected):
                    m = np.asarray(mode).reshape(3, 3)
                    delta = 2.0 ** -12
                    plus = (h + delta * m) @ p
                    minus = (h - delta * m) @ p
                    derivative = (plus[:2] / plus[2] - minus[:2] / minus[2]) / (2 * delta)
                    exact = np.array(list(map(float, want)))
                    error = float(np.max(np.abs(derivative - exact)))
                    assert np.allclose(derivative, exact, rtol=2e-5, atol=2e-9), (derivative, exact)
                    stats["finite_difference_vectors"] += 1
                    stats["maximum_finite_difference_absolute_error"] = max(stats["maximum_finite_difference_absolute_error"], error)
        stats["pairs"] += 1
    stats["requests"] += 1
    return result


def fixtures():
    original = json.loads((ROOT / "examples/calibration-sensitivity.json").read_text(encoding="utf-8"))
    yield "translation-and-scale", original, True
    empty = copy.deepcopy(original); empty["modes"] = []; yield "zero-rank", empty, False
    zero = copy.deepcopy(original); zero["modes"] = [[0] * 9]; yield "zero-mode", zero, False
    for amplitude in [1e-100, 1e100]:
        value = copy.deepcopy(original)
        value["modes"] = [[0, 0, amplitude, 0, 0, 2 * amplitude, 0, 0, 0]]
        yield "translation-{}".format(amplitude), value, False
    gauge = copy.deepcopy(original); gauge["modes"] = [original["calibration"]["matrix"]]
    yield "scale-gauge-null", gauge, True
    rng = np.random.default_rng(SEED)
    for index in range(16):
        h = [0.1 + rng.uniform(-0.02, 0.02), rng.uniform(-0.01, 0.01), rng.uniform(-1, 1),
             rng.uniform(-0.01, 0.01), 0.12 + rng.uniform(-0.02, 0.02), rng.uniform(-1, 1),
             rng.uniform(-0.001, 0.001), rng.uniform(-0.001, 0.001), 1.0]
        rank = [1, 2, 8, 9, 16, 32][index % 6]
        modes = (rng.normal(size=(rank, 9)) * np.array([1e-4, 1e-4, 0.01, 1e-4, 1e-4, 0.01, 1e-6, 1e-6, 1e-4])).tolist()
        points = [([0, 0], [100, 100]), ([100, 0], [0, 100]), ([25, 50], [25, 50])]
        points += [(rng.uniform(0, 100, 2).tolist(), rng.uniform(0, 100, 2).tolist()) for _ in range(13)]
        yield "perspective-{}-rank-{}".format(index, rank), {
            "calibration": {"matrix": h, "roi": original["calibration"]["roi"], "max_meters_per_pixel": 1},
            "modes": modes,
            "probes": [{"probe_id": "pair-{}".format(i), "first_pixel": a, "second_pixel": b}
                       for i, (a, b) in enumerate(points)]}, True
    maximum = copy.deepcopy(original)
    maximum["modes"] = [original["modes"][0]] * 32
    maximum["probes"] = [dict(original["probes"][0], probe_id="maximum-{}".format(i)) for i in range(256)]
    yield "maximum-32x256", maximum, False


def web_reference(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/calibration-sensitivity.test.mjs"]
    environment = dict(os.environ, MOONGROUND_CLI=str(binary))
    process = subprocess.run(command, cwd=str(ROOT), env=environment, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, encoding="utf-8", timeout=180)
    assert process.returncode == 0, process.stdout
    summary = {key: int(value) for key, value in re.findall(r"^# (tests|pass|fail) (\d+)$", process.stdout, re.M)}
    assert summary == {"tests": 7, "pass": 7, "fail": 0}, process.stdout
    return {"status": "passed", "summary": summary, "command": " ".join(command),
            "source_sha256": hashlib.sha256((ROOT / "web/calibration-sensitivity.test.mjs").read_bytes()).hexdigest(),
            "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
            "stdout_sha256": hashlib.sha256(process.stdout.encode("utf-8")).hexdigest(),
            "node": subprocess.check_output(["node", "--version"], text=True).strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/calibration-sensitivity-results.json")
    args = parser.parse_args(); binary = args.binary.resolve(); started = time.perf_counter()
    stats = dict(requests=0, pairs=0, scalars=0, maximum_absolute_error=0.0,
                 maximum_tolerance_fraction=0.0, finite_difference_vectors=0,
                 maximum_finite_difference_absolute_error=0.0)
    cases = []
    for name, value, differences in fixtures():
        result = check_request(binary, value, stats, differences)
        cases.append({"case": name, "modes": len(value["modes"]), "pairs": len(value["probes"]),
                      "output_utf16": len(encode(result).encode("utf-16-le")) // 2})
    result = {"status": "passed", "seed": SEED,
              "command": " ".join(shlex.quote(v) for v in [sys.executable] + sys.argv),
              "toolchain": subprocess.check_output(["moon", "version", "--all", "--no-path"], text=True).strip(),
              "pinned_moon_home": os.environ.get("MOON_HOME"),
              "python": platform.python_version(), "numpy": np.__version__,
              "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "reference": "Exact Fraction derivative of projective quotient; exact shared marginal/cross/relative moments; floating comparison tolerances, no certified error bound; secondary nonlinear central differences",
              "response_tolerance": "256*binary64_epsilon*sum(abs(original derivative terms)); moment tolerances propagate response tolerances plus 256*epsilon*sum(abs(products))",
              "finite_difference": {"step": 2 ** -12, "rtol": 2e-5, "atol": 2e-9},
              "statistics": stats, "cases": cases}
    if args.web:
        result["web_interchange"] = web_reference(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(json.dumps({"status": result["status"], "statistics": stats, "output": str(args.output)}, ensure_ascii=True))


if __name__ == "__main__":
    main()
