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
CHECKPOINT_INPUT_VERSION = 1
STATE_CONTINUATION_VERSION = 1
EVALUATION_STORE_VERSION = 1
REFERENCE_PREFIX_DOMAIN = b'moonground/reference-prefix/v1\0'


class RawNumber(str):
    """An original JSON numeric token, distinct from a JSON string."""


def exact_json(value):
    if isinstance(value, RawNumber):
        return str(value)
    if isinstance(value, str) or value is None or isinstance(value, bool):
        return json.dumps(value, ensure_ascii=True, allow_nan=False)
    if isinstance(value, list):
        return '['+','.join(exact_json(item) for item in value)+']'
    if isinstance(value, dict):
        return '{'+','.join(json.dumps(key,ensure_ascii=True)+':'+exact_json(item)
                            for key,item in value.items())+'}'
    raise ValueError('unsupported checkpoint JSON value')


def resume_input(path):
    with path.open('rb') as stream:
        raw = stream.read(1048577)
    return resume_bytes(raw)


def resume_bytes(raw):
    if len(raw) > 1048576:
        raise ValueError('resume file exceeds 1048576 bytes')
    try:
        document = json.loads(raw.decode('utf-8'),object_pairs_hook=unique_fields,
                              parse_float=RawNumber,parse_int=RawNumber,parse_constant=invalid_constant)
        stack = [(document,0)]
        while stack:
            value,depth = stack.pop()
            if depth > 32:
                raise ValueError('resume JSON exceeds nesting depth 32')
            if isinstance(value,dict):
                stack.extend((child,depth+1) for child in value.values())
            elif isinstance(value,list):
                stack.extend((child,depth+1) for child in value)
        checkpoint = document.get('resume') if isinstance(document,dict) else None
        if not isinstance(checkpoint,dict):
            raise ValueError('resume file needs a complete evaluation resume object')
        limits = {}
        for name in ['max_tracks','max_samples']:
            token = checkpoint.get(name)
            if not isinstance(token,RawNumber) or len(token)>10 or not token.isascii() or not token.isdecimal():
                raise ValueError('resume capacity must be a positive integer')
            limits[name] = int(token)
        session_id = checkpoint.get('session_id')
        if type(session_id) is not str or not session_id:
            raise ValueError('resume session_id must be a nonempty string')
        encoded = exact_json(checkpoint).encode('utf-8')
        if len(encoded) > 16384:
            raise ValueError('evaluation checkpoint exceeds 16384 bytes')
        return encoded,session_id,limits,hashlib.sha256(raw).hexdigest(),document
    except RecursionError as error:
        raise ValueError('resume JSON nesting is too deep') from error


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


def unsigned_token(value, label):
    if not isinstance(value, RawNumber) or not value.isascii() or not value.isdecimal() or len(value) > 19 or str(int(value)) != value or int(value) > 9223372036854775807:
        raise ValueError('invalid previous ' + label)
    return int(value)


def clock_string(value):
    if value is None:
        return None
    if type(value) is not str or not value.isascii() or not value.isdecimal() or len(value) > 19 or str(int(value)) != value or int(value) > 9223372036854775807:
        raise ValueError('invalid previous timestamp')
    return int(value)


def checked_digest(value):
    if type(value) is not str or len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
        raise ValueError('invalid previous prefix digest')
    return value


