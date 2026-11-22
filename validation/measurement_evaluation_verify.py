#!/usr/bin/env python3
"""Check metric evaluation with offline Decimal reductions and file-log joins."""

import argparse
from collections import Counter
from decimal import Decimal, localcontext
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
import tempfile
import time

from public_reports import portable_report

ROOT = Path(__file__).resolve().parent.parent
SEED = 20261122
SCOPE = 'conditional_on_fixed_calibration_camera_and_anchor'
ACCEPTED = ('initializing', 'ready', 'uncertain')


def track(identity, clock, status='ready', point=(3.0, 4.0), speed=2.0):
    accepted, observable = status in ACCEPTED, status in ('ready', 'uncertain')
    value = dict(track_id=identity, segment_id=str(identity), status=status,
                 position_m=list(point) if accepted else None,
                 position_covariance=[0.01, 0, 0.01] if accepted else None,
                 position_std_m=0.1 if accepted else None,
                 velocity_mps=[speed, 0] if observable else None,
                 velocity_covariance=[0.01, 0, 0.01] if observable else None,
                 velocity_std_mps=0.1 if observable else None,
                 speed_mps=speed if status == 'ready' else None)
    if status == 'rejected_projection':
        value.update(segment_id=None, reason='outside ROI')
    else:
        value.update(observed_path_length_m=0, net_displacement_m=0,
                     accepted_count=1, last_accepted_timestamp_us=str(clock))
    return value


def measurement(clock, tracks):
    return dict(schema_version='0.2.0', session_id='evaluation', timestamp_us=str(clock),
                tracks=tracks, closed_segment_ids=[], uncertainty_scope=SCOPE)


def paired(clock, tracks, samples):
    return dict(measurement=measurement(clock, tracks),
                reference=dict(timestamp_us=str(clock), samples=samples))


def reference(identity, point=(0.0, 0.0), speed=0.0):
    value = dict(track_id=identity, position_m=list(point))
    if speed is not None:
        value['speed_mps'] = speed
    return value


def fixtures():
    yield 'empty', []
    yield 'unreferenced', [paired(0, [track(1, 0)], [])]
    yield 'all-missing', [paired(0, [], [reference(1), reference(2)])]
    yield 'no-speed-reference', [paired(0, [track(1, 0)], [reference(1, speed=None)])]
    yield 'hand-calculated', [paired(0, [track(1, 0, speed=5)], [reference(1, speed=3)]),
                              paired(1, [track(1, 1, point=(0, 0), speed=3)], [reference(1, speed=5)])]
    statuses = list(ACCEPTED) + ['rejected_innovation', 'numerical_failure', 'rejected_projection']
    yield 'all-statuses', [paired(0, [track(i + 1, 0, s) for i, s in enumerate(statuses)] + [track(8, 0)],
                                [reference(i) for i in range(1, 8)])]
    yield 'exact-clocks', [paired(t, [track(1, t)], [reference(1)])
                           for t in (9007199254740993, 9007199254740994, 9223372036854775807)]
    rng = random.Random(SEED)
    for scale in (1e-200, 1e200, 1.0):
        rows = []
        for i in range(40):
            tracks, references = [], []
            for identity in range(1, 15):
                point = [rng.uniform(-10, 10) * scale for _ in range(2)]
                speed = rng.uniform(0, 4) * scale
                if rng.random() < 0.85:
                    references.append(reference(identity, point, speed if rng.random() < 0.7 else None))
                if rng.random() < 0.85:
                    observed = [point[k] + rng.uniform(-0.5, 0.5) * scale for k in range(2)]
                    tracks.append(track(identity, i, rng.choice(statuses), observed,
                                        max(0, speed + rng.uniform(-0.1, 0.1) * scale)))
            rng.shuffle(tracks)
            rng.shuffle(references)
            rows.append(paired(i, tracks, references))
        yield 'random-scale-' + str(scale), rows
    yield 'cancelling-extreme-bias', [paired(i, [track(1, i, point=(value, 0))], [reference(1)])
                                     for i, value in enumerate((1e308, -1e308, 1e308, -1e308))]
    yield 'maximum-wire-frame', [paired(0, [track(i, 0) for i in range(1, 1025)],
                                        [reference(i) for i in range(1, 1025)])]
    yield 'native-10000-frame-accumulation', [paired(i, [], []) for i in range(10000)]


def decimal(value):
    return Decimal.from_float(float(value))


