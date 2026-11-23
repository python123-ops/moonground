#!/usr/bin/env python3
"""Run bounded native measurement batches with transactional disk checkpoints."""

import argparse
import contextlib
import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time

APPLICATION_ID = 0x4D474A31
MAX_LINE = 16 * 1024 * 1024
MAX_OUTPUT_LINE = 32 * 1024 * 1024
MAX_BATCH_OUTPUT = 128 * 1024 * 1024


def digest_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(data)
    return digest.hexdigest()


def regular(path):
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode) or getattr(value, 'st_file_attributes', 0) & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0):
        raise ValueError('expected a regular file: ' + path.name)


def encode(value):
    return json.dumps(value, ensure_ascii=True, separators=(',', ':'), allow_nan=False)


def decode(data):
    def fields(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate JSON field: ' + key)
            result[key] = value
        return result
    def number(value):
        result = float(value)
        if not math.isfinite(result):
            raise ValueError('nonfinite JSON number')
        return result
    def constant(value):
        raise ValueError('invalid JSON constant: ' + value)
    return json.loads(data, object_pairs_hook=fields, parse_float=number, parse_constant=constant)


@contextlib.contextmanager
def state_lock(path):
    lock = path.with_name(path.name + '.lock')
    if lock.exists():
        regular(lock)
    with lock.open('a+b') as stream:
        stream.seek(0, 2)
        if stream.tell() == 0:
            stream.write(b'\0')
            stream.flush()
        stream.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise ValueError('another replay holds this state file') from error
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == 'nt':
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def _connect(path, create=False):
    if path.exists():
        regular(path)
    elif not create:
        raise ValueError('replay state does not exist')
    connection = sqlite3.connect(path.as_uri() + ('?mode=rwc' if create else '?mode=rw'),
                                 uri=True, isolation_level=None, timeout=1.0)
    try:
        app = connection.execute('PRAGMA application_id').fetchone()[0]
        if app != APPLICATION_ID:
            if app != 0 or not create or connection.execute("SELECT count(*) FROM sqlite_master").fetchone()[0]:
                raise ValueError('state is not a MoonGround replay database')
            connection.execute('BEGIN IMMEDIATE')
            connection.execute('PRAGMA application_id=' + str(APPLICATION_ID))
            connection.execute('PRAGMA user_version=1')
            connection.execute('CREATE TABLE job (id INTEGER PRIMARY KEY CHECK(id=1), document TEXT NOT NULL)')
            connection.execute('CREATE TABLE results (sequence INTEGER PRIMARY KEY, payload BLOB NOT NULL)')
            connection.execute('COMMIT')
        if connection.execute('PRAGMA user_version').fetchone()[0] != 1:
            raise ValueError('unsupported replay database version')
        return connection
    except BaseException:
        connection.close()
        raise


def _document(connection):
    row = connection.execute('SELECT document FROM job WHERE id=1').fetchone()
    if row is None:
        if connection.execute('SELECT count(*) FROM results').fetchone()[0]:
            raise ValueError('result rows have no committed job metadata')
        return None
    value = decode(row[0])
    fields = {'schema_version', 'input_sha256', 'input_bytes', 'binary_sha256',
              'offset', 'frames', 'commits', 'resume', 'complete'}
    if not isinstance(value, dict) or set(value) != fields or type(value['schema_version']) is not int or value['schema_version'] != 1:
        raise ValueError('unsupported replay state fields')
    for name in ['input_bytes', 'offset', 'frames', 'commits']:
        if type(value[name]) is not int or not 0 <= value[name] <= 9223372036854775807:
            raise ValueError('invalid replay state counter: ' + name)
    for name in ['input_sha256', 'binary_sha256']:
        text = value[name]
        if not isinstance(text, str) or len(text) != 64 or any(c not in '0123456789abcdef' for c in text):
            raise ValueError('invalid replay state digest')
    if type(value['complete']) is not bool or value['offset'] > value['input_bytes']:
        raise ValueError('invalid replay state progress')
    if value['complete'] and value['offset'] != value['input_bytes']:
        raise ValueError('complete replay has an unfinished input offset')
    if value['resume'] is not None:
        if not isinstance(value['resume'], str) or len(value['resume'].encode('utf-8')) > MAX_OUTPUT_LINE:
            raise ValueError('invalid saved checkpoint text')
        record = decode(value['resume'])
        if not isinstance(record, dict) or set(record) != {'resume'} or not isinstance(record['resume'], dict):
            raise ValueError('invalid saved checkpoint envelope')
    count, first, last = connection.execute('SELECT count(*), min(sequence), max(sequence) FROM results').fetchone()
    if count != value['frames'] or (count and (first != 1 or last != count)):
        raise ValueError('result rows and committed checkpoint disagree')
    return value


def _status(connection, value):
    if value is None:
        raise ValueError('state has no initialized replay')
    return dict(schema_version=1, frames=value['frames'], commits=value['commits'],
                input_offset=value['offset'], input_bytes=value['input_bytes'], complete=value['complete'],
                input_sha256=value['input_sha256'], binary_sha256=value['binary_sha256'],
                logical_state_bytes=connection.execute('PRAGMA page_count').fetchone()[0] * connection.execute('PRAGMA page_size').fetchone()[0])


def status(path):
    with contextlib.closing(_connect(path)) as connection:
        return _status(connection, _document(connection))


def _line(stream):
    data = stream.readline(MAX_LINE + 2)
    if data and (len(data.rstrip(b'\r\n')) > MAX_LINE or (not data.endswith(b'\n') and len(data) > MAX_LINE)):
        raise ValueError('input line exceeds 16 MiB')
    if data and not data.rstrip(b'\r\n'):
        raise ValueError('blank input record')
    return data


def _fingerprint(stream):
    value = os.fstat(stream.fileno())
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns


def _native(binary, source, output, errors, timeout):
    source.seek(0)
    process = subprocess.Popen([str(binary), '--stream-checkpoint', '--max-line-bytes', str(MAX_LINE)],
                               stdin=source, stdout=output, stderr=errors)
    started = time.monotonic()
    try:
        while process.poll() is None:
            if time.monotonic() - started > timeout:
                raise ValueError('native batch timed out; committed progress is retained')
            if os.fstat(output.fileno()).st_size > MAX_BATCH_OUTPUT or os.fstat(errors.fileno()).st_size > 65536:
                raise ValueError('native batch output exceeded its limit')
            time.sleep(0.01)
        output.seek(0)
        errors.seek(0)
        diagnostic = errors.read(65537)
        if process.returncode or diagnostic:
            raise ValueError('native batch failed (exit {}): {}'.format(process.returncode, diagnostic[:4096].decode('utf-8', 'replace').strip()))
        if os.fstat(output.fileno()).st_size > MAX_BATCH_OUTPUT:
            raise ValueError('native batch output exceeded its limit')
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()


def _output_line(stream):
    data = stream.readline(MAX_OUTPUT_LINE + 1)
    if not data or not data.endswith(b'\n') or len(data) > MAX_OUTPUT_LINE:
        raise ValueError('native batch returned a missing, partial or oversized record')
    return data


def _store_batch(connection, output, count, before, offset, complete):
    after = dict(before, offset=offset, frames=before['frames'] + count,
                 commits=before['commits'] + 1, complete=complete)
    connection.execute('BEGIN IMMEDIATE')
    try:
        for index in range(count):
            data = _output_line(output)
            value = decode(data)
            if not isinstance(value, dict) or value.get('schema_version') != '0.2.0' or 'resume' in value:
                raise ValueError('native batch returned an invalid measurement record')
            connection.execute('INSERT INTO results(sequence,payload) VALUES(?,?)',
                               (before['frames'] + index + 1, sqlite3.Binary(data)))
        raw = _output_line(output)
        checkpoint = decode(raw)
        if not isinstance(checkpoint, dict) or set(checkpoint) != {'resume'} or not isinstance(checkpoint['resume'], dict) or output.read(1):
            raise ValueError('native batch did not end with exactly one checkpoint')
        # Preserve the native checkpoint spelling, including all numeric tokens.
        after['resume'] = raw.decode('utf-8').rstrip('\r\n')
        connection.execute('UPDATE job SET document=? WHERE id=1', (encode(after),))
        connection.execute('COMMIT')
        return after
    except BaseException:
        if connection.in_transaction:
            connection.execute('ROLLBACK')
        raise


def replay(binary, source_path, state_path, batch_frames=128, batch_bytes=4194304,
           max_state_mib=256, timeout=60.0, max_frames=None):
    binary, source_path, state_path = binary.resolve(), source_path.resolve(), state_path.resolve()
    if not 1 <= batch_frames <= 4096 or not 1 <= batch_bytes <= 64 * 1024 * 1024:
        raise ValueError('batch-frames must be 1..4096 and batch-bytes 1..67108864')
    if not 1 <= max_state_mib <= 1048576 or not math.isfinite(timeout) or not 0 < timeout <= 86400:
        raise ValueError('state budget and timeout must be positive and bounded')
    if max_frames is not None and (type(max_frames) is not int or max_frames < 1):
        raise ValueError('max-frames must be a positive integer')
    regular(binary)
    regular(source_path)
    for protected in [binary, source_path]:
        if state_path == protected or (state_path.exists() and os.path.samefile(state_path, protected)):
            raise ValueError('state must be separate from the input and executable')
    state_path.parent.mkdir(parents=True, exist_ok=True)
    with state_lock(state_path), source_path.open('rb') as source:
        stamp = _fingerprint(source)
        digest = hashlib.sha256()
        for data in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(data)
        if _fingerprint(source) != stamp:
            raise ValueError('input changed while its hash was read')
        source.seek(0)
        header = _line(source)
        if not header:
            raise ValueError('input has no configuration record')
        initial_offset = source.tell()
        identity = dict(input_sha256=digest.hexdigest(), input_bytes=stamp[2], binary_sha256=digest_file(binary))
        with contextlib.closing(_connect(state_path, create=not state_path.exists())) as connection:
            connection.execute('PRAGMA journal_mode=DELETE')
            connection.execute('PRAGMA synchronous=FULL')
            page_size = connection.execute('PRAGMA page_size').fetchone()[0]
            pages = max_state_mib * 1024 * 1024 // page_size
            if connection.execute('PRAGMA page_count').fetchone()[0] > pages:
                raise ValueError('existing state exceeds the requested database budget')
            connection.execute('PRAGMA max_page_count=' + str(pages))
            current = _document(connection)
            if current is None:
                current = dict(schema_version=1, offset=initial_offset, frames=0, commits=0, resume=None, complete=False, **identity)
                connection.execute('INSERT INTO job(id,document) VALUES(1,?)', (encode(current),))
            if any(current[key] != value for key, value in identity.items()):
                raise ValueError('input or native executable differs from the committed job')
            if current['offset'] < initial_offset or (current['frames'] > 0 and current['resume'] is None):
                raise ValueError('committed input offset or checkpoint is invalid')
            processed = 0
            while not current['complete'] and (max_frames is None or processed < max_frames):
                if _fingerprint(source) != stamp:
                    raise ValueError('input changed during replay; committed progress is retained')
                source.seek(current['offset'])
                with tempfile.TemporaryFile(dir=str(state_path.parent)) as batch,\
                     tempfile.TemporaryFile(dir=str(state_path.parent)) as output,\
                     tempfile.TemporaryFile(dir=str(state_path.parent)) as errors:
                    batch.write((current['resume'].encode('utf-8') if current['resume'] else header.rstrip(b'\r\n')) + b'\n')
                    count, size = 0, 0
                    limit = min(batch_frames, max_frames - processed) if max_frames is not None else batch_frames
                    while count < limit:
                        start = source.tell()
                        data = _line(source)
                        if not data:
                            break
                        if count and size + len(data) > batch_bytes:
                            source.seek(start)
                            break
                        batch.write(data.rstrip(b'\r\n') + b'\n')
                        count, size = count + 1, size + len(data)
                    offset = source.tell()
                    batch.flush()
                    if digest_file(binary) != identity['binary_sha256']:
                        raise ValueError('native executable changed during replay')
                    _native(binary, batch, output, errors, timeout)
                    if _fingerprint(source) != stamp or digest_file(binary) != identity['binary_sha256']:
                        raise ValueError('input or executable changed during the native batch')
                    current = _store_batch(connection, output, count, current, offset, offset == stamp[2])
                    processed += count
            return _status(connection, current)


def export(state_path, destination, replace_existing=False):
    state_path = state_path.resolve()
    destination = destination.absolute()
    destination = destination.parent.resolve() / destination.name
    if os.path.lexists(str(destination)):
        regular(destination)
        if not replace_existing:
            raise ValueError('export destination already exists; choose a new file or use --replace-existing')
    for protected in [state_path] + [state_path.with_name(state_path.name + suffix) for suffix in ['-journal', '-wal', '-shm', '.lock']]:
        if destination == protected or (destination.exists() and protected.exists() and os.path.samefile(destination, protected)):
            raise ValueError('export destination overlaps the state files')
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    with contextlib.closing(_connect(state_path)) as connection:
        connection.execute('BEGIN')
        value = _document(connection)
        if value is None:
            raise ValueError('state has no initialized replay')
        if destination.exists() and digest_file(destination) in {value['input_sha256'], value['binary_sha256']}:
            raise ValueError('export destination contains the source input or executable')
        try:
            digest, count = hashlib.sha256(), 0
            with tempfile.NamedTemporaryFile('wb', dir=str(destination.parent), prefix='.moonground-export-', delete=False) as output:
                temporary = Path(output.name)
                for (payload,) in connection.execute('SELECT payload FROM results ORDER BY sequence'):
                    output.write(payload)
                    digest.update(payload)
                    count += 1
                output.flush()
                os.fsync(output.fileno())
            os.replace(str(temporary), str(destination))
            return dict(frames=count, complete=value['complete'], sha256=digest.hexdigest())
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()


def add_run_arguments(parser, binary=True):
    if binary:
        parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--batch-frames', type=int, default=128)
    parser.add_argument('--batch-bytes', type=int, default=4194304)
    parser.add_argument('--max-state-mib', type=int, default=256)
    parser.add_argument('--timeout-seconds', type=float, default=60.0)
    parser.add_argument('--max-frames', type=int)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    add_run_arguments(commands.add_parser('run'))
    commands.add_parser('status').add_argument('--state', type=Path, required=True)
    output = commands.add_parser('export')
    output.add_argument('--state', type=Path, required=True)
    output.add_argument('--output', type=Path, required=True)
    output.add_argument('--replace-existing', action='store_true')
    args = parser.parse_args(argv)
    try:
        if args.command == 'run':
            value = replay(args.binary, args.input, args.state, args.batch_frames, args.batch_bytes,
                           args.max_state_mib, args.timeout_seconds, args.max_frames)
        elif args.command == 'status':
            value = status(args.state.resolve())
        else:
            value = export(args.state, args.output, args.replace_existing)
        print(encode(value))
        return 0
    except KeyboardInterrupt:
        parser.exit(130, 'replay interrupted; committed progress is retained\n')
    except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
        parser.exit(2, str(error) + '\n')


if __name__ == '__main__':
    sys.exit(main())