def state_continuation(document):
    source, cursor = document.get('measurement_source'), document.get('reference_cursor')
    if document.get('state_scope') != 'through_committed_measurements' or not isinstance(source, dict) or not isinstance(cursor, dict):
        raise ValueError('state continuation needs a previous --committed-only report')
    if source.get('kind') != 'sqlite_replay' or unsigned_token(cursor.get('version'), 'reference cursor version') != 1:
        raise ValueError('unsupported state continuation report')
    previous = {name:unsigned_token(source.get(name), 'replay '+name)
                for name in ['frames', 'input_offset', 'input_bytes']}
    previous.update({name:checked_digest(source.get(name))
                     for name in ['results_sha256', 'input_sha256', 'binary_sha256']})
    previous['complete'] = source.get('complete')
    through = clock_string(source.get('last_timestamp_us'))
    previous['last_timestamp_us'] = None if through is None else str(through)
    if type(previous['complete']) is not bool or previous['input_offset'] > previous['input_bytes'] or (
            previous['complete'] and previous['input_offset'] != previous['input_bytes']) or (
            (previous['frames'] == 0) != (through is None)):
        raise ValueError('invalid previous replay progress')
    if clock_string(cursor.get('through_timestamp_us')) != through or clock_string(document['resume'].get('last_timestamp_us')) != through:
        raise ValueError('previous checkpoint and committed watermark disagree')
    count = cursor.get('prefix_records')
    if type(count) is not str or not count.isascii() or not count.isdecimal() or len(count) > 19 or str(int(count)) != count or int(count) > 9223372036854775807:
        raise ValueError('invalid previous reference record count')
    if through is None and int(count) != 0:
        raise ValueError('empty replay has a nonempty reference prefix')
    return previous, dict(prefix_records=int(count), record_prefix_sha256=checked_digest(cursor.get('record_prefix_sha256')),
                          through_timestamp_us=through)


class _ReferenceWindow:
    """Scan a reference log, checking history and yielding only the new window."""
    def __init__(self, stream, through, previous, limit, check):
        self.digest = hashlib.sha256()
        self.rows = records(stream, 'reference', self.digest, limit)
        self.prefix = hashlib.sha256(REFERENCE_PREFIX_DOMAIN)
        self.through = clock_string(through)
        self.after = previous['through_timestamp_us'] if previous else None
        self.previous = previous
        self.old_count = previous['prefix_records'] if previous else 0
        self.total = self.consumed = self.evaluated = 0
        self.pending = b''
        self.check = check
        if previous and self.old_count == 0 and self.prefix.hexdigest() != previous['record_prefix_sha256']:
            raise ValueError('previously evaluated reference prefix has changed')

    def readline(self, size=-1):
        if size == 0:
            return b''
        while not self.pending:
            self.check()
            row = next(self.rows, None)
            if row is None:
                if self.total < self.old_count:
                    raise ValueError('previously evaluated reference records were removed')
                return b''
            clock, _, payload = row
            self.total += 1
            if self.total <= self.old_count:
                if self.after is None or clock > self.after:
                    raise ValueError('previous reference prefix exceeds its watermark')
            elif self.after is not None and clock <= self.after:
                raise ValueError('reference backfill overlaps the previous committed watermark')
            if self.through is not None and clock <= self.through:
                self.prefix.update(len(payload).to_bytes(8, 'big'))
                self.prefix.update(payload)
                self.consumed += 1
            if self.previous and self.total == self.old_count and self.prefix.hexdigest() != self.previous['record_prefix_sha256']:
                raise ValueError('previously evaluated reference prefix has changed')
            if self.total > self.old_count and self.through is not None and clock <= self.through:
                self.evaluated += 1
                self.pending = payload + b'\n'
        count = len(self.pending) if size < 0 else min(size, len(self.pending))
        data, self.pending = self.pending[:count], self.pending[count:]
        return data

    def report(self):
        return dict(version=1, prefix_records=str(self.consumed), record_prefix_sha256=self.prefix.hexdigest(),
                    through_timestamp_us=None if self.through is None else str(self.through),
                    after_timestamp_us=None if self.after is None else str(self.after),
                    total_records=str(self.total), evaluated_records=str(self.evaluated),
                    deferred_records=str(self.total-self.consumed), file_sha256=self.digest.hexdigest())


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
        options = {'previous':args.previous_source} if hasattr(args, 'previous_source') else {}
        with measurement_source.open(**options) as snapshot:
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
    header = getattr(args,'resume_header',None)
    if header is None:
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


