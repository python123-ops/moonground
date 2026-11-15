#!/usr/bin/env python3
"""Independent Fraction derivatives and 110-digit Decimal circular-angle reference.

Differentiate projective quotients as exact rational numbers, then form angular
responses from the unnormalized determinant divided by squared length. Decimal
atan uses a convergent reduced Taylor series and Machin's pi identity, independent
of the production atan2. Nonlinear central differences use wrapped residuals.
The comparison tolerances are numerical test criteria, not certified error bounds.
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
SEED = 20261117
EPS = Decimal.from_float(2.0 ** -52)
TINY = Decimal("1e-300")


def dec(value):
    if isinstance(value, Fraction):
        return Decimal(value.numerator) / Decimal(value.denominator)
    return Decimal.from_float(float(value))


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def atan_positive(value):
    assert value >= 0
    factor = 1
    while value > Decimal("0.125"):
        value /= 1 + (1 + value * value).sqrt()
        factor *= 2
    total, power, odd = Decimal(0), value, 1
    while True:
        previous = total
        total += power / odd
        if total == previous:
            return factor * total
        power *= -value * value
        odd += 2


def decimal_pi():
    return 16 * atan_positive(Decimal(1) / 5) - 4 * atan_positive(Decimal(1) / 239)


def atan2(y, x, pi):
    if y == 0:
        return pi if x < 0 else Decimal(0)
    if x == 0:
        return pi / 2 if y > 0 else -pi / 2
    value = atan_positive(abs(y / x))
    if x < 0:
        value = pi - value
    return value if y > 0 else -value


def native(binary, request):
    process = subprocess.run([str(binary), "--calibration-angle"], input=encode(request).encode("utf-8"),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    assert process.returncode == 0, process.stderr.decode("utf-8", "replace")
    assert not process.stderr and process.stdout.endswith(b"\n")
    return json.loads(process.stdout)


def exact_direction(matrix, modes, segment, pi):
    a, da, ea = projection_reference.exact_responses(matrix, modes, segment[0])
    b, db, eb = projection_reference.exact_responses(matrix, modes, segment[1])
    d = [b[i] - a[i] for i in range(2)]
    squared = d[0] ** 2 + d[1] ** 2
    assert squared > 0
    length = dec(squared).sqrt()
    direction = [dec(v) / length for v in d]
    position_scale = max([abs(dec(v)) for v in a + b] + [length, TINY])
    length_error = 1024 * EPS * position_scale
    responses, errors = [], []
    for ra, rb, ex, ey in zip(da, db, ea, eb):
        delta = [rb[i] - ra[i] for i in range(2)]
        response = (d[0] * delta[1] - d[1] * delta[0]) / squared
        derivative_scale = sum(abs(dec(v)) for v in ra + rb)
        error = (16 * sum(dec(v) for v in ex + ey) + 4096 * EPS * derivative_scale) / length
        error += 16 * length_error / length ** 2 * sum(abs(dec(v)) for v in delta)
        responses.append(dec(response)); errors.append(max(error, TINY))
    return dict(a=list(map(dec, a)), b=list(map(dec, b)), d=list(map(dec, d)), length=length,
                direction=direction, angle=atan2(dec(d[1]), dec(d[0]), pi),
                responses=responses, errors=errors, length_error=length_error,
                angle_error=8 * length_error / length + 1024 * EPS)


def check(actual, expected, tolerance, unit, stats):
    assert isinstance(actual, (int, float)) and math.isfinite(actual)
    error, tolerance = abs(dec(actual) - expected), max(tolerance, TINY)
    assert error <= tolerance, (unit, actual, str(expected), str(error), str(tolerance))
    stats["scalars"] += 1
    stats["maximum_absolute_error_by_unit"][unit] = max(stats["maximum_absolute_error_by_unit"][unit], float(error))
    stats["maximum_tolerance_fraction"] = max(stats["maximum_tolerance_fraction"], float(error / tolerance))


def check_angle(actual, expected, tolerance, pi, stats):
    assert -math.pi < actual <= math.pi
    residual = dec(actual) - expected
    if residual > pi:
        residual -= 2 * pi
    if residual < -pi:
        residual += 2 * pi
    check(float(residual), Decimal(0), tolerance, "rad", stats)


def dot(a, b):
    return sum((x * y for x, y in zip(a, b)), Decimal(0))


def dot_error(a, b, ea, eb):
    return sum((abs(x) * dy + abs(y) * dx + dx * dy for x, y, dx, dy in zip(a, b, ea, eb)), Decimal(0)) + 1024 * EPS * sum((abs(x * y) for x, y in zip(a, b)), Decimal(0))


def check_moments(output, values, errors, stats):
    assert len(output["mode_responses_rad"]) == len(values)
    for got, want, error in zip(output["mode_responses_rad"], values, errors):
        check(got, want, error, "rad", stats)
    variance, tolerance = dot(values, values), dot_error(values, values, errors, errors)
    check(output["contribution_rad2"], variance, tolerance, "rad2", stats)
    check(output["std_rad"], variance.sqrt(), tolerance.sqrt() + 1024 * EPS * variance.sqrt(), "rad", stats)


def check_request(binary, request, differences, pi, stats):
    result = native(binary, request)
    matrix = request["calibration"]["matrix"]
    scale = max(abs(v) for v in matrix)
    matrix = [float(v) / scale for v in matrix]
    assert result["normalized_matrix"] == matrix
    assert result["schema_version"] == "0.1.0" and result["kind"] == "calibration_angle_comparison"
    assert result["evidence_scope"] == "first_order_shared_homography_angular_tangents"
    assert result["angle_convention"] == "second_relative_to_first_ccw"
    assert result["mode_count"] == len(request["modes"])
    assert len(result["comparisons"]) == len(request["comparisons"])
    for probe, row in zip(request["comparisons"], result["comparisons"]):
        assert row["probe_id"] == probe["probe_id"]
        first = exact_direction(matrix, request["modes"], probe["first_segment"], pi)
        second = exact_direction(matrix, request["modes"], probe["second_segment"], pi)
        for output, reference in [(row["first"], first), (row["second"], second)]:
            for name, values in [("first_position_m", reference["a"]), ("second_position_m", reference["b"])]:
                assert len(output[name]) == 2
                for got, want in zip(output[name], values):
                    check(got, want, 512 * EPS * max(abs(want), Decimal(1)), "m", stats)
            check(output["distance_m"], reference["length"], reference["length_error"], "m", stats)
            for got, want in zip(output["direction"], reference["direction"]):
                check(got, want, 8 * reference["length_error"] / reference["length"], "dimensionless", stats)
            check_angle(output["angle_rad"], reference["angle"], reference["angle_error"], pi, stats)
            check_moments(output, reference["responses"], reference["errors"], stats)
        a, b, ea, eb = first["responses"], second["responses"], first["errors"], second["errors"]
        delta, error = [y - x for x, y in zip(a, b)], [x + y for x, y in zip(ea, eb)]
        cross = first["d"][0] * second["d"][1] - first["d"][1] * second["d"][0]
        cosine = dot(first["d"], second["d"])
        angle = atan2(cross, cosine, pi)
        check_angle(row["angle_rad"], angle, first["angle_error"] + second["angle_error"], pi, stats)
        if probe["probe_id"] == "near-parallel":
            assert angle > 0 and row["angle_rad"] > 0
        check(row["cross_contribution_rad2"], dot(a, b), dot_error(a, b, ea, eb), "rad2", stats)
        check_moments(row, delta, error, stats)
        if differences:
            h = np.asarray(matrix).reshape(3, 3)
            points = np.array([point + [1.0] for segment in [probe["first_segment"], probe["second_segment"]] for point in segment])
            def nonlinear(mapping):
                projected = points @ mapping.T
                projected = projected[:, :2] / projected[:, 2, None]
                u, v = projected[1] - projected[0], projected[3] - projected[2]
                return np.array([np.arctan2(u[1], u[0]), np.arctan2(v[1], v[0]), np.arctan2(u[0] * v[1] - u[1] * v[0], u @ v)])
            step = 2.0 ** -12
            for index, mode in enumerate(request["modes"]):
                m = np.asarray(mode).reshape(3, 3)
                residual = nonlinear(h + step * m) - nonlinear(h - step * m)
                numerical = np.arctan2(np.sin(residual), np.cos(residual)) / (2 * step)
                expected = np.array(list(map(float, [a[index], b[index], delta[index]])))
                absolute_error = float(np.max(np.abs(numerical - expected)))
                assert np.allclose(numerical, expected, rtol=2e-5, atol=5e-8), (numerical, expected)
                stats["finite_difference_vectors"] += 1
                stats["maximum_finite_difference_absolute_error_rad"] = max(stats["maximum_finite_difference_absolute_error_rad"], absolute_error)
        stats["comparisons"] += 1
    stats["requests"] += 1
    return result


def fixtures():
    original = json.loads((ROOT / "examples/calibration-angle.json").read_text(encoding="utf-8"))
    yield "shared-rotation-scale-translation", original, True
    empty = copy.deepcopy(original); empty["modes"] = []; yield "zero-rank", empty, False
    for amplitude in [1e-100, 1e100]:
        value = copy.deepcopy(original); value["modes"] = [[0, 0, amplitude, 0, 0, 2 * amplitude, 0, 0, 0]]
        yield "translation-{}".format(amplitude), value, False
    gauge = copy.deepcopy(original); gauge["modes"] = [[x * 0.125 for x in original["calibration"]["matrix"]]]
    yield "homogeneous-gauge-mode", gauge, True
    cut = dict(calibration=dict(matrix=[1, 0, 0, 0, 1, 0, 0, 0, 1], roi=original["calibration"]["roi"], max_meters_per_pixel=2),
               modes=[[0, 0, 0, 0, 0, 0, 0.001, 0, 0]], comparisons=[
                   dict(probe_id="exact-cut-nonzero-tangent", first_segment=[[0, 0], [4, 0]], second_segment=[[10, 10], [6, 10]]),
                   dict(probe_id="above-cut", first_segment=[[0, 0], [4, 0]], second_segment=[[10, 10], [6, 10.00000001]]),
                   dict(probe_id="below-cut", first_segment=[[0, 0], [4, 0]], second_segment=[[10, 10], [6, 9.99999999]])])
    yield "circular-cut", cut, True
    small = copy.deepcopy(cut); small["modes"] = []
    small["comparisons"] = [dict(probe_id="near-parallel", first_segment=[[0, 0], [4, 3]], second_segment=[[0, 0], [8, 6.000000000000001]])]
    yield "tiny-positive-angle", small, False
    huge = copy.deepcopy(small)
    huge["calibration"]["roi"] = [[0, 0], [1e200, 0], [1e200, 1e200], [0, 1e200]]
    huge["comparisons"] = [dict(probe_id="different-scales", first_segment=[[0, 0], [1e200, 0]], second_segment=[[0, 0], [0, 1e-200]])]
    yield "different-segment-scales", huge, False
    rng = np.random.default_rng(SEED)
    for index in range(18):
        h = [0.1 + rng.uniform(-0.02, 0.02), rng.uniform(-0.01, 0.01), rng.uniform(-1, 1),
             rng.uniform(-0.01, 0.01), 0.12 + rng.uniform(-0.02, 0.02), rng.uniform(-1, 1),
             rng.uniform(-0.001, 0.001), rng.uniform(-0.001, 0.001), 1.0]
        rank = [1, 2, 8, 9, 16, 32][index % 6]
        modes = (rng.normal(size=(rank, 9)) * np.array([1e-4, 1e-4, 0.01, 1e-4, 1e-4, 0.01, 1e-6, 1e-6, 1e-4])).tolist()
        probes = [dict(probe_id="diagonals", first_segment=[[0, 0], [100, 100]], second_segment=[[100, 0], [0, 100]]),
                  dict(probe_id="same-reversed", first_segment=[[25, 25], [75, 50]], second_segment=[[75, 50], [25, 25]])]
        probes += [dict(probe_id="random-{}".format(i), first_segment=rng.uniform(0, 100, (2, 2)).tolist(), second_segment=rng.uniform(0, 100, (2, 2)).tolist()) for i in range(14)]
        yield "perspective-{}-rank-{}".format(index, rank), dict(calibration=dict(matrix=h, roi=original["calibration"]["roi"], max_meters_per_pixel=1), modes=modes, comparisons=probes), True
    maximum = copy.deepcopy(original)
    maximum["modes"] = [original["modes"][0]] * 32
    maximum["comparisons"] = [dict(original["comparisons"][0], probe_id="maximum-{}".format(i)) for i in range(256)]
    yield "maximum-32x256", maximum, False


def web_reference(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/calibration-angle.test.mjs"]
    process = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding="utf-8", timeout=180)
    assert process.returncode == 0, process.stdout
    summary = {key: int(value) for key, value in re.findall(r"^# (tests|pass|fail) (\d+)$", process.stdout, re.M)}
    assert summary == {"tests": 8, "pass": 8, "fail": 0}, process.stdout
    return dict(status="passed", summary=summary, command=" ".join(command),
                source_sha256=hashlib.sha256((ROOT / "web/calibration-angle.test.mjs").read_bytes()).hexdigest(),
                bridge_sha256=hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
                stdout_sha256=hashlib.sha256(process.stdout.encode("utf-8")).hexdigest(),
                node=subprocess.check_output(["node", "--version"], text=True).strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True); parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/calibration-angle-results.json")
    args = parser.parse_args(); binary = args.binary.resolve(); started = time.perf_counter()
    stats = dict(requests=0, comparisons=0, scalars=0, maximum_absolute_error_by_unit=dict(m=0.0, rad=0.0, rad2=0.0, dimensionless=0.0),
                 maximum_tolerance_fraction=0.0, finite_difference_vectors=0, maximum_finite_difference_absolute_error_rad=0.0)
    cases = []
    with localcontext() as context:
        context.prec = 110
        for name, request, differences in fixtures():
            # Preserve the exact terminating decimals of the 1e+/-200 binary64
            # inputs, so reference rounding does not dominate absolute m error.
            context.prec = 800 if name == "different-segment-scales" else 110
            pi = decimal_pi()
            assert abs(float(pi) - math.pi) < 1e-15
            result = check_request(binary, request, differences, pi, stats)
            cases.append(dict(case=name, modes=len(request["modes"]), comparisons=len(request["comparisons"]),
                              decimal_precision=context.prec,
                              encoded_json_utf16=len(encode(result).encode("utf-16-le")) // 2))
    result = dict(status="passed", seed=SEED, command=" ".join(shlex.quote(v) for v in [sys.executable] + sys.argv),
                  toolchain=subprocess.check_output(["moon", "version", "--all", "--no-path"], text=True).strip(),
                  pinned_moon_home=os.environ.get("MOON_HOME"), python=platform.python_version(), numpy=np.__version__,
                  source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  projection_reference_sha256=hashlib.sha256((ROOT / "validation/calibration_sensitivity_verify.py").read_bytes()).hexdigest(),
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  reference="Fraction projective quotient and angular derivatives; 110-digit Decimal norms, reduced-series atan, Machin pi and circular shared moments; 800 digits for the 1e+/-200 segment-scale case",
                  error_scope="Numerical errors are recorded separately by unit, not physical angle or length accuracy. Angles are compared modulo 2*pi; contribution errors are local first-order numerical checks.",
                  tolerance="Endpoint and length scale conditioning propagate into angular response tolerances; contrast responses are formed before moments. Formulas are in the reference source; these are not certified bounds.",
                  finite_difference=dict(step=2 ** -12, rtol=2e-5, atol_rad=5e-8, residual="atan2(sin(plus-minus),cos(plus-minus))"),
                  statistics=stats, cases=cases)
    if args.web:
        result["web_interchange"] = web_reference(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(json.dumps(dict(status="passed", statistics=stats, output=str(args.output)), ensure_ascii=True))


if __name__ == "__main__":
    main()