def offline_report(rows, session_id='evaluation'):
    counts = Counter(dict(frames=str(len(rows)), references=0, speed_references=0,
                          measurements=0, without_reference=0, missing=0, initializing=0,
                          ready=0, uncertain=0, rejected_innovation=0, numerical_failure=0,
                          rejected_projection=0))
    positions, dxs, dys, speeds = [], [], [], []
    for row in rows:
        tracks = {t['track_id']: t for t in row['measurement']['tracks']}
        references = row['reference']['samples']
        counts['measurements'] += len(tracks)
        counts['references'] += len(references)
        counts['without_reference'] += len(set(tracks) - {t['track_id'] for t in references})
        for ref in references:
            counts['speed_references'] += int('speed_mps' in ref)
            observed = tracks.get(ref['track_id'])
            if observed is None:
                counts['missing'] += 1
                continue
            counts[observed['status']] += 1
            if observed['status'] in ACCEPTED:
                dx, dy = [decimal(observed['position_m'][i]) - decimal(ref['position_m'][i]) for i in range(2)]
                dxs.append(dx)
                dys.append(dy)
                positions.append((dx * dx + dy * dy).sqrt())
            if observed['status'] == 'ready' and 'speed_mps' in ref:
                speeds.append(decimal(observed['speed_mps']) - decimal(ref['speed_mps']))
    def average(values):
        return sum(values, Decimal(0)) / len(values) if values else None
    def stats(values):
        return dict(samples=len(values), mean_absolute_error=average([abs(v) for v in values]),
                    root_mean_square_error=(sum((v*v for v in values), Decimal(0)) / len(values)).sqrt() if values else None,
                    maximum_absolute_error=max(map(abs, values)) if values else None)
    result = dict(schema_version='0.1.0', kind='measurement_evaluation',
                  reference_scope='caller_supplied_aligned_metric_truth', session_id=session_id,
                  first_timestamp_us=rows[0]['measurement']['timestamp_us'] if rows else None,
                  last_timestamp_us=rows[-1]['measurement']['timestamp_us'] if rows else None,
                  counts=dict(counts), position_error_m=stats(positions),
                  position_bias_m=[average(dxs), average(dys)] if positions else None,
                  position_coverage=Decimal(len(positions)) / counts['references'] if counts['references'] else None,
                  speed_error_mps=stats(speeds), speed_bias_mps=average(speeds),
                  speed_coverage=Decimal(len(speeds)) / counts['speed_references'] if counts['speed_references'] else None)
    scales = dict(m=max([abs(x) for x in positions + dxs + dys] + [Decimal('1e-300')]),
                  mps=max([abs(x) for x in speeds] + [Decimal('1e-300')]), dimensionless=Decimal(1))
    return result, scales


def compare(actual, expected, scales, stats, path=''):
    if isinstance(expected, dict):
        assert set(actual) == set(expected), (path, set(actual) ^ set(expected))
        for key, value in expected.items():
            compare(actual[key], value, scales, stats, path + '.' + key)
    elif isinstance(expected, list):
        assert len(actual) == len(expected)
        for a, b in zip(actual, expected):
            compare(a, b, scales, stats, path)
    elif isinstance(expected, Decimal):
        assert isinstance(actual, (int, float)) and math.isfinite(actual), path
        unit = 'dimensionless' if 'coverage' in path else ('mps' if 'speed' in path else 'm')
        tolerance = Decimal('2e-12') * max(abs(expected), scales[unit])
        error = abs(decimal(actual) - expected)
        assert error <= tolerance, (path, actual, str(expected), str(error / tolerance))
        stats['scalars'] += 1
        stats['maximum_tolerance_fraction'] = max(stats['maximum_tolerance_fraction'], float(error / tolerance))
        stats['maximum_absolute_error_by_unit'][unit] = max(stats['maximum_absolute_error_by_unit'][unit], float(error))
    else:
        assert actual == expected, (path, actual, expected)
        stats['exact_fields'] += 1