def evaluate(args, measurement_source=None, resume_content=None):
    args = argparse.Namespace(**vars(args))
    requirements_path = getattr(args, 'requirements', None)
    inputs = [args.references, args.binary, Path(__file__)]
    inputs += measurement_source.protected_paths if measurement_source is not None else [args.measurements]
    if requirements_path is not None:
        inputs.append(requirements_path)
    resume_path = getattr(args,'resume',None)
    if resume_path is not None:
        inputs.append(resume_path)
    check_destination(args.output, inputs)
    resume_hash = None
    committed_only = getattr(args, 'committed_only', False)
    if committed_only and measurement_source is None:
        raise ValueError('--committed-only requires --state')
    resuming = resume_path is not None or resume_content is not None
    checkpoint_mode = getattr(args,'checkpoint',False) or resuming or committed_only
    previous_cursor = None
    if resuming:
        if measurement_source is not None and not committed_only:
            raise ValueError('--resume with --state requires --committed-only')
        raw_checkpoint,session_id,limits,resume_hash,document = resume_input(resume_path) if resume_path is not None else resume_bytes(resume_content)
        if committed_only:
            args.previous_source, previous_cursor = state_continuation(document)
        if args.session_id is not None and args.session_id != session_id:
            raise ValueError('resume session_id differs from the requested session')
        args.session_id = session_id
        for name,value in limits.items():
            if getattr(args,name) is not None and getattr(args,name) != value:
                raise ValueError('resume capacity differs from the requested '+name)
            setattr(args,name,value)
        args.resume_header = b'{"resume":'+raw_checkpoint+b'}'
    if args.max_tracks is None:
        args.max_tracks = 4096
    if args.max_samples is None:
        args.max_samples = 10000000
    raw_requirements, requirements = None, None
    if requirements_path is not None:
        with requirements_path.open('rb') as stream:
            raw_requirements = stream.read(65537)
        requirements = compact_requirements(raw_requirements)
    binary_hash = digest_file(args.binary)
    started = time.perf_counter()
    reference_window = None
    with tempfile.TemporaryFile('w+b') as aligned, tempfile.TemporaryFile('w+b') as output:
        with measurement_stream(args, measurement_source) as (measured_file, source_info), args.references.open('rb') as reference_file:
            if source_info is not None and args.output is not None and args.output.exists():
                if digest_file(args.output) in {source_info['input_sha256'], source_info['binary_sha256']}:
                    raise ValueError('output contains the replay input or producing executable')
            selected_reference = reference_file
            if committed_only:
                reference_window = _ReferenceWindow(reference_file, source_info['last_timestamp_us'],
                                                    previous_cursor, args.max_line_bytes, measured_file.check)
                selected_reference = reference_window
            session_id, join_counts, measured_hash, reference_hash = align(
                measured_file, selected_reference, aligned, args, requirements)
            if source_info is not None and measured_hash != source_info['evaluated_results_sha256']:
                raise ValueError('measurement stream differs from the checked replay snapshot')
        # Release the read transaction and replay lock before native calculation.
        aligned.seek(0)
        mode = '--accept-measurements' if raw_requirements is not None else '--evaluate-measurements'
        command = [str(args.binary.resolve()), mode+('-checkpoint' if checkpoint_mode else ''),
                   '--max-line-bytes', str(args.max_line_bytes)]
        process = subprocess.run(command, stdin=aligned, stdout=output, stderr=subprocess.PIPE,
                                 timeout=args.timeout)
        if process.returncode != 0 and not (raw_requirements is not None and process.returncode == 3):
            raise ValueError('MoonGround evaluation failed: ' + process.stderr.decode('utf-8', 'replace').strip())
        output.seek(0)
        report = json.loads(output.read().decode('utf-8'), parse_constant=invalid_constant)
        next_checkpoint = None
        if checkpoint_mode:
            if set(report) != {'report','resume'} or not isinstance(report['resume'],dict):
                raise ValueError('native evaluation checkpoint envelope is incomplete')
            next_checkpoint, report = report['resume'], report['report']
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
    if reference_window is not None:
        result['state_scope'] = 'through_committed_measurements'
        result['reference_cursor'] = reference_window.report()
    if checkpoint_mode:
        result['resume'] = next_checkpoint
        result['alignment_scope'] = 'current_inputs'
    if resume_hash is not None:
        result['inputs']['resume_sha256'] = resume_hash
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


