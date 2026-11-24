#!/usr/bin/env python3
"""Join measurement and metric-reference logs, then evaluate with native MoonGround.

The join retains two current records in memory and spools aligned NDJSON to a
temporary file. Metrics are computed by MoonGround, not by this adapter.
"""

import argparse
import contextlib
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

STATE_INPUT_VERSION = 1


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON field: ' + key)
        result[key] = value
    return result


def invalid_constant(value):
    raise ValueError('invalid JSON constant: ' + value)


def encode(value):
    return json.dumps(value, ensure_ascii=True, allow_nan=False, separators=(',', ':')).encode('utf-8')


def records(stream, label, digest, limit):
    previous = None
    line_number = 0
    while True:
        raw = stream.readline(limit + 2)
        if not raw:
            return
        line_number += 1
        digest.update(raw)
        size = len(raw) - int(raw.endswith(b'\n'))
        if size > limit:
            raise ValueError('{} line {} exceeds byte limit'.format(label, line_number))
        try:
            value = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_fields,
                               parse_float=Decimal, parse_constant=invalid_constant)
            if not isinstance(value, dict):
                raise ValueError('record must be an object')
            timestamp = value.get('timestamp_us')
            if not isinstance(timestamp, str):
                raise ValueError('timestamp_us must be an Int64 decimal string')
            clock = int(timestamp)
            if clock < 0 or clock > 9223372036854775807 or str(clock) != timestamp:
                raise ValueError('timestamp_us must be a canonical nonnegative Int64 string')
            if previous is not None and clock <= previous:
                raise ValueError('timestamps must strictly increase')
        except (ValueError, UnicodeError, RecursionError) as error:
            raise ValueError('{} line {}: {}'.format(label, line_number, error)) from error
        previous = clock
        # Preserve raw numeric tokens for MoonGround's strict parser, including
        # nonzero tokens that underflow binary64. Only timestamps route the join.
        yield clock, value, raw.rstrip(b'\r\n')


def empty_measurement(session_id, clock):
    return encode(dict(schema_version='0.2.0', session_id=session_id,
                       timestamp_us=str(clock), tracks=[], closed_segment_ids=[],
                       uncertainty_scope='conditional_on_fixed_calibration_camera_and_anchor'))


def digest_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def check_destination(output, inputs):
    if output is None:
        return
    for path in inputs:
        if output.resolve() == path.resolve() or (
                output.exists() and path.exists() and os.path.samefile(str(output), str(path))):
            raise ValueError('output must differ from the input logs and executable')


def compact_requirements(raw):
    if len(raw) > 65536:
        raise ValueError('requirements file exceeds 65536 bytes')
    text = raw.decode('utf-8')
    # Validate before removing whitespace, so malformed adjacent tokens cannot
    # be joined into a valid number. Keep numeric spellings for MoonGround.
    try:
        value = json.loads(text, object_pairs_hook=unique_fields, parse_float=str,
                           parse_int=str, parse_constant=invalid_constant)
    except RecursionError as error:
        raise ValueError('requirements nesting is too deep') from error
    if not isinstance(value, dict):
        raise ValueError('requirements must be a JSON object')
    result, quoted, escaped = [], False, False
    for character in text:
        if quoted:
            result.append(character)
            if escaped:
                escaped = False
            elif character == '\\':
                escaped = True
            elif character == '"':
                quoted = False
        elif character == '"':
            quoted = True
            result.append(character)
        elif character not in ' \r\n\t':
            result.append(character)
    return ''.join(result).encode('utf-8')


@contextlib.contextmanager
def measurement_stream(args, measurement_source):
    if measurement_source is None:
        with args.measurements.open('rb') as stream:
            yield stream, None
    else:
        with measurement_source.open() as snapshot:
            yield snapshot


def align(measured_file, reference_file, aligned, args, requirements):
    measured_hash, reference_hash = hashlib.sha256(), hashlib.sha256()
    join_counts = dict(paired_frames=0, measurement_only_frames=0, reference_only_frames=0)
    measured_rows = records(measured_file, 'measurement', measured_hash, args.max_line_bytes)
    reference_rows = records(reference_file, 'reference', reference_hash, args.max_line_bytes)
    measured, reference = next(measured_rows, None), next(reference_rows, None)
    session_id = args.session_id
    if session_id is None and measured is not None:
        session_id = measured[1].get('session_id')
    if not isinstance(session_id, str) or not session_id:
        raise ValueError('provide --session-id when the measurement log is empty')
    header = encode(dict(session_id=session_id, max_tracks=args.max_tracks, max_samples=args.max_samples))
    if requirements is not None:
        header = header[:-1]+b',"requirements":'+requirements+b'}'
    aligned.write(header+b'\n')
    while measured is not None or reference is not None:
        if reference is None or (measured is not None and measured[0] < reference[0]):
            clock, measured_data = measured[0], measured[2]
            reference_data = encode(dict(timestamp_us=str(clock), samples=[]))
            join_counts['measurement_only_frames'] += 1
            measured = next(measured_rows, None)
        elif measured is None or reference[0] < measured[0]:
            measured_data = empty_measurement(session_id, reference[0])
            reference_data = reference[2]
            join_counts['reference_only_frames'] += 1
            reference = next(reference_rows, None)
        else:
            measured_data, reference_data = measured[2], reference[2]
            join_counts['paired_frames'] += 1
            measured = next(measured_rows, None)
            reference = next(reference_rows, None)
        aligned.write(b'{"measurement":' + measured_data + b',"reference":' + reference_data + b'}\n')
    return session_id, join_counts, measured_hash.hexdigest(), reference_hash.hexdigest()


