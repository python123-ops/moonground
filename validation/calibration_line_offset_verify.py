#!/usr/bin/env python3
"""Verify shared line offsets via exact inverse-transpose line transport."""

import argparse
from decimal import Decimal, localcontext
from fractions import Fraction as F
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import subprocess
import sys
import time

from public_reports import portable_report

ROOT = Path(__file__).resolve().parents[1]
SEED = 20261122


def D(value):
    return Decimal(value.numerator) / Decimal(value.denominator) if isinstance(value, F) else Decimal(value)


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def cross(a, b):
    return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]


def inverse_transpose(h):
    a, b, c = [h[i:i+3] for i in (0, 3, 6)]
    rows = [cross(b, c), cross(c, a), cross(a, b)]
    determinant = dot(a, rows[0])
    return [[v / determinant for v in row] for row in rows]


def multiply(matrix, vector):
    return [dot(row, vector) for row in matrix]


def project(h, pixel):
    p = [F(float(pixel[0])), F(float(pixel[1])), F(1)]
    z = [dot(h[i:i+3], p) for i in (0, 3, 6)]
    return [z[0]/z[2], z[1]/z[2]], p, z[2]


def point_derivative(mode, point, homogeneous, w):
    dz = [dot(mode[i:i+3], homogeneous) for i in (0, 3, 6)]
    return [(dz[i]-point[i]*dz[2])/w for i in (0, 1)]


def oracle(h, modes, row):
    a, _, _ = project(h, row['line_start'])
    b, _, _ = project(h, row['line_end'])
    p, hp, wp = project(h, row['first_pixel'])
    q, hq, wq = project(h, row['second_pixel'])
    image_line = cross([F(float(v)) for v in row['line_start']] + [F(1)],
                       [F(float(v)) for v in row['line_end']] + [F(1)])
    transport = inverse_transpose(h)
    line = multiply(transport, image_line)
    side = line[0] * (a[1]-b[1]) + line[1] * (b[0]-a[0])
    sign = 1 if side > 0 else -1
    line = [sign * value for value in line]
    n2 = line[0]**2 + line[1]**2
    norm = D(n2).sqrt()
    numerators = [dot(line, p + [F(1)]), dot(line, q + [F(1)]),
                  line[0]*(p[0]-q[0]) + line[1]*(p[1]-q[1])]
    means = [D(value) / norm for value in numerators]
    responses = [[], [], []]
    scales = [[], [], []]
    for mode in modes:
        transpose_product = [sum(mode[j*3+i]*line[j] for j in range(3)) for i in range(3)]
        dl = [-value for value in multiply(transport, transpose_product)]
        dp = point_derivative(mode, p, hp, wp)
        dq = point_derivative(mode, q, hq, wq)
        derivatives = [dot(dl, p+[F(1)]) + dot(line[:2], dp),
                       dot(dl, q+[F(1)]) + dot(line[:2], dq),
                       dot(dl[:2], [p[i]-q[i] for i in range(2)]) +
                       dot(line[:2], [dp[i]-dq[i] for i in range(2)])]
        term_scales = [sum(abs(x*y) for x,y in zip(dl, p+[F(1)])) + sum(abs(x*y) for x,y in zip(line[:2], dp)),
                       sum(abs(x*y) for x,y in zip(dl, q+[F(1)])) + sum(abs(x*y) for x,y in zip(line[:2], dq)),
                       sum(abs(dl[i]*(p[i]-q[i])) + abs(line[i]*(dp[i]-dq[i])) for i in range(2))]
        normal_term = dot(line[:2], dl[:2])
        for i in range(3):
            numerator = derivatives[i]*n2 - numerators[i]*normal_term
            responses[i].append(D(numerator) / (D(n2) * norm))
            scales[i].append((D(term_scales[i])*D(n2) + abs(D(numerators[i]*normal_term))) /
                             (D(n2)*norm))
    variance = [sum((v*v for v in values), Decimal(0)) for values in responses]
    length = D(sum((b[i]-a[i])**2 for i in range(2))).sqrt()
    return dict(line_start_m=list(map(D, a)), line_end_m=list(map(D, b)),
                direction=[D(b[i]-a[i])/length for i in range(2)], line_length_m=length,
                first=dict(position_m=list(map(D, p)), signed_offset_m=means[0],
                           mode_responses_m=responses[0], contribution_m2=variance[0], std_m=variance[0].sqrt()),
                second=dict(position_m=list(map(D, q)), signed_offset_m=means[1],
                            mode_responses_m=responses[1], contribution_m2=variance[1], std_m=variance[1].sqrt()),
                cross_contribution_m2=sum((x*y for x, y in zip(responses[0], responses[1])), Decimal(0)),
                difference_m=means[2], difference_mode_responses_m=responses[2],
                difference_contribution_m2=variance[2], difference_std_m=variance[2].sqrt()), scales