def report_bytes(result):
    return (json.dumps(result, ensure_ascii=True, indent=2, allow_nan=False)+'\n').encode('utf-8')


def evaluate_stored(args, measurement_source):
    if measurement_source is None or not args.committed_only or args.resume is not None:
        raise ValueError('--evaluation-state requires --state --committed-only and replaces --resume')
    if not hasattr(measurement_source, 'evaluation_store'):
        raise ValueError('select a release with durable evaluation state support')
    store = measurement_source.evaluation_store(args.evaluation_state,
                                               args.max_evaluation_mib if args.max_evaluation_mib is not None else 256,
                                               args.evaluation_timeout if args.evaluation_timeout is not None else 60.0)
    protected = [args.binary, args.references, Path(__file__)]+measurement_source.protected_paths
    protected += [path for path in [args.requirements, args.output] if path is not None]
    for destination in store.protected_paths:
        check_destination(destination, protected)
    check_destination(args.output, store.protected_paths)
    with store.open() as writer:
        number, parent, previous = writer.head
        result = evaluate(args, measurement_source, resume_content=previous)
        result['evaluation_state'] = dict(version=1, sequence=str(number+1), parent_sha256=parent)
        content = report_bytes(result)
        writer.append(content)
    return result, content


def main(argv=None, measurement_source=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--measurements', type=Path, required=measurement_source is None)
    parser.add_argument('--references', type=Path, required=True)
    parser.add_argument('--requirements', type=Path,
                        help='explicit position_m/speed_mps JSON requirements; unmet checks return exit status 3')
    parser.add_argument('--checkpoint',action='store_true',help='include complete evaluation continuation state in the report')
    parser.add_argument('--committed-only', action='store_true',help='evaluate references through the committed replay watermark and save a continuation cursor')
    parser.add_argument('--resume',type=Path,help='continue from a checkpoint report using later, disjoint log chunks')
    parser.add_argument('--evaluation-state', type=Path, help='atomically store reports and resume from the latest committed evaluation')
    parser.add_argument('--max-evaluation-mib', type=int)
    parser.add_argument('--evaluation-timeout', type=float)
    parser.add_argument('--session-id')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--max-tracks', type=int)
    parser.add_argument('--max-samples', type=int)
    parser.add_argument('--max-line-bytes', type=int, default=1048576)
    parser.add_argument('--timeout', type=float, default=300.0,
                        help='native evaluator time limit in seconds, after joining input logs')
    args = parser.parse_args(argv)
    if not ((args.max_tracks is None or 1 <= args.max_tracks <= 4096) and
            (args.max_samples is None or 1 <= args.max_samples <= 2147483647) and
            1 <= args.max_line_bytes <= 16777216 and 0.0 < args.timeout < float('inf')):
        parser.error('invalid evaluation capacity or timeout')
    try:
        if args.evaluation_state is not None:
            result, content = evaluate_stored(args, measurement_source)
        else:
            if args.max_evaluation_mib is not None or args.evaluation_timeout is not None:
                raise ValueError('evaluation state budgets require --evaluation-state')
            result = evaluate(args, measurement_source)
            content = report_bytes(result)
        if args.output:
            save_atomic(args.output, content)
        else:
            sys.stdout.write(content.decode('utf-8'))
        return 3 if result.get('acceptance', {}).get('accepted') is False else 0
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        parser.exit(2, str(error) + '\n')


if __name__ == '__main__':
    sys.exit(main())
