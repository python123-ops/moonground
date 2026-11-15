#!/usr/bin/env python3
"""Independent Decimal/Fraction reference for shared calibrated length contrasts.

Differentiate the rational homography quotient exactly, then evaluate Euclidean
lengths and their derivatives with 110-digit Decimal arithmetic. Compare the
binary64 implementation using scale-aware numerical tolerances; these are test
tolerances, not certified public error bounds. Nonlinear central differences
separately check distance, difference and ratio derivatives.
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
SEED = 20261116
EPS = Decimal(2) ** -52
TINY = Decimal("1e-300")


def dec(value):
    if isinstance(value, Fraction):
        return Decimal(value.numerator) / Decimal(value.denominator)
    return Decimal.from_float(float(value))


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def native(binary, request):
    result = subprocess.run([str(binary), "--calibration-distance"], input=encode(request).encode("utf-8"),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    assert result.returncode == 0, result.stderr.decode("utf-8", "replace")
    assert not result.stderr and result.stdout.endswith(b"\n")
    return json.loads(result.stdout)


def exact_distance(matrix, modes, segment):
    a, da, ea = projection_reference.exact_responses(matrix, modes, segment[0])
    b, db, eb = projection_reference.exact_responses(matrix, modes, segment[1])
    a, b = list(map(dec, a)), list(map(dec, b))
    d = [b[i] - a[i] for i in range(2)]
    length = (d[0] ** 2 + d[1] ** 2).sqrt()
    assert length > 0
    direction = [v / length for v in d]
    responses, errors = [], []
    position_scale = max([abs(v) for v in a + b] + [length, TINY])
    length_tolerance = 1024 * EPS * position_scale
    for x, y, ex, ey in zip(da, db, ea, eb):
        delta = [dec(y[i] - x[i]) for i in range(2)]
        response = sum(direction[i] * delta[i] for i in range(2))
        projection_scale = sum(abs(dec(v)) for v in x + y)
        error = 16 * sum(dec(v) for v in ex + ey) + 4096 * EPS * projection_scale
        error += 8 * length_tolerance / length * sum(abs(v) for v in delta)
        responses.append(response); errors.append(max(error, TINY))
    return dict(a=a, b=b, length=length, direction=direction, responses=responses,
                errors=errors, length_tolerance=length_tolerance, position_scale=position_scale)


def check(actual, expected, tolerance, stats):
    assert isinstance(actual, (int, float)) and math.isfinite(actual)
    error = abs(dec(actual) - expected)
    tolerance = max(tolerance, TINY)
    assert error <= tolerance, (actual, str(expected), str(error), str(tolerance))
    stats["scalars"] += 1
    stats["maximum_absolute_error"] = max(stats["maximum_absolute_error"], float(error))
    stats["maximum_tolerance_fraction"] = max(stats["maximum_tolerance_fraction"], float(error / tolerance))


def dot(a, b):
    return sum((x * y for x, y in zip(a, b)), Decimal(0))


def dot_tolerance(a, b, ea, eb):
    return sum((abs(x) * dy + abs(y) * dx + dx * dy for x, y, dx, dy in zip(a, b, ea, eb)), Decimal(0)) + 1024 * EPS * sum((abs(x * y) for x, y in zip(a, b)), Decimal(0))


def check_request(binary, request, stats, differences):
    result = native(binary, request)
    matrix = request["calibration"]["matrix"]
    scale = max(abs(v) for v in matrix)
    matrix = [float(v) / scale for v in matrix]
    assert result["normalized_matrix"] == matrix and result["mode_count"] == len(request["modes"])
    assert result["kind"] == "calibration_distance_comparison"
    assert result["evidence_scope"] == "first_order_shared_homography_distance_contrasts"
    assert len(result["comparisons"]) == len(request["comparisons"])
    for probe, row in zip(request["comparisons"], result["comparisons"]):
        assert row["probe_id"] == probe["probe_id"]
        first = exact_distance(matrix, request["modes"], probe["first_segment"])
        second = exact_distance(matrix, request["modes"], probe["second_segment"])
        for output, reference in [(row["first"], first), (row["second"], second)]:
            for name, values in [("first_position_m", reference["a"]), ("second_position_m", reference["b"])]:
                assert len(output[name]) == 2
                for got, want in zip(output[name], values):
                    check(got, want, 512 * EPS * max(abs(want), Decimal(1)), stats)
            assert len(output["direction"]) == 2
            for got, want in zip(output["direction"], reference["direction"]):
                check(got, want, 8 * reference["length_tolerance"] / reference["length"], stats)
            check(output["distance_m"], reference["length"], reference["length_tolerance"], stats)
            assert len(output["mode_responses_m"]) == len(reference["responses"])
            for got, want, error in zip(output["mode_responses_m"], reference["responses"], reference["errors"]):
                check(got, want, error, stats)
            variance = dot(reference["responses"], reference["responses"])
            tolerance = dot_tolerance(reference["responses"], reference["responses"], reference["errors"], reference["errors"])
            check(output["contribution_m2"], variance, tolerance, stats)
            check(output["std_m"], variance.sqrt(), tolerance.sqrt() + 1024 * EPS * variance.sqrt(), stats)
        a, b, ea, eb = first["responses"], second["responses"], first["errors"], second["errors"]
        check(row["cross_contribution_m2"], dot(a, b), dot_tolerance(a, b, ea, eb), stats)
        diff = [x - y for x, y in zip(a, b)]
        ediff = [x + y for x, y in zip(ea, eb)]
        ratio = first["length"] / second["length"]
        eratio = 8 * ratio * (first["length_tolerance"] / first["length"] + second["length_tolerance"] / second["length"])
        dratio = [(x * second["length"] - first["length"] * y) / second["length"] ** 2 for x, y in zip(a, b)]
        edratio = [(dx + abs(ratio) * dy + abs(y) * eratio) / second["length"] + 8 * second["length_tolerance"] / second["length"] ** 2 * (abs(x) + abs(ratio * y))
                   for x, y, dx, dy in zip(a, b, ea, eb)]
        check(row["difference_m"], first["length"] - second["length"], first["length_tolerance"] + second["length_tolerance"], stats)
        check(row["ratio"], ratio, eratio, stats)
        for response_name, variance_name, std_name, values, errors in [
                ("difference_mode_responses_m", "difference_contribution_m2", "difference_std_m", diff, ediff),
                ("ratio_mode_responses", "ratio_contribution", "ratio_std", dratio, edratio)]:
            assert len(row[response_name]) == len(values)
            for got, want, error in zip(row[response_name], values, errors):
                check(got, want, error, stats)
            variance = dot(values, values)
            tolerance = dot_tolerance(values, values, errors, errors)
            check(row[variance_name], variance, tolerance, stats)
            check(row[std_name], variance.sqrt(), tolerance.sqrt() + 1024 * EPS * variance.sqrt(), stats)
        if differences:
            h = np.asarray(matrix).reshape(3, 3)
            points = np.array([p + [1.0] for segment in [probe["first_segment"], probe["second_segment"]] for p in segment])
            def nonlinear(mapping):
                projected = points @ mapping.T
                projected = projected[:, :2] / projected[:, 2, None]
                one = np.linalg.norm(projected[1] - projected[0])
                two = np.linalg.norm(projected[3] - projected[2])
                return np.array([one, two, one - two, one / two])
            step = 2.0 ** -12
            for index, mode in enumerate(request["modes"]):
                m = np.asarray(mode).reshape(3, 3)
                numerical = (nonlinear(h + step * m) - nonlinear(h - step * m)) / (2 * step)
                expected = np.array(list(map(float, [a[index], b[index], diff[index], dratio[index]])))
                error = float(np.max(np.abs(numerical - expected)))
                assert np.allclose(numerical, expected, rtol=2e-5, atol=5e-8), (numerical, expected)
                stats["finite_difference_vectors"] += 1
                stats["maximum_finite_difference_absolute_error"] = max(stats["maximum_finite_difference_absolute_error"], error)
        stats["comparisons"] += 1
    stats["requests"] += 1
    return result


def fixtures():
    original = json.loads((ROOT / "examples/calibration-distance.json").read_text(encoding="utf-8"))
    yield "shared-translation-scale", original, True
    empty = copy.deepcopy(original); empty["modes"] = []; yield "zero-rank", empty, False
    for amplitude in [1e-100, 1e100]:
        value = copy.deepcopy(original); value["modes"] = [[0, 0, amplitude, 0, 0, 2 * amplitude, 0, 0, 0]]
        yield "translation-{}".format(amplitude), value, False
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
    maximum["modes"] = [original["modes"][1]] * 32
    maximum["comparisons"] = [dict(original["comparisons"][0], probe_id="maximum-{}".format(i)) for i in range(256)]
    yield "maximum-32x256", maximum, False


def web_reference(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/calibration-distance.test.mjs"]
    process = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding="utf-8", timeout=180)
    assert process.returncode == 0, process.stdout
    summary = {key: int(value) for key, value in re.findall(r"^# (tests|pass|fail) (\d+)$", process.stdout, re.M)}
    assert summary == {"tests": 7, "pass": 7, "fail": 0}, process.stdout
    return dict(status="passed", summary=summary, command=" ".join(command),
                source_sha256=hashlib.sha256((ROOT / "web/calibration-distance.test.mjs").read_bytes()).hexdigest(),
                bridge_sha256=hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
                stdout_sha256=hashlib.sha256(process.stdout.encode("utf-8")).hexdigest(),
                node=subprocess.check_output(["node", "--version"], text=True).strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True); parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/calibration-distance-results.json")
    args = parser.parse_args(); binary = args.binary.resolve(); started = time.perf_counter()
    stats = dict(requests=0, comparisons=0, scalars=0, maximum_absolute_error=0.0, maximum_tolerance_fraction=0.0,
                 finite_difference_vectors=0, maximum_finite_difference_absolute_error=0.0)
    cases = []
    with localcontext() as context:
        context.prec = 110
        for name, request, differences in fixtures():
            result = check_request(binary, request, stats, differences)
            cases.append(dict(case=name, modes=len(request["modes"]), comparisons=len(request["comparisons"]),
                              encoded_json_utf16=len(encode(result).encode("utf-16-le")) // 2))
    result = dict(status="passed", seed=SEED, command=" ".join(shlex.quote(v) for v in [sys.executable] + sys.argv),
                  toolchain=subprocess.check_output(["moon", "version", "--all", "--no-path"], text=True).strip(),
                  pinned_moon_home=os.environ.get("MOON_HOME"), python=platform.python_version(), numpy=np.__version__,
                  source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  projection_reference_sha256=hashlib.sha256((ROOT / "validation/calibration_sensitivity_verify.py").read_bytes()).hexdigest(),
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  reference="Fraction homography quotient derivative; 110-digit Decimal Euclidean lengths, differences, ratios and shared moments; scale-aware floating comparison tolerances, no certified error bound",
                  tolerance="Length 1024*epsilon*absolute position scale; response errors include endpoint derivative error and length conditioning; contrast and moment errors propagate those tolerances. Formulas are in the reference source.",
                  finite_difference=dict(step=2 ** -12, rtol=2e-5, atol=5e-8), statistics=stats, cases=cases)
    if args.web:
        result["web_interchange"] = web_reference(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(json.dumps(dict(status="passed", statistics=stats, output=str(args.output)), ensure_ascii=True))


if __name__ == "__main__":
    main()