def nonlinear(h, mode, row, step):
    changed = [D(v) + step*D(m) for v, m in zip(h, mode)]
    def point(pixel):
        z = [sum(changed[i+j]*D(F(float(v))) for j, v in enumerate([*pixel, 1])) for i in (0, 3, 6)]
        return [z[0]/z[2], z[1]/z[2]]
    a, b, p, q = [point(row[key]) for key in ('line_start', 'line_end', 'first_pixel', 'second_pixel')]
    u = [b[i]-a[i] for i in range(2)]
    length = sum(v*v for v in u).sqrt()
    def signed(v):
        return (u[0]*v[1]-u[1]*v[0])/length
    return [signed([p[i]-a[i] for i in range(2)]), signed([q[i]-a[i] for i in range(2)]),
            signed([p[i]-q[i] for i in range(2)])]


def row(name, a=(0, 4), b=(8, 4), p=(2, 7), q=(2, 2)):
    return dict(probe_id=name, line_start=list(a), line_end=list(b), first_pixel=list(p), second_pixel=list(q))


def request(modes, rows, matrix=None, maximum=2):
    return dict(calibration=dict(matrix=matrix or [1,0,0,0,1,0,0,0,1],
                                roi=[[0,0],[100,0],[100,100],[0,100]], max_meters_per_pixel=maximum),
                modes=modes, comparisons=rows)


def fixtures():
    translation = [0,0,0.25,0,0,0.5,0,0,0]
    scale = [0.125,0,0,0,0.125,0,0,0,0]
    rotation = [0,-0.125,0,0.125,0,0,0,0,0]
    gauge = [0.125,0,0,0,0.125,0,0,0,0.125]
    rows = [row('opposite'), row('same', q=(2,7)), row('online', p=(12,4), q=(0,4)),
            row('oblique', a=(1,2), b=(10,14), p=(20,6), q=(6,10)),
            row('reverse', a=(8,4), b=(0,4))]
    yield 'empty-batch', request([], []), False
    yield 'empty-modes', request([], rows), False
    yield 'common-similarity-and-gauge', request([translation, scale, rotation, gauge], rows), True
    yield 'moving-reference-shear', request([[0,0,0,0.125,0,0,0,0,0], [0.125,0,0,0,0,0,0,0,0]], rows), True
    yield 'perspective', request([[0,0,0,0,0,0,0.0005,-0.0003,0], scale], rows,
                               [0.8,0.125,2,-0.25,0.75,3,0.001,-0.0005,1]), True
    yield 'reflection', request([translation, rotation, scale], rows, [-1,0,0,0,1,0,0,0,1]), True
    yield 'short-reference', request([], [row('tiny', a=(0,0), b=(1e-200,2e-200), p=(2,3), q=(4,2))]), False
    yield 'near-coincident-reference', request([scale], [row('close', a=(1,1), b=(1.0000000000000002,1), p=(1,2), q=(1,3))]), False
    for magnitude in (1e-140, 1e140):
        yield 'extreme-scale-' + str(magnitude), request([], rows, [magnitude,0,0,0,magnitude,0,0,0,1], max(2, magnitude*3)), False
    # Far reference line: compare positions directly, rather than rounded offsets.
    yield 'far-reference', request([], [row('separation', a=(0,0), b=(1,0), p=(0,1), q=(0,1.0000000000000002))],
                                   [1e15,0,0,0,1e15,-1e15,0,0,1], 2e15), False
    rng = random.Random(SEED)
    for k in range(14):
        h = [rng.uniform(0.3,0.8), rng.uniform(-0.05,0.05), rng.uniform(-3,3),
             rng.uniform(-0.05,0.05), rng.uniform(0.3,0.8), rng.uniform(-3,3),
             rng.uniform(-0.0005,0.0005), rng.uniform(-0.0005,0.0005), 1]
        modes = [[rng.uniform(-0.001,0.001) for _ in range(6)] +
                 [rng.uniform(-0.00001,0.00001), rng.uniform(-0.00001,0.00001), rng.uniform(-0.001,0.001)]
                 for _ in range(1 + k % 7)]
        probes = [row('random-' + str(i), *[[rng.uniform(2,98),rng.uniform(2,98)] for _ in range(4)]) for i in range(11)]
        yield 'random-' + str(k), request(modes, probes), True
    yield 'maximum-batch', request([translation, scale] * 16, [row('max-' + str(i)) for i in range(256)]), False


