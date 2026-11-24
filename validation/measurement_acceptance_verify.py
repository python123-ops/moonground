#!/usr/bin/env python3
"""Check explicit accuracy requirements against independent Decimal reductions."""

import argparse
from decimal import Decimal, localcontext
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time

from measurement_evaluation_verify import SEED, fixtures, offline_report, compare, track, paired, reference
from public_reports import portable_report

ROOT = Path(__file__).resolve().parent.parent
FIELDS = [('position_m', 'position_error_m', 'position_coverage'), ('speed_mps', 'speed_error_mps', 'speed_coverage')]
ERRORS = [('max_mae', 'mean_absolute_error'), ('max_rmse', 'root_mean_square_error'), ('max_error', 'maximum_absolute_error')]


def encode(value):
    return json.dumps(value, separators=(',', ':'), allow_nan=False)


def run(binary, source, rows, ending='\n', expected=None):
    data = ending.join([source]+[encode(row) for row in rows])+ending
    process = subprocess.run([str(binary), '--accept-measurements'], input=data.encode(),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    if expected == 2:
        assert process.returncode == 2 and not process.stdout and process.stderr
        return None
    assert process.returncode in [0, 3] and not process.stderr, (process.returncode, process.stderr)
    assert len(process.stdout.splitlines()) == 1
    result = json.loads(process.stdout)
    assert type(result['accepted']) is bool
    assert process.returncode == (0 if result['accepted'] else 3)
    if expected is not None:
        assert process.returncode == expected
    return result


def check_requirements(report, requirements, result):
    checks = []
    for quantity, errors, coverage in FIELDS:
        if quantity not in requirements:
            continue
        limits = requirements[quantity]
        values = [(errors+'.samples', report[errors]['samples'], limits['min_samples'], 'at_least'),
                  (coverage, report[coverage], limits['min_coverage'], 'at_least')]
        values += [(errors+'.'+field, report[errors][field], limits[key], 'at_most') for key, field in ERRORS if key in limits]
        for metric, actual, limit, comparison in values:
            passes = actual is not None and (float(actual) >= limit if comparison == 'at_least' else float(actual) <= limit)
            checks.append(dict(metric=metric, actual=actual, limit=limit, comparison=comparison, passed=passes))
    assert len(checks) == len(result['checks'])
    for expected, actual in zip(checks, result['checks']):
        assert set(actual) == set(expected)
        for field in ['metric', 'limit', 'comparison', 'passed']:
            assert actual[field] == expected[field], (field, actual, expected)
        if expected['actual'] is None:
            assert actual['actual'] is None
        else:
            assert math.isclose(actual['actual'], float(expected['actual']), rel_tol=2e-12, abs_tol=0)
    assert result['accepted'] == all(check['passed'] for check in checks)
    assert result['requirements'] == requirements
    return len(checks)


def numerical_cases(binary):
    statistics = dict(scalars=0, exact_fields=0, maximum_tolerance_fraction=0,
                      maximum_absolute_error_by_unit=dict(m=0, mps=0, dimensionless=0))
    results, checks = [], 0
    for name, rows in fixtures():
        with localcontext() as context:
            context.prec = 160
            report, scales = offline_report(rows)
        requirements = {}
        for quantity, errors, coverage in FIELDS:
            limits = dict(min_samples=1, min_coverage=0.0)
            for key, field in ERRORS:
                value = float(report[errors][field]) if report[errors][field] is not None else 1.0
                limits[key] = value*2 if value <= 5e307 else value
            requirements[quantity] = limits
        for strict in [False, True]:
            selected = json.loads(encode(requirements))
            if strict:
                for quantity, errors, coverage in FIELDS:
                    selected[quantity]['min_samples'] = max(1, report[errors]['samples']+1)
                    selected[quantity]['max_mae'] = 0.0
            source = encode(dict(session_id='evaluation', requirements=selected))
            actual = run(binary, source, rows)
            with localcontext() as context:
                context.prec = 160
                compare(actual['evaluation'], report, scales, statistics)
            checks += check_requirements(report, selected, actual)
            results.append(dict(name=name+('-strict' if strict else '-loose'), frames=len(rows), requirements=selected,
                                accepted=actual['accepted'], exit_code=0 if actual['accepted'] else 3, passed=True))
    # Exact boundaries use binary-exact statistics and coverage fractions.
    rows = [paired(0, [track(1, 0, speed=2)], [reference(1), reference(2)])]
    limits = dict(position_m=dict(min_samples=1, min_coverage=0.5, max_mae=5, max_rmse=5, max_error=5),
                  speed_mps=dict(min_samples=1, min_coverage=0.5, max_mae=2, max_rmse=2, max_error=2))
    actual = run(binary, encode(dict(session_id='evaluation', requirements=limits)), rows, expected=0)
    report, _ = offline_report(rows)
    checks += check_requirements(report, limits, actual)
    results.append(dict(name='inclusive-samples-coverage-and-errors', frames=1, requirements=limits, accepted=True, exit_code=0, passed=True))
    return results, checks, statistics


def protocol_cases(binary):
    base = dict(session_id='evaluation', requirements=dict(position_m=dict(min_samples=1, min_coverage=1, max_error=0)))
    cases = []
    invalid = [dict(session_id='evaluation'), dict(base, requirements={}), dict(base, requirements=None),
               dict(base, requirements=dict(position_m=None)), dict(base, extra=0)]
    for changes in [dict(min_samples=0), dict(min_samples=True), dict(min_coverage=1.01), dict(max_error=-1), dict(max_error=None), dict(extra=1)]:
        limits = dict(base['requirements']['position_m'], **changes)
        invalid.append(dict(base, requirements=dict(position_m=limits)))
    for index, source in enumerate(invalid):
        run(binary, encode(source), [], expected=2)
        cases.append(dict(name='invalid-configuration-'+str(index), passed=True))
    for number in ['1e-1000', '1e1000']:
        raw = encode(base).replace('"max_error":0', '"max_error":'+number)
        run(binary, raw, [], expected=2)
        cases.append(dict(name='invalid-raw-bound-'+number, passed=True))
    for ending in ['\n', '\r\n', '']:
        actual = run(binary, encode(base), [], ending=ending, expected=3)
        assert actual['evaluation']['counts']['frames'] == '0'
        cases.append(dict(name='configuration-only-ending-'+repr(ending), passed=True))
    valid = paired(0, [track(1, 0, point=(0, 0))], [reference(1)])
    run(binary, encode(base), [valid, dict(invalid=True)], expected=2)
    cases.append(dict(name='late-error-emits-no-prefix-report', passed=True))
    return cases


def file_cases(binary):
    cases = []
    with tempfile.TemporaryDirectory(prefix='moonground-acceptance-') as temporary:
        directory = Path(temporary)
        criteria, output = directory/'requirements.json', directory/'result.json'
        sample = (ROOT/'examples/measurement-acceptance-requirements.json').read_bytes()
        criteria.write_bytes(sample)
        command = [sys.executable, str(ROOT/'examples/evaluate_measurements.py'), '--binary', str(binary),
                   '--measurements', str(ROOT/'examples/measurement-evaluation-measurements.ndjson'),
                   '--references', str(ROOT/'examples/measurement-evaluation-reference.ndjson'),
                   '--requirements', str(criteria), '--output', str(output)]
        def execute(name, status=0, extra=(), launcher=None):
            invocation=list(command)
            if launcher is not None:invocation[1]=str(launcher)
            process = subprocess.run(invocation+list(extra), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
            assert process.returncode == status, (name, process.returncode, process.stderr)
            cases.append(dict(name=name, passed=True, exit_code=status))
        execute('pretty-printed-requirements-and-full-log-join')
        report = json.loads(output.read_text())
        assert report['kind'] == 'measurement_acceptance_run' and report['acceptance']['accepted']
        assert report['evaluation']['position_coverage'] == 0.75 and report['evaluation']['speed_coverage'] == 0.25
        assert report['inputs']['requirements_sha256'] == hashlib.sha256(sample).hexdigest()
        strict = json.loads(sample)
        strict['speed_mps']['min_coverage'] = 0.95
        criteria.write_text(json.dumps(strict, indent=2))
        execute('failed-coverage-writes-complete-report-and-exits-three', 3)
        assert not json.loads(output.read_text())['acceptance']['accepted']
        for name, data in [('raw-underflow', b'{"position_m":{"min_samples":1,"min_coverage":0,"max_error":1e-1000}}'),
                           ('adjacent-numeric-tokens', b'{"position_m":{"min_samples":1,"min_coverage":0,"max_error":1 e-2}}'),
                           ('duplicate-key', b'{"position_m":{},"position_m":{}}'),
                           ('oversized-criteria', b' '*65537)]:
            criteria.write_bytes(data)
            output.write_bytes(b'previous-report')
            execute(name, 2)
            assert output.read_bytes() == b'previous-report'
        criteria.write_bytes(sample)
        execute('output-cannot-overwrite-requirements', 2, ['--output', str(criteria)])
        assert criteria.read_bytes() == sample
        copied = directory/'adapter-copy.py'
        code=(ROOT/'examples/evaluate_measurements.py').read_bytes()
        copied.write_bytes(code)
        execute('output-cannot-overwrite-the-adapter', 2, ['--output', str(copied)], launcher=copied)
        assert copied.read_bytes()==code
        alias = directory/'alias.json'
        os.link(str(criteria), str(alias))
        execute('output-cannot-overwrite-hardlinked-requirements', 2, ['--output', str(alias)])
        assert criteria.read_bytes() == sample
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--web', action='store_true')
    args = parser.parse_args()
    started = time.monotonic()
    binary = args.binary.resolve()
    cases, checks, statistics = numerical_cases(binary)
    protocol, adapter = protocol_cases(binary), file_cases(binary)
    result = dict(status='passed', seed=SEED, numerical_cases=cases, numerical_case_count=len(cases), checks=checks,
                  protocol_cases=protocol, file_adapter_cases=adapter, statistics=statistics, decimal_precision=160,
                  source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  reference_sha256=hashlib.sha256((ROOT/'validation/measurement_evaluation_verify.py').read_bytes()).hexdigest(),
                  adapter_sha256=hashlib.sha256((ROOT/'examples/evaluate_measurements.py').read_bytes()).hexdigest(),
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), python=platform.python_version(),
                  elapsed_seconds=time.monotonic()-started, command='python '+' '.join(sys.argv))
    if args.web:
        process = subprocess.run(['node', '--test', 'web/measurement-acceptance.test.mjs'], cwd=ROOT,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120,
                                 env=dict(os.environ, MOONGROUND_CLI=str(binary)))
        assert process.returncode == 0, process.stdout.decode('utf-8','replace')
        result['web_interchange'] = dict(status='passed', source_sha256=hashlib.sha256((ROOT/'web/measurement-acceptance.test.mjs').read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes((json.dumps(portable_report(result), indent=2)+'\n').encode('utf-8'))
    print(json.dumps(dict(status='passed', numerical_cases=len(cases), checks=checks, protocol_cases=len(protocol), file_adapter_cases=len(adapter))))


if __name__ == '__main__':
    main()