def evaluate(args, measurement_source=None):
    requirements_path = getattr(args, 'requirements', None)
    inputs = [args.references, args.binary, Path(__file__)]
    inputs += measurement_source.protected_paths if measurement_source is not None else [args.measurements]
    if requirements_path is not None:
        inputs.append(requirements_path)
    check_destination(args.output, inputs)
    raw_requirements, requirements = None, None
    if requirements_path is not None:
        with requirements_path.open('rb') as stream:
            raw_requirements = stream.read(65537)
        requirements = compact_requirements(raw_requirements)
    binary_hash = digest_file(args.binary)
    started = time.perf_counter()
    with tempfile.TemporaryFile('w+b') as aligned, tempfile.TemporaryFile('w+b') as output:
        with measurement_stream(args, measurement_source) as (measured_file, source_info), args.references.open('rb') as reference_file:
            if source_info is not None and args.output is not None and args.output.exists():
                if digest_file(args.output) in {source_info['input_sha256'], source_info['binary_sha256']}:
                    raise ValueError('output contains the replay input or producing executable')
            session_id, join_counts, measured_hash, reference_hash = align(
                measured_file, reference_file, aligned, args, requirements)
            if source_info is not None and measured_hash != source_info['results_sha256']:
                raise ValueError('measurement stream differs from the checked replay snapshot')
        # Release the read transaction and replay lock before native calculation.
        aligned.seek(0)
        command = [str(args.binary.resolve()), '--accept-measurements' if raw_requirements is not None else '--evaluate-measurements',
                   '--max-line-bytes', str(args.max_line_bytes)]
        process = subprocess.run(command, stdin=aligned, stdout=output, stderr=subprocess.PIPE,
                                 timeout=args.timeout)
        if process.returncode != 0 and not (raw_requirements is not None and process.returncode == 3):
            raise ValueError('MoonGround evaluation failed: ' + process.stderr.decode('utf-8', 'replace').strip())
        output.seek(0)
        report = json.loads(output.read().decode('utf-8'), parse_constant=invalid_constant)
        if raw_requirements is not None and (report.get('kind') != 'measurement_acceptance' or
                type(report.get('accepted')) is not bool or process.returncode != (0 if report['accepted'] else 3)):
            raise ValueError('native acceptance decision and exit status disagree')
    result = dict(schema_version='0.1.0', kind='measurement_evaluation_run',
                evaluation=report['evaluation'] if raw_requirements is not None else report,
                configuration=dict(session_id=session_id, max_tracks=args.max_tracks,
                                   max_samples=args.max_samples, max_line_bytes=args.max_line_bytes,
                                   timeout_seconds=args.timeout),
                inputs=dict(measurements_sha256=measured_hash,
                            references_sha256=reference_hash),
                alignment=join_counts, binary_sha256=binary_hash,
                adapter_sha256=digest_file(Path(__file__)),
                elapsed_seconds=time.perf_counter() - started)
    if source_info is not None:
        result['measurement_source'] = source_info
    if raw_requirements is not None:
        result['kind'] = 'measurement_acceptance_run'
        result['acceptance'] = {key: report[key] for key in ['accepted', 'requirements', 'checks']}
        result['inputs']['requirements_sha256'] = hashlib.sha256(raw_requirements).hexdigest()
    return result


def save_atomic(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile('wb', dir=str(path.parent), prefix='.evaluation-',
                                         suffix='.tmp', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(str(temporary), str(path))
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main(argv=None, measurement_source=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--measurements', type=Path, required=measurement_source is None)
    parser.add_argument('--references', type=Path, required=True)
    parser.add_argument('--requirements', type=Path,
                        help='explicit position_m/speed_mps JSON requirements; unmet checks return exit status 3')
    parser.add_argument('--session-id')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--max-tracks', type=int, default=4096)
    parser.add_argument('--max-samples', type=int, default=10000000)
    parser.add_argument('--max-line-bytes', type=int, default=1048576)
    parser.add_argument('--timeout', type=float, default=300.0,
                        help='native evaluator time limit in seconds, after joining input logs')
    args = parser.parse_args(argv)
    if not (1 <= args.max_tracks <= 4096 and 1 <= args.max_samples <= 2147483647 and
            1 <= args.max_line_bytes <= 16777216 and 0.0 < args.timeout < float('inf')):
        parser.error('invalid evaluation capacity or timeout')
    try:
        result = evaluate(args, measurement_source)
        content = (json.dumps(result, ensure_ascii=True, indent=2, allow_nan=False) + '\n').encode('utf-8')
        if args.output:
            save_atomic(args.output, content)
        else:
            sys.stdout.write(content.decode('utf-8'))
        return 3 if result.get('acceptance', {}).get('accepted') is False else 0
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        parser.exit(2, str(error) + '\n')


if __name__ == '__main__':
    sys.exit(main())