def check_request(binary, data, finite_difference, stats):
    process = subprocess.run([str(binary), '--calibration-line-offset'], input=json.dumps(data).encode(),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    assert process.returncode == 0, process.stderr.decode('utf-8', errors='replace')
    actual = json.loads(process.stdout)
    h = [F(float(v/max(map(abs, data['calibration']['matrix'])))) for v in data['calibration']['matrix']]
    assert actual['normalized_matrix'] == [float(v) for v in h]
    modes = [[F(float(v)) for v in mode] for mode in data['modes']]
    assert actual['kind'] == 'calibration_line_offset_comparison'
    assert actual['mode_count'] == len(modes)
    assert len(actual['comparisons']) == len(data['comparisons'])
    for probe, value in zip(data['comparisons'], actual['comparisons']):
        golden, scales = oracle(h, modes, probe)
        geometry = max([abs(v) for key in ('line_start_m', 'line_end_m') for v in golden[key]] + [Decimal('1e-300')])
        response_scale = max([abs(v) for values in scales for v in values] + [Decimal('1e-300')])
        def compare(a, b, key=''):
            if isinstance(b, dict):
                for field, child in b.items():
                    compare(a[field], child, field)
            elif isinstance(b, list):
                assert len(a) == len(b)
                for left, right in zip(a, b): compare(left, right, key)
            else:
                unit = 'm2' if 'contribution' in key else ('dimensionless' if key == 'direction' else 'm')
                base = response_scale**2 if unit == 'm2' else (Decimal(1) if unit == 'dimensionless' else geometry)
                if key == 'difference_m':
                    base = max([abs(a-b) for a,b in zip(golden['first']['position_m'], golden['second']['position_m'])] + [Decimal('1e-300')])
                if key == 'position_m': base = max(abs(b), Decimal('1e-300'))
                if 'responses' in key or key in ('std_m', 'difference_std_m'): base = response_scale
                tolerance = Decimal('2e-10')*abs(b) + Decimal('3e-12')*base
                error = abs(D(F(float(a)))-b)
                assert math.isfinite(a) and error <= tolerance, (probe['probe_id'], key, a, str(b), str(error/tolerance))
                stats['scalars'] += 1
                stats['maximum_tolerance_fraction'] = max(stats['maximum_tolerance_fraction'], float(error/tolerance))
                stats['maximum_absolute_error_by_unit'][unit] = max(stats['maximum_absolute_error_by_unit'][unit], float(error))
        compare(value, golden)
        if finite_difference:
            step = Decimal('0.000001')
            for i, mode in enumerate(modes):
                positive, negative = nonlinear(h, mode, probe, step), nonlinear(h, mode, probe, -step)
                expected = [golden['first']['mode_responses_m'][i], golden['second']['mode_responses_m'][i], golden['difference_mode_responses_m'][i]]
                for got, want in zip([(a-b)/(2*step) for a,b in zip(positive,negative)], expected):
                    assert abs(got-want) <= Decimal('2e-7')*abs(want) + Decimal('2e-9')*max(response_scale, Decimal(1))
                stats['finite_difference_vectors'] += 1
        stats['comparisons'] += 1
    stats['requests'] += 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--web', action='store_true')
    parser.add_argument('--output', type=Path, default=ROOT/'validation/calibration-line-offset-results.json')
    args = parser.parse_args()
    binary = args.binary.resolve()
    started = time.perf_counter()
    stats = dict(requests=0, comparisons=0, scalars=0, finite_difference_vectors=0,
                 maximum_tolerance_fraction=0.0, maximum_absolute_error_by_unit=dict(m=0.0, m2=0.0, dimensionless=0.0))
    cases = []
    with localcontext() as context:
        context.prec = 160
        for name, data, differences in fixtures():
            try:
                check_request(binary, data, differences, stats)
                cases.append(dict(name=name, modes=len(data['modes']), comparisons=len(data['comparisons']), nonlinear_checked=differences))
            except Exception as error:
                raise AssertionError('fixture ' + name + ': ' + str(error)) from error
    result = dict(status='passed', seed=SEED, statistics=stats, cases=cases, decimal_precision=160, python=platform.python_version(),
                  toolchain=subprocess.check_output(['moon','version','--all','--no-path'], text=True).strip(),
                  command='python ' + ' '.join(sys.argv), source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  reference='Exact Fraction inverse-transpose image-line transport and differentiated matrix inverse; 160-digit Decimal square roots and moments',
                  finite_difference=dict(step='0.000001', precision=160, formula='Nonlinear projected anchor cross products and norm; three signed offsets including direct point separation'),
                  tolerance=dict(rtol=2e-10, scaled_atol=3e-12),
                  units=dict(mean='m', response='m per latent mode', contribution='m2'),
                  elapsed_seconds=time.perf_counter()-started)
    if args.web:
        command = ['node','--test','--test-reporter=tap','web/calibration-line-offset.test.mjs']
        process = subprocess.run(command, cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, encoding='utf-8', timeout=120,
                                 env=dict(os.environ, MOONGROUND_CLI=str(binary)))
        assert process.returncode == 0, process.stdout
        summary = {key:int(re.search(r'^# '+key+r' (\d+)$', process.stdout, re.M)[1]) for key in ('tests','pass','fail')}
        result['web_interchange'] = dict(status='passed', summary=summary, command=' '.join(command),
                                       source_sha256=hashlib.sha256((ROOT/'web/calibration-line-offset.test.mjs').read_bytes()).hexdigest(),
                                       bridge_sha256=hashlib.sha256((ROOT/'_build/site/moonground.mjs').read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes((json.dumps(portable_report(result), indent=2) + '\n').encode())
    print(json.dumps(dict(status='passed', statistics=stats)))


if __name__ == '__main__':
    main()
