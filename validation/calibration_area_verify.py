#!/usr/bin/env python3
"""Independent exact cyclic reference for shared convex ground area contrasts.

The oracle differentiates the full cyclic shoelace using exact Fractions, rather
than the library's anchored triangle fan. Decimal arithmetic checks moments and
standard deviations; nonlinear centered-shoelace differences check derivatives.
Conditioning tolerances below are fixture acceptance tolerances, not public
error bounds or estimates of physical measurement accuracy.
"""
import argparse
import copy
from decimal import Decimal, localcontext
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
import calibration_sensitivity_verify as projection_reference

ROOT = Path(__file__).resolve().parents[1]
SEED = 20261118
EPS = Decimal.from_float(2.0 ** -52)
TINY = Decimal("1e-320")


def dec(value):
    if isinstance(value, Fraction):
        return Decimal(value.numerator) / Decimal(value.denominator)
    return Decimal.from_float(float(value))


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def native(binary, request):
    result = subprocess.run([str(binary), "--calibration-area"], input=encode(request).encode("utf-8"),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    assert result.returncode == 0, result.stderr.decode("utf-8", "replace")
    assert not result.stderr and result.stdout.endswith(b"\n")
    return json.loads(result.stdout)


def cross(a, b):
    return a[0] * b[1] - a[1] * b[0]


def half_cross_error(a, b, ea, eb):
    return (abs(a[0]) * eb[1] + abs(b[1]) * ea[0] + ea[0] * eb[1]
            + abs(a[1]) * eb[0] + abs(b[0]) * ea[1] + ea[1] * eb[0]
            + 2048 * EPS * (abs(a[0] * b[1]) + abs(a[1] * b[0]))) / 2


def exact_polygon(matrix, modes, polygon):
    projected = [projection_reference.exact_responses(matrix, modes, p) for p in polygon]
    positions = [p[0] for p in projected]
    signed = sum((cross(p, positions[(i + 1) % len(positions)]) for i, p in enumerate(positions)), Fraction(0)) / 2
    assert signed != 0
    orientation = 1 if signed > 0 else -1
    responses = []
    for mode in range(len(modes)):
        derivative = sum((cross(projected[i][1][mode], positions[(i + 1) % len(positions)])
                          + cross(p, projected[(i + 1) % len(positions)][1][mode])
                          for i, p in enumerate(positions)), Fraction(0)) / 2
        responses.append(dec(orientation * derivative))
    # Independent quotient term scales include cancellation in either numerator
    # and in the projective denominator. Anchor offsets are used only to estimate
    # conditioning tolerances; the golden area/derivatives above remain cyclic.
    errors = []
    for point, position in zip(polygon, positions):
        homogeneous = list(map(Fraction, point)) + [Fraction(1)]
        rows = [sum(Fraction(matrix[3 * axis + j]) * homogeneous[j] for j in range(3)) for axis in range(3)]
        denominator_scale = sum(abs(Fraction(matrix[6 + j]) * homogeneous[j]) for j in range(3))
        errors.append([512 * EPS * dec(
            sum(abs(Fraction(matrix[3 * axis + j]) * homogeneous[j] / rows[2]) for j in range(3))
            + abs(position[axis]) * denominator_scale / abs(rows[2])) for axis in range(2)])
    points = [list(map(dec, p)) for p in positions]
    offsets = [[p[j] - points[0][j] for j in range(2)] for p in points]
    offset_errors = [[e[j] + errors[0][j] + 512 * EPS * abs(offsets[i][j]) for j in range(2)] for i, e in enumerate(errors)]
    area_error = sum((half_cross_error(offsets[i], offsets[i + 1], offset_errors[i], offset_errors[i + 1])
                      for i in range(1, len(points) - 1)), Decimal(0))
    response_errors = []
    for mode in range(len(modes)):
        r = [list(map(dec, p[1][mode])) for p in projected]
        er = [list(map(dec, p[2][mode])) for p in projected]
        delta = [[p[j] - r[0][j] for j in range(2)] for p in r]
        ed = [[e[j] + er[0][j] + 512 * EPS * abs(delta[i][j]) for j in range(2)] for i, e in enumerate(er)]
        response_errors.append(sum((
            half_cross_error(delta[i], offsets[i + 1], ed[i], offset_errors[i + 1])
            + half_cross_error(offsets[i], delta[i + 1], offset_errors[i], ed[i + 1])
            for i in range(1, len(points) - 1)), Decimal(0)))
    return dict(positions=points, position_errors=errors, signed=dec(signed), area=dec(abs(signed)),
                responses=responses, errors=response_errors, area_error=area_error)


def check(actual, expected, tolerance, unit, stats):
    assert isinstance(actual, (int, float)) and math.isfinite(actual)
    error, tolerance = abs(dec(actual) - expected), max(tolerance, TINY)
    assert error <= tolerance, (unit, actual, str(expected), str(error), str(tolerance))
    stats["scalars"] += 1
    stats["maximum_absolute_error_by_unit"][unit] = max(stats["maximum_absolute_error_by_unit"][unit], float(error))
    stats["maximum_tolerance_fraction"] = max(stats["maximum_tolerance_fraction"], float(error / tolerance))


def dot(a, b):
    return sum((x * y for x, y in zip(a, b)), Decimal(0))


def dot_error(a, b, ea, eb):
    return sum((abs(x) * dy + abs(y) * dx + dx * dy for x, y, dx, dy in zip(a, b, ea, eb)), Decimal(0)) + 2048 * EPS * sum((abs(x * y) for x, y in zip(a, b)), Decimal(0))


def check_moments(output, values, errors, stats, prefix="", ratio=False):
    response_key = prefix + ("mode_responses" if ratio else "mode_responses_m2")
    variance_key = prefix + ("contribution" if ratio else "contribution_m4")
    std_key = prefix + ("std" if ratio else "std_m2")
    unit, square_unit = ("dimensionless", "dimensionless") if ratio else ("m2", "m4")
    assert len(output[response_key]) == len(values)
    for got, want, error in zip(output[response_key], values, errors):
        check(got, want, error, unit, stats)
    variance, tolerance = dot(values, values), dot_error(values, values, errors, errors)
    check(output[variance_key], variance, tolerance, square_unit, stats)
    check(output[std_key], variance.sqrt(), tolerance.sqrt() + 2048 * EPS * variance.sqrt(), unit, stats)


def check_request(binary, request, differences, stats):
    result = native(binary, request)
    matrix = request["calibration"]["matrix"]
    scale = max(abs(v) for v in matrix)
    matrix = [float(v) / scale for v in matrix]
    assert result["normalized_matrix"] == matrix and result["mode_count"] == len(request["modes"])
    assert result["schema_version"] == "0.1.0" and result["kind"] == "calibration_area_comparison"
    assert result["evidence_scope"] == "first_order_shared_homography_area_contrasts"
    assert len(result["comparisons"]) == len(request["comparisons"])
    cache = {}
    def polygon_reference(vertices):
        key = tuple(tuple(p) for p in vertices)
        if key not in cache:
            cache[key] = exact_polygon(matrix, request["modes"], vertices)
        return cache[key]
    for probe, row in zip(request["comparisons"], result["comparisons"]):
        assert row["probe_id"] == probe["probe_id"]
        first, second = [polygon_reference(probe[key]) for key in ["first_polygon", "second_polygon"]]
        for output, reference in [(row["first"], first), (row["second"], second)]:
            assert len(output["positions_m"]) == len(reference["positions"])
            for point, want, error in zip(output["positions_m"], reference["positions"], reference["position_errors"]):
                for got, target, tolerance in zip(point, want, error):
                    check(got, target, tolerance, "m", stats)
            for name in ["signed", "area"]:
                check(output["signed_area_m2" if name == "signed" else "area_m2"], reference[name], reference["area_error"], "m2", stats)
            check_moments(output, reference["responses"], reference["errors"], stats)
        a, b, ea, eb = first["responses"], second["responses"], first["errors"], second["errors"]
        delta, ed = [x - y for x, y in zip(a, b)], [x + y for x, y in zip(ea, eb)]
        ratio = first["area"] / second["area"]
        ratio_error = (first["area_error"] + abs(ratio) * second["area_error"]) / second["area"] + 2048 * EPS * abs(ratio)
        ratio_responses = [(x - ratio * y) / second["area"] for x, y in zip(a, b)]
        ratio_errors = [(x + abs(ratio) * y + abs(v) * ratio_error + abs(r) * second["area_error"]
                         + 2048 * EPS * (abs(u) + abs(ratio * v))) / second["area"]
                        for u, v, r, x, y in zip(a, b, ratio_responses, ea, eb)]
        check(row["cross_contribution_m4"], dot(a, b), dot_error(a, b, ea, eb), "m4", stats)
        check(row["difference_m2"], first["area"] - second["area"], first["area_error"] + second["area_error"], "m2", stats)
        check_moments(row, delta, ed, stats, prefix="difference_")
        check(row["ratio"], ratio, ratio_error, "dimensionless", stats)
        check_moments(row, ratio_responses, ratio_errors, stats, prefix="ratio_", ratio=True)
        if differences:
            h = np.asarray(matrix).reshape(3, 3)
            polygons = [np.array([p + [1.0] for p in probe[key]]) for key in ["first_polygon", "second_polygon"]]
            def nonlinear(mapping):
                areas = []
                for polygon in polygons:
                    points = polygon @ mapping.T
                    points = points[:, :2] / points[:, 2, None]
                    points -= points.mean(axis=0)
                    areas.append(abs(np.sum(points[:, 0] * np.roll(points[:, 1], -1) - points[:, 1] * np.roll(points[:, 0], -1))) / 2)
                return np.array(areas + [areas[0] - areas[1], areas[0] / areas[1]])
            step = 2.0 ** -12
            for index, mode in enumerate(request["modes"]):
                m = np.asarray(mode).reshape(3, 3)
                numerical = (nonlinear(h + step * m) - nonlinear(h - step * m)) / (2 * step)
                expected = np.array(list(map(float, [a[index], b[index], delta[index], ratio_responses[index]])))
                assert np.allclose(numerical, expected, rtol=2e-5, atol=5e-8), (numerical, expected)
                stats["finite_difference_vectors"] += 1
                for unit, residual in [("m2", np.max(np.abs(numerical[:3] - expected[:3]))), ("dimensionless", abs(numerical[3] - expected[3]))]:
                    stats["maximum_finite_difference_absolute_error_by_unit"][unit] = max(stats["maximum_finite_difference_absolute_error_by_unit"][unit], float(residual))
        stats["comparisons"] += 1
    stats["requests"] += 1
    return result


def square(x, y, side):
    return [[x, y], [x + side, y], [x + side, y + side], [x, y + side]]


def fixtures():
    original = json.loads((ROOT / "examples/calibration-area.json").read_text(encoding="utf-8"))
    yield "shared-scale-and-translation", original, True
    empty = copy.deepcopy(original); empty["modes"] = []; yield "zero-rank", empty, False
    empty["comparisons"] = []; yield "empty", empty, False
    for amplitude in [1e-100, 1e100]:
        value = copy.deepcopy(original); value["modes"] = [[0, 0, amplitude, 0, 0, 2 * amplitude, 0, 0, 0]]
        yield "translation-{}".format(amplitude), value, False
    gauge = copy.deepcopy(original); gauge["modes"] = [[x * 0.125 for x in original["calibration"]["matrix"]]]
    yield "homogeneous-gauge", gauge, True
    negative = dict(calibration=dict(matrix=[1, 0, 0, 0, 1, 0, 0, 0, 1], roi=square(0, 0, 100), max_meters_per_pixel=2),
                    modes=[[0.125, 0, 0, 0, 0.125, 0, 0.015625, 0, 0]], comparisons=[
                        dict(probe_id="opposite-responses", first_polygon=square(0, 0, 4), second_polygon=square(8, 0, 4))])
    yield "negative-correlation", negative, True
    rotation = copy.deepcopy(negative); rotation["modes"] = [[0, -0.125, 0, 0.125, 0, 0, 0, 0, 0]]
    yield "rotation-first-order-zero", rotation, True
    reflection = copy.deepcopy(original); reflection["calibration"]["matrix"][0] *= -1; reflection["modes"][1][0] *= -1
    yield "reflection-and-winding", reflection, True
    far = copy.deepcopy(negative); far["calibration"]["roi"] = square(0, 0, 1e12 + 16)
    far["modes"] = [[0, 0, 1, 0, 0, 2, 0, 0, 0]]
    far["comparisons"] = [dict(probe_id="far-patch", first_polygon=square(1e12, 1e12, 4), second_polygon=square(1e12, 1e12, 8))]
    yield "large-origin-small-patches", far, False
    for side in [1.5e154, 1e-150]:
        value = copy.deepcopy(negative); value["modes"] = []
        value["calibration"]["roi"] = square(0, 0, 1.5e154)
        triangle = [[0, 0], [side, 0], [0, side]]
        value["comparisons"] = [dict(probe_id="same-scale", first_polygon=triangle, second_polygon=triangle)]
        yield "extreme-area-{}".format(side), value, False
    rng = np.random.default_rng(SEED)
    for index in range(18):
        h = [0.1 + rng.uniform(-0.02, 0.02), rng.uniform(-0.01, 0.01), rng.uniform(-1, 1),
             rng.uniform(-0.01, 0.01), 0.12 + rng.uniform(-0.02, 0.02), rng.uniform(-1, 1),
             rng.uniform(-0.001, 0.001), rng.uniform(-0.001, 0.001), 1.0]
        rank = [1, 2, 8, 9, 16, 32][index % 6]
        modes = (rng.normal(size=(rank, 9)) * np.array([1e-4, 1e-4, 0.01, 1e-4, 1e-4, 0.01, 1e-6, 1e-6, 1e-4])).tolist()
        probes = []
        for i in range(12):
            polygons = []
            for j in range(2):
                n = 3 + (index + i + j) % 7
                angles = np.arange(n) * 2 * np.pi / n + rng.uniform(0, 2 * np.pi)
                center = rng.uniform(30, 70, 2); radii = rng.uniform(5, 25, 2)
                polygon = (center + np.column_stack([np.cos(angles), np.sin(angles)]) * radii).tolist()
                if (i + j) % 2:
                    polygon.reverse()
                polygons.append(polygon)
            probes.append(dict(probe_id="random-{}".format(i), first_polygon=polygons[0], second_polygon=polygons[1]))
        yield "perspective-{}-rank-{}".format(index, rank), dict(calibration=dict(matrix=h, roi=square(0, 0, 100), max_meters_per_pixel=1), modes=modes, comparisons=probes), True
    maximum = copy.deepcopy(original)
    maximum["modes"] = [original["modes"][1]] * 32
    polygon = [[50 + 30 * math.cos(i * math.pi / 32), 50 + 30 * math.sin(i * math.pi / 32)] for i in range(64)]
    maximum["comparisons"] = [dict(probe_id="maximum-{}".format(i), first_polygon=polygon, second_polygon=polygon) for i in range(64)]
    yield "maximum-32x64x64", maximum, False


def web_reference(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/calibration-area.test.mjs"]
    process = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding="utf-8", timeout=180)
    assert process.returncode == 0, process.stdout
    summary = {key: int(value) for key, value in re.findall(r"^# (tests|pass|fail) (\d+)$", process.stdout, re.M)}
    assert summary == {"tests": 8, "pass": 8, "fail": 0}, process.stdout
    return dict(status="passed", summary=summary, command=" ".join(command),
                source_sha256=hashlib.sha256((ROOT / "web/calibration-area.test.mjs").read_bytes()).hexdigest(),
                bridge_sha256=hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
                stdout_sha256=hashlib.sha256(process.stdout.encode("utf-8")).hexdigest(),
                node=subprocess.check_output(["node", "--version"], text=True).strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True); parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/calibration-area-results.json")
    args = parser.parse_args(); binary = args.binary.resolve(); started = time.perf_counter()
    stats = dict(requests=0, comparisons=0, scalars=0, maximum_absolute_error_by_unit=dict(m=0.0, m2=0.0, m4=0.0, dimensionless=0.0),
                 maximum_tolerance_fraction=0.0, finite_difference_vectors=0,
                 maximum_finite_difference_absolute_error_by_unit=dict(m2=0.0, dimensionless=0.0))
    cases = []
    with localcontext() as context:
        for name, request, differences in fixtures():
            context.prec = 800 if name.startswith("extreme-area-") else 110
            result = check_request(binary, request, differences, stats)
            cases.append(dict(case=name, modes=len(request["modes"]), comparisons=len(request["comparisons"]),
                              decimal_precision=context.prec, encoded_json_utf16=len(encode(result).encode("utf-16-le")) // 2))
    result = dict(status="passed", seed=SEED, command=" ".join(shlex.quote(v) for v in [sys.executable] + sys.argv),
                  toolchain=subprocess.check_output(["moon", "version", "--all", "--no-path"], text=True).strip(),
                  pinned_moon_home=os.environ.get("MOON_HOME"), python=platform.python_version(), numpy=np.__version__,
                  source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  projection_reference_sha256=hashlib.sha256((ROOT / "validation/calibration_sensitivity_verify.py").read_bytes()).hexdigest(),
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  reference="Exact Fraction full cyclic shoelace and differentiated rational projective quotients; 110-digit Decimal moments and square roots, 800 digits for extreme areas",
                  error_scope="Numerical errors are recorded separately by unit, not physical area accuracy. Only explicit shared first-order calibration mode contributions are compared.",
                  tolerance="Quotient term scales propagate through anchor offsets only for conditioning tolerances; the exact golden area and derivatives use the full cyclic formula. Tolerances are fixture checks, not certified bounds.",
                  finite_difference=dict(step=2 ** -12, rtol=2e-5, atol=5e-8, formula="Nonlinear projective mapping followed by mean-centered cyclic shoelace; areas, difference and ratio"),
                  statistics=stats, cases=cases)
    if args.web:
        result["web_interchange"] = web_reference(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(json.dumps(dict(status="passed", statistics=stats, output=str(args.output)), ensure_ascii=True))


if __name__ == "__main__":
    main()