def native(binary, rows):
    lines = [dict(session_id='evaluation')] + rows
    payload = '\n'.join(json.dumps(line, separators=(',', ':'), allow_nan=False) for line in lines) + '\n'
    result = subprocess.run([str(binary), '--evaluate-measurements'], input=payload,
                            text=True, encoding='utf-8', stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    assert result.returncode == 0, result.stderr
    assert len(result.stdout.strip().splitlines()) == 1
    return json.loads(result.stdout)


def file_adapter(binary):
    script = ROOT / 'examples/evaluate_measurements.py'
    source = ROOT / 'examples/measurement-evaluation-measurements.ndjson'
    reference_source = ROOT / 'examples/measurement-evaluation-reference.ndjson'
    cases = []
    with tempfile.TemporaryDirectory(prefix='moonground-evaluation-') as directory:
        root = Path(directory)
        measured, references, output = root/'observations.ndjson', root/'reference.ndjson', root/'result.json'
        measured.write_bytes(source.read_bytes())
        references.write_bytes(reference_source.read_bytes())
        command = [sys.executable, str(script), '--binary', str(binary), '--measurements', str(measured),
                   '--references', str(references), '--output', str(output)]
        def execute(name, status=0, extra=None):
            process = subprocess.run(command + (extra or []), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
            assert process.returncode == status, (name, process.stderr.decode('utf-8', 'replace'))
            cases.append(dict(name=name, exit_code=status, passed=True))
        execute('ordered-full-outer-join')
        result = json.loads(output.read_text(encoding='utf-8'))
        assert result['alignment'] == dict(paired_frames=3, measurement_only_frames=1, reference_only_frames=1)
        assert result['evaluation']['counts']['missing'] == 1
        assert result['evaluation']['position_coverage'] == 0.75
        assert result['evaluation']['speed_coverage'] == 0.25
        assert result['inputs']['measurements_sha256'] == hashlib.sha256(source.read_bytes()).hexdigest()
        assert result['inputs']['references_sha256'] == hashlib.sha256(reference_source.read_bytes()).hexdigest()
        assert result['binary_sha256'] == hashlib.sha256(binary.read_bytes()).hexdigest()
        for name, bad in [
                ('raw-underflow-retained', b'{"timestamp_us":"800000","samples":[{"track_id":1,"position_m":[0,0],"speed_mps":1e-999}]}\n'),
                ('duplicate-raw-fields', b'{"timestamp_us":"800000","samples":[],"samples":[]}\n'),
                ('out-of-order-references', b'{"timestamp_us":"0","samples":[]}\n')]:
            output.write_bytes(b'previous-result')
            references.write_bytes(reference_source.read_bytes() + bad)
            execute(name, 2)
            assert output.read_bytes() == b'previous-result'
        references.write_bytes(reference_source.read_bytes())
        original = measured.read_bytes()
        execute('output-input-alias-rejected', 2, ['--output', str(measured)])
        assert measured.read_bytes() == original
        alias = root/'alias.ndjson'
        try:
            os.link(str(measured), str(alias))
        except OSError:
            cases.append(dict(name='hardlink-alias', passed=False, status='filesystem_does_not_support_test'))
        else:
            execute('hardlink-output-alias-rejected', 2, ['--output', str(alias)])
            assert measured.read_bytes() == original
        measured.write_bytes(b'')
        output.write_bytes(b'previous-result')
        execute('empty-measurements-require-session', 2)
        assert output.read_bytes() == b'previous-result'
        execute('reference-only-log-counts-misses', 0, ['--session-id', 'evaluation-example'])
        result = json.loads(output.read_text(encoding='utf-8'))
        assert result['evaluation']['counts']['missing'] == 4
        assert result['evaluation']['position_error_m']['mean_absolute_error'] is None
        assert result['evaluation']['position_coverage'] == 0
        measured.write_bytes(original + original.splitlines(keepends=True)[0])
        execute('out-of-order-measurements', 2)
        measured.write_bytes(original)
        for timeout in ['nan', 'inf', '0', '-1']:
            execute('invalid-timeout-' + timeout, 2, ['--timeout', timeout])
        assert not list(root.glob('.evaluation-*.tmp'))
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--web', action='store_true')
    parser.add_argument('--output', type=Path, default=ROOT/'validation/measurement-evaluation-results.json')
    args = parser.parse_args()
    binary, started = args.binary.resolve(), time.perf_counter()
    stats = dict(requests=0, frames=0, references=0, scalars=0, exact_fields=0,
                 maximum_tolerance_fraction=0.0, maximum_absolute_error_by_unit=dict(m=0.0, mps=0.0, dimensionless=0.0))
    cases = []
    with localcontext() as context:
        context.prec = 160
        for name, rows in fixtures():
            expected, scales = offline_report(rows)
            compare(native(binary, rows), expected, scales, stats)
            stats['requests'] += 1
            stats['frames'] += len(rows)
            stats['references'] += expected['counts']['references']
            cases.append(dict(name=name, frames=len(rows), references=expected['counts']['references']))
    adapter_cases = file_adapter(binary)
    result = dict(status='passed', data_scope='synthetic_metric_references', seed=SEED,
                  statistics=stats, cases=cases, file_adapter_cases=adapter_cases,
                  reference='Offline 160-digit Decimal subtraction, Euclidean norms and direct population reductions; no online accumulator',
                  decimal_precision=160, tolerance=dict(rtol=2e-12, scale='maximum absolute evaluated error per unit'),
                  command='python ' + ' '.join(sys.argv), python=platform.python_version(),
                  toolchain=subprocess.check_output(['moon','version','--all','--no-path'], text=True).strip(),
                  source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  adapter_sha256=hashlib.sha256((ROOT/'examples/evaluate_measurements.py').read_bytes()).hexdigest(),
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), elapsed_seconds=time.perf_counter()-started)
    if args.web:
        command = ['node','--test','--test-reporter=tap','web/measurement-evaluation.test.mjs']
        process = subprocess.run(command, cwd=str(ROOT), text=True, encoding='utf-8', stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, timeout=120, env=dict(os.environ, MOONGROUND_CLI=str(binary)))
        assert process.returncode == 0, process.stdout
        summary = {key:int(re.search(r'^# '+key+r' (\d+)$', process.stdout, re.M)[1]) for key in ('tests','pass','fail')}
        result['web_interchange'] = dict(status='passed', summary=summary, command=' '.join(command),
            source_sha256=hashlib.sha256((ROOT/'web/measurement-evaluation.test.mjs').read_bytes()).hexdigest(),
            bridge_sha256=hashlib.sha256((ROOT/'_build/site/moonground.mjs').read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes((json.dumps(portable_report(result), indent=2) + '\n').encode('utf-8'))
    print(json.dumps(dict(status='passed', statistics=stats, file_adapter_cases=len(adapter_cases))))


if __name__ == '__main__':
    main()
