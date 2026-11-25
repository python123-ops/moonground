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
STATE_CONTINUATION_VERSION = 1
EVALUATION_STORE_VERSION = 1
EVALUATION_SNAPSHOT_VERSION = 1
EVALUATION_APPLICATION_ID = 0x4D474531
MAX_EVALUATION_REPORT = 1048576
EVALUATION_TABLE = 'CREATE TABLE evaluations (sequence INTEGER PRIMARY KEY, parent_sha256 TEXT, sha256 TEXT NOT NULL, document BLOB NOT NULL)'


def digest_file(path, check=None):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            if check is not None:
                check()
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


def _connect(path, create=False, readonly=False):
    if path.exists():
        regular(path)
    elif not create:
        raise ValueError('replay state does not exist')
    connection = sqlite3.connect(path.as_uri() + ('?mode=ro' if readonly else '?mode=rwc' if create else '?mode=rw'),
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
        connection.execute('BEGIN')
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
            connection.execute('PRAGMA synchronous=EXTRA')
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


def _file_path(path):
    path = path.absolute()
    return path.parent.resolve() / path.name


def _deadline(timeout, max_state_mib):
    if not math.isfinite(timeout) or not 0 < timeout <= 86400 or type(max_state_mib) is not int or not 1 <= max_state_mib <= 1048576:
        raise ValueError('state budget and timeout must be positive and bounded')
    end = time.monotonic() + timeout
    def check():
        if time.monotonic() >= end:
            raise ValueError('state operation timed out; no destination was published')
    return check


def _inspect(connection, check, max_state_mib):
    check()
    def interrupted():
        check()
        return 0
    # Bound long integrity scans as well as the incremental copy.
    connection.set_progress_handler(interrupted, 1000)
    expected = {
        'job': 'CREATE TABLE job (id INTEGER PRIMARY KEY CHECK(id=1), document TEXT NOT NULL)',
        'results': 'CREATE TABLE results (sequence INTEGER PRIMARY KEY, payload BLOB NOT NULL)',
    }
    actual = connection.execute('SELECT type,name,sql FROM sqlite_master ORDER BY name LIMIT 3').fetchall()
    if actual != [('table', name, expected[name]) for name in sorted(expected)]:
        raise ValueError('unsupported replay database structure')
    size = connection.execute('PRAGMA page_count').fetchone()[0] * connection.execute('PRAGMA page_size').fetchone()[0]
    if size > max_state_mib * 1024 * 1024:
        raise ValueError('state exceeds the requested database budget')
    if connection.execute('PRAGMA integrity_check(1)').fetchall() != [('ok',)]:
        raise ValueError('replay database failed its integrity check')
    if connection.execute('SELECT count(*) FROM job').fetchone()[0] != 1:
        raise ValueError('state must contain exactly one initialized replay')
    value = _document(connection)
    if value is None or (value['frames'] and value['resume'] is None):
        raise ValueError('state has no initialized replay or checkpoint')
    digest = hashlib.sha256()
    previous = None
    for (payload,) in connection.execute('SELECT payload FROM results ORDER BY sequence'):
        check()
        if not isinstance(payload, bytes) or len(payload) > MAX_OUTPUT_LINE or not payload.endswith(b'\n') or len(payload.splitlines()) != 1:
            raise ValueError('invalid stored measurement bytes')
        record = decode(payload)
        if not isinstance(record, dict) or record.get('schema_version') != '0.2.0' or 'resume' in record:
            raise ValueError('invalid stored measurement record')
        timestamp = record.get('timestamp_us')
        if not isinstance(timestamp, str) or not timestamp.isascii() or not timestamp.isdecimal() or not 0 <= int(timestamp) <= 9223372036854775807 or str(int(timestamp)) != timestamp:
            raise ValueError('invalid stored measurement timestamp')
        if previous is not None and int(timestamp) <= previous:
            raise ValueError('stored measurement timestamps are not increasing')
        previous = int(timestamp)
        digest.update(payload)
    check()
    return dict(_status(connection, value), integrity='ok', results_sha256=digest.hexdigest(),
                checkpoint_sha256=hashlib.sha256(value['resume'].encode('utf-8')).hexdigest() if value['resume'] else None)


def verify(state_path, max_state_mib=256, timeout=60.0):
    state_path = _file_path(state_path)
    check = _deadline(timeout, max_state_mib)
    with state_lock(state_path), contextlib.closing(_connect(state_path)) as connection:
        connection.execute('BEGIN')
        return _inspect(connection, check, max_state_mib)


class _MeasurementRows:
    """Read one verified result row at a time, retaining file readline semantics."""
    def __init__(self, connection, check, report, start_sequence=0):
        self.cursor = connection.execute('SELECT payload FROM results WHERE sequence>? ORDER BY sequence', (start_sequence,))
        self.check = check
        self.pending = b''
        self.digest = hashlib.sha256()
        self.report = report
        report['evaluated_results_sha256'] = self.digest.hexdigest()

    def readline(self, size=-1):
        self.check()
        if size == 0:
            return b''
        if not self.pending:
            row = self.cursor.fetchone()
            if row is None:
                return b''
            self.pending = row[0]
            self.digest.update(self.pending)
            self.report['evaluated_results_sha256'] = self.digest.hexdigest()
        count = len(self.pending) if size < 0 else min(size, len(self.pending))
        result, self.pending = self.pending[:count], self.pending[count:]
        return result


@contextlib.contextmanager
def _measurement_errors():
    try:
        yield
    except sqlite3.Error as error:
        raise ValueError('cannot read replay measurements: ' + str(error)) from error


class MeasurementSource:
    """A checked, bounded stream of one committed SQLite replay snapshot."""
    def __init__(self, state_path, allow_partial=False, max_state_mib=256, timeout=60.0):
        self.path = _file_path(state_path)
        self.allow_partial = allow_partial
        self.max_state_mib = max_state_mib
        self.timeout = timeout
        self.protected_paths = [self.path, Path(__file__)] + [
            self.path.with_name(self.path.name + suffix)
            for suffix in ['-journal', '-wal', '-shm', '.lock']]

    def evaluation_store(self, path, max_state_mib=256, timeout=60.0):
        return EvaluationStore(path, max_state_mib, timeout)

    @contextlib.contextmanager
    def open(self, previous=None):
        check = _deadline(self.timeout, self.max_state_mib)
        # Share the replay/backup lock: reading never delays an active writer's
        # commit, and both the inspection and the stream see the same snapshot.
        regular(self.path)
        with _measurement_errors(), state_lock(self.path), contextlib.closing(_connect(self.path, readonly=True)) as connection:
            connection.execute('BEGIN')
            report = _inspect(connection, check, self.max_state_mib)
            if not report['complete'] and not self.allow_partial:
                raise ValueError('replay is incomplete; finish it or explicitly use --allow-partial')
            row = connection.execute('SELECT payload FROM results ORDER BY sequence DESC LIMIT 1').fetchone()
            report['last_timestamp_us'] = decode(row[0])['timestamp_us'] if row else None
            start = 0
            if previous is not None:
                for name in ['frames', 'input_offset', 'input_bytes']:
                    if type(previous.get(name)) is not int or not 0 <= previous[name] <= 9223372036854775807:
                        raise ValueError('invalid previous replay counter: ' + name)
                if type(previous.get('complete')) is not bool:
                    raise ValueError('invalid previous replay completion flag')
                if any(previous.get(name) != report[name] for name in ['input_sha256', 'input_bytes', 'binary_sha256']):
                    raise ValueError('replay input or producing executable differs from the previous report')
                start = previous['frames']
                if report['frames'] < start or report['input_offset'] < previous['input_offset'] or (
                        previous['complete'] and (not report['complete'] or report['frames'] != start)):
                    raise ValueError('replay moved behind the previous committed snapshot')
                digest, last = hashlib.sha256(), None
                for (payload,) in connection.execute('SELECT payload FROM results WHERE sequence<=? ORDER BY sequence', (start,)):
                    check()
                    digest.update(payload)
                    last = decode(payload)['timestamp_us']
                if digest.hexdigest() != previous.get('results_sha256') or last != previous.get('last_timestamp_us'):
                    raise ValueError('previously evaluated replay results have changed')
                report['previous_frames'] = start
                report['previous_results_sha256'] = digest.hexdigest()
            report['evaluated_frames'] = report['frames'] - start
            report.update(kind='sqlite_replay', partial_requested=self.allow_partial,
                          max_state_mib=self.max_state_mib, timeout_seconds=self.timeout,
                          reader_sha256=digest_file(Path(__file__), check))
            rows = _MeasurementRows(connection, check, report, start)
            try:
                yield rows, report
                check()
            finally:
                # An unfinished SQLite cursor otherwise keeps the file open on
                # Windows even after Connection.close(), until its reader dies.
                rows.cursor.close()


def _new_state_path(path, source):
    if os.path.lexists(str(path)):
        raise ValueError('destination already exists; choose a new state or backup file')
    for suffix in ['', '-journal', '-wal', '-shm', '.lock']:
        if path == source.with_name(source.name + suffix):
            raise ValueError('destination overlaps source state files')
    for suffix in ['-journal', '-wal', '-shm']:
        if os.path.lexists(str(path.with_name(path.name + suffix))):
            raise ValueError('destination has existing SQLite journal files')


def _sync_directory(path):
    if os.name != 'nt':
        descriptor = os.open(str(path), os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def _database_snapshot(source_path, destination, max_state_mib, timeout, connect, inspect, expected_digest=None):
    source_path, destination = _file_path(source_path), _file_path(destination)
    check = _deadline(timeout, max_state_mib)
    regular(source_path)
    if source_path.stat().st_size > max_state_mib * 1024 * 1024:
        raise ValueError('state exceeds the requested database budget')
    _new_state_path(destination, source_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    with state_lock(source_path), state_lock(destination):
        _new_state_path(destination, source_path)
        if expected_digest is not None:
            # A backup is a standalone, closed database. Never recover or apply
            # an external journal to bytes whose checksum the operator supplied.
            if any(os.path.lexists(str(source_path.with_name(source_path.name + suffix))) for suffix in ['-journal', '-wal', '-shm']):
                raise ValueError('backup must be a standalone database without journal files')
            if source_path.stat().st_size > max_state_mib * 1024 * 1024:
                raise ValueError('backup exceeds the requested database budget')
            if digest_file(source_path, check) != expected_digest:
                raise ValueError('backup SHA-256 differs from the expected checksum')
        try:
            with contextlib.closing(connect(source_path, readonly=expected_digest is not None)) as source:
                source.execute('BEGIN')
                before = inspect(source, check, max_state_mib)
                with tempfile.NamedTemporaryFile(dir=str(destination.parent), prefix='.moonground-snapshot-', delete=False) as stream:
                    temporary = Path(stream.name)
                with contextlib.closing(sqlite3.connect(str(temporary), isolation_level=None)) as target:
                    target.execute('PRAGMA synchronous=EXTRA')
                    def progress(status, remaining, total):
                        check()
                        if total * source.execute('PRAGMA page_size').fetchone()[0] > max_state_mib * 1024 * 1024:
                            raise ValueError('snapshot exceeds the requested database budget')
                    source.backup(target, pages=256, progress=progress, sleep=0.02)
                    target.execute('BEGIN')
                    for pragma in ['application_id', 'user_version']:
                        if source.execute('PRAGMA '+pragma).fetchone() != target.execute('PRAGMA '+pragma).fetchone():
                            raise ValueError('snapshot database identity differs from its source')
                    after = inspect(target, check, max_state_mib)
                    if before != after:
                        raise ValueError('snapshot differs from the committed source state')
            if expected_digest is not None and digest_file(source_path, check) != expected_digest:
                raise ValueError('backup changed while it was being restored')
            with temporary.open('r+b') as stream:
                os.fsync(stream.fileno())
            digest, size = digest_file(temporary, check), temporary.stat().st_size
            check()
            # Hard-link publication cannot overwrite a path created after the
            # initial check. The staged database is on the same filesystem.
            os.link(str(temporary), str(destination))
            _sync_directory(destination.parent)
            return dict(after, sha256=digest, bytes=size)
        finally:
            if temporary is not None:
                for suffix in ['', '-journal', '-wal', '-shm']:
                    staged = temporary.with_name(temporary.name + suffix)
                    if staged.exists():
                        staged.unlink()


def _snapshot(source_path, destination, max_state_mib, timeout, expected_digest=None):
    return _database_snapshot(source_path, destination, max_state_mib, timeout, _connect, _inspect, expected_digest)


def backup(state_path, destination, max_state_mib=256, timeout=60.0):
    return _snapshot(state_path, destination, max_state_mib, timeout)


def restore(backup_path, state_path, sha256, max_state_mib=256, timeout=60.0):
    if not isinstance(sha256, str) or len(sha256) != 64 or any(c not in '0123456789abcdefABCDEF' for c in sha256):
        raise ValueError('restore requires the backup SHA-256 checksum')
    return _snapshot(backup_path, state_path, max_state_mib, timeout, sha256.lower())


class _EvaluationNumber(str):
    """Retain numeric tokens while inspecting stored reports."""


def _evaluation_number(token):
    value = float(token)
    nonzero = any(c in '123456789' for c in token.lower().split('e')[0])
    if not math.isfinite(value) or (value == 0.0 and nonzero):
        raise ValueError('stored evaluation contains a nonfinite or underflowed number')
    return _EvaluationNumber(token)


def _evaluation_document(payload, sequence, parent):
    if not isinstance(payload, bytes) or len(payload) > MAX_EVALUATION_REPORT:
        raise ValueError('evaluation report exceeds 1048576 bytes or is not a BLOB')
    def fields(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate evaluation report field: ' + key)
            result[key] = value
        return result
    def invalid(value):
        raise ValueError('invalid evaluation JSON constant: ' + value)
    try:
        document = json.loads(payload.decode('utf-8'), object_pairs_hook=fields,
                              parse_int=_evaluation_number, parse_float=_evaluation_number, parse_constant=invalid)
        stack = [(document, 0)]
        while stack:
            value, depth = stack.pop()
            if depth > 32:
                raise ValueError('evaluation report exceeds nesting depth 32')
            if isinstance(value, dict):
                stack.extend((child, depth+1) for child in value.values())
            elif isinstance(value, list):
                stack.extend((child, depth+1) for child in value)
    except (UnicodeError, RecursionError) as error:
        raise ValueError('invalid evaluation report JSON') from error
    if not isinstance(document, dict) or document.get('schema_version') != '0.1.0' or document.get('kind') not in (
            'measurement_evaluation_run', 'measurement_acceptance_run') or document.get('state_scope') != 'through_committed_measurements':
        raise ValueError('evaluation state requires a committed-only report')
    metadata = document.get('evaluation_state')
    if not isinstance(metadata, dict) or set(metadata) != {'version', 'sequence', 'parent_sha256'} or (
            type(metadata['version']) is not _EvaluationNumber or metadata['version'] != '1') or (
            type(metadata['sequence']) is not str or metadata['sequence'] != str(sequence)) or metadata['parent_sha256'] != parent:
        raise ValueError('evaluation report generation or parent differs from its record')
    inputs = document.get('inputs')
    if not isinstance(inputs, dict) or inputs.get('resume_sha256') != parent:
        raise ValueError('evaluation resume digest differs from its parent record')
    source, cursor, checkpoint = (document.get(name) for name in ['measurement_source', 'reference_cursor', 'resume'])
    if not isinstance(source, dict) or source.get('kind') != 'sqlite_replay' or not isinstance(cursor, dict) or not isinstance(checkpoint, dict):
        raise ValueError('evaluation state has no replay snapshot, reference cursor or checkpoint')
    for name in ['frames', 'input_offset', 'input_bytes']:
        token = source.get(name)
        if type(token) is not _EvaluationNumber or not token.isascii() or not token.isdecimal() or len(token) > 19 or str(int(token)) != token or int(token) > 9223372036854775807:
            raise ValueError('invalid stored evaluation counter: ' + name)
    for name in ['input_sha256', 'binary_sha256', 'results_sha256']:
        token = source.get(name)
        if type(token) is not str or len(token) != 64 or any(c not in '0123456789abcdef' for c in token):
            raise ValueError('invalid stored evaluation source digest')
    clock = source.get('last_timestamp_us')
    if clock is not None and (type(clock) is not str or not clock.isascii() or not clock.isdecimal() or len(clock) > 19 or str(int(clock)) != clock or int(clock) > 9223372036854775807):
        raise ValueError('invalid stored evaluation timestamp')
    if (int(source['frames']) == 0) != (clock is None) or type(source.get('complete')) is not bool or (
            int(source['input_offset']) > int(source['input_bytes'])) or (
            source['complete'] and source['input_offset'] != source['input_bytes']):
        raise ValueError('invalid stored evaluation progress')
    if type(cursor.get('through_timestamp_us')) is not type(clock) or type(checkpoint.get('last_timestamp_us')) is not type(clock) or cursor.get('through_timestamp_us') != clock or checkpoint.get('last_timestamp_us') != clock:
        raise ValueError('stored evaluation watermarks disagree')
    return document


@contextlib.contextmanager
def _evaluation_errors():
    try:
        yield
    except sqlite3.Error as error:
        raise ValueError('cannot access evaluation state: ' + str(error)) from error


def _evaluation_connect(path, readonly=False):
    regular(path)
    connection = sqlite3.connect(path.as_uri()+('?mode=ro' if readonly else '?mode=rw'),
                                uri=True, isolation_level=None, timeout=1.0)
    try:
        if connection.execute('PRAGMA application_id').fetchone()[0] != EVALUATION_APPLICATION_ID or connection.execute('PRAGMA user_version').fetchone()[0] != 1:
            raise ValueError('not a supported MoonGround evaluation state database')
        return connection
    except BaseException:
        connection.close()
        raise


def _evaluation_initialize(path):
    # Publish a fully initialized, closed database. A crash before publication
    # cannot leave an empty file at the requested state path.
    temporary = None
    try:
        if any(os.path.lexists(str(path.with_name(path.name+suffix))) for suffix in ['-journal', '-wal', '-shm']):
            raise ValueError('new evaluation state has existing SQLite journal files')
        with tempfile.NamedTemporaryFile(dir=str(path.parent), prefix='.moonground-evaluation-', delete=False) as stream:
            temporary = Path(stream.name)
        with contextlib.closing(sqlite3.connect(str(temporary), isolation_level=None)) as connection:
            connection.execute('PRAGMA synchronous=EXTRA')
            connection.execute('BEGIN IMMEDIATE')
            connection.execute('PRAGMA application_id='+str(EVALUATION_APPLICATION_ID))
            connection.execute('PRAGMA user_version=1')
            connection.execute(EVALUATION_TABLE)
            connection.execute('COMMIT')
        with temporary.open('r+b') as stream:
            os.fsync(stream.fileno())
        os.link(str(temporary), str(path))
        _sync_directory(path.parent)
    finally:
        if temporary is not None:
            for suffix in ['', '-journal', '-wal', '-shm']:
                item = temporary.with_name(temporary.name+suffix)
                if item.exists():
                    item.unlink()


def _evaluation_progress(previous, source):
    if previous is not None and (any(source[name] != previous[name]
            for name in ['input_sha256', 'input_bytes', 'binary_sha256']) or
            int(source['frames']) < int(previous['frames']) or
            int(source['input_offset']) < int(previous['input_offset']) or
            (previous['complete'] and (not source['complete'] or source['frames'] != previous['frames']))):
        raise ValueError('evaluation history changed its replay identity or moved backwards')


def _evaluation_head(connection, check, max_state_mib):
    check()
    def interrupted():
        check()
        return 0
    connection.set_progress_handler(interrupted, 1000)
    if connection.execute('SELECT type,name,sql FROM sqlite_master ORDER BY name LIMIT 2').fetchall() != [('table', 'evaluations', EVALUATION_TABLE)]:
        raise ValueError('unsupported evaluation state structure')
    if connection.execute('PRAGMA page_count').fetchone()[0] * connection.execute('PRAGMA page_size').fetchone()[0] > max_state_mib*1024*1024:
        raise ValueError('evaluation state exceeds its database budget')
    if connection.execute('PRAGMA integrity_check(1)').fetchall() != [('ok',)]:
        raise ValueError('evaluation state failed its integrity check')
    number, previous, latest, previous_source = 0, None, None, None
    with contextlib.closing(connection.execute('SELECT sequence,parent_sha256,sha256,document FROM evaluations ORDER BY sequence')) as rows:
        for sequence, parent, digest, payload in rows:
            check()
            number += 1
            if sequence != number or parent != previous or not isinstance(payload, bytes) or hashlib.sha256(payload).hexdigest() != digest:
                raise ValueError('evaluation state record sequence, parent or digest differs')
            document = _evaluation_document(payload, sequence, parent)
            source = document['measurement_source']
            _evaluation_progress(previous_source, source)
            previous_source = source
            previous, latest = digest, payload
    check()
    return number, previous, latest


class _EvaluationWriter:
    def __init__(self, connection, head, max_state_mib, timeout):
        self.connection, self.head = connection, head
        self.max_state_mib, self.timeout = max_state_mib, timeout

    def append(self, payload):
        check = _deadline(self.timeout, self.max_state_mib)
        number, previous, raw = self.head
        if number >= 9223372036854775807:
            raise ValueError('evaluation state generation is exhausted')
        document = _evaluation_document(payload, number+1, previous)
        if raw is not None:
            saved = json.loads(raw, parse_int=_EvaluationNumber, parse_float=_EvaluationNumber)
            _evaluation_progress(saved['measurement_source'], document['measurement_source'])
        digest = hashlib.sha256(payload).hexdigest()
        self.connection.execute('BEGIN IMMEDIATE')
        try:
            if _evaluation_head(self.connection, check, self.max_state_mib) != self.head:
                raise ValueError('evaluation state changed during calculation')
            self.connection.execute('INSERT INTO evaluations(sequence,parent_sha256,sha256,document) VALUES(?,?,?,?)',
                                    (number+1, previous, digest, sqlite3.Binary(payload)))
            check()
            self.connection.execute('COMMIT')
        except BaseException:
            if self.connection.in_transaction:
                self.connection.execute('ROLLBACK')
            raise
        finally:
            self.connection.set_progress_handler(None, 0)
        self.head = number+1, digest, payload
        return digest


def _evaluation_summary(connection, head):
    number, digest, payload = head
    parent = connection.execute('SELECT parent_sha256 FROM evaluations WHERE sequence=?', (number,)).fetchone() if payload else None
    latest = _evaluation_document(payload, number, parent[0]) if payload else None
    source = latest['measurement_source'] if latest else {}
    return dict(kind='evaluation_state', version=1, integrity='ok', records=str(number),
                latest_sha256=digest, latest_frames=str(source['frames']) if latest else None,
                last_timestamp_us=source.get('last_timestamp_us'), complete=source.get('complete'),
                input_sha256=source.get('input_sha256'), binary_sha256=source.get('binary_sha256'),
                evaluation_binary_sha256=latest.get('binary_sha256') if latest else None,
                adapter_sha256=latest.get('adapter_sha256') if latest else None,
                logical_state_bytes=connection.execute('PRAGMA page_count').fetchone()[0]*connection.execute('PRAGMA page_size').fetchone()[0])


def _evaluation_snapshot_info(connection, check, max_state_mib):
    report = _evaluation_summary(connection, _evaluation_head(connection, check, max_state_mib))
    check()
    return report


class EvaluationStore:
    """Persist complete evaluation reports independently of the replay database."""
    def __init__(self, path, max_state_mib=256, timeout=60.0):
        self.path = _file_path(path)
        self.max_state_mib, self.timeout = max_state_mib, timeout
        self.protected_paths = [self.path]+[self.path.with_name(self.path.name+suffix)
                                           for suffix in ['-journal', '-wal', '-shm', '.lock']]

    @contextlib.contextmanager
    def open(self):
        check = _deadline(self.timeout, self.max_state_mib)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with _evaluation_errors(), state_lock(self.path):
            if not self.path.exists():
                _evaluation_initialize(self.path)
            with contextlib.closing(_evaluation_connect(self.path)) as connection:
                connection.execute('PRAGMA synchronous=EXTRA')
                page_size = connection.execute('PRAGMA page_size').fetchone()[0]
                connection.execute('PRAGMA max_page_count='+str(self.max_state_mib*1024*1024//page_size))
                connection.execute('BEGIN')
                head = _evaluation_head(connection, check, self.max_state_mib)
                connection.execute('COMMIT')
                connection.set_progress_handler(None, 0)
                # No SQLite transaction is held during native calculation.
                yield _EvaluationWriter(connection, head, self.max_state_mib, self.timeout)

    def status(self):
        return self._read()[0]

    def _read(self, sequence=None):
        check = _deadline(self.timeout, self.max_state_mib)
        with _evaluation_errors(), state_lock(self.path), contextlib.closing(_evaluation_connect(self.path)) as connection:
            connection.execute('BEGIN')
            number, digest, payload = _evaluation_head(connection, check, self.max_state_mib)
            summary = _evaluation_summary(connection, (number, digest, payload))
            if sequence is not None:
                if type(sequence) is not int or not 1 <= sequence <= number:
                    raise ValueError('evaluation sequence is not present')
                digest, payload = connection.execute('SELECT sha256,document FROM evaluations WHERE sequence=?', (sequence,)).fetchone()
            elif not payload:
                return summary, None, None
            return summary, digest, payload

    def export(self, destination, sequence=None, replace_existing=False):
        destination = _file_path(destination)
        if os.path.lexists(str(destination)):
            regular(destination)
            if not replace_existing:
                raise ValueError('evaluation export destination already exists; use --replace-existing or a new path')
        for protected in self.protected_paths+[Path(__file__)]:
            if destination == protected or (destination.exists() and protected.exists() and os.path.samefile(destination, protected)):
                raise ValueError('evaluation export overlaps protected state files')
        summary, digest, payload = self._read(sequence)
        if payload is None:
            raise ValueError('evaluation state has no committed reports')
        if destination.exists() and digest_file(destination) in {summary['input_sha256'], summary['binary_sha256'], summary['evaluation_binary_sha256'], summary['adapter_sha256']}:
            raise ValueError('evaluation export contains the replay input or producing executable')
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile('wb', dir=str(destination.parent), prefix='.moonground-evaluation-export-', delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            if replace_existing:
                os.replace(str(temporary), str(destination))
            else:
                os.link(str(temporary), str(destination))
            _sync_directory(destination.parent)
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()
        return dict(sequence=str(sequence) if sequence is not None else summary['records'], sha256=digest, bytes=len(payload))

    def backup(self, destination, expected_report_sha256=None):
        if expected_report_sha256 is not None:
            if type(expected_report_sha256) is not str or len(expected_report_sha256) != 64 or any(c not in '0123456789abcdefABCDEF' for c in expected_report_sha256):
                raise ValueError('expected report SHA-256 must contain 64 hexadecimal digits')
            expected_report_sha256 = expected_report_sha256.lower()
        def inspect(connection, check, budget):
            report = _evaluation_snapshot_info(connection, check, budget)
            if expected_report_sha256 is not None and report['latest_sha256'] != expected_report_sha256:
                raise ValueError('evaluation head differs from the expected report SHA-256')
            return report
        with _evaluation_errors():
            return _database_snapshot(self.path, destination, self.max_state_mib, self.timeout,
                                      _evaluation_connect, inspect)

    def restore(self, backup_path, sha256):
        if type(sha256) is not str or len(sha256) != 64 or any(c not in '0123456789abcdefABCDEF' for c in sha256):
            raise ValueError('restore requires the evaluation backup SHA-256 checksum')
        with _evaluation_errors():
            return _database_snapshot(backup_path, self.path, self.max_state_mib, self.timeout,
                                      _evaluation_connect, _evaluation_snapshot_info, sha256.lower())


def add_state_arguments(parser):
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--max-state-mib', type=int, default=256)
    parser.add_argument('--timeout-seconds', type=float, default=60.0)


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


def add_evaluation_state_arguments(parser):
    parser.add_argument('--evaluation-state', type=Path, required=True)
    parser.add_argument('--max-evaluation-mib', type=int, default=256)
    parser.add_argument('--evaluation-timeout', type=float, default=60.0)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    add_run_arguments(commands.add_parser('run'))
    commands.add_parser('status').add_argument('--state', type=Path, required=True)
    output = commands.add_parser('export')
    output.add_argument('--state', type=Path, required=True)
    output.add_argument('--output', type=Path, required=True)
    output.add_argument('--replace-existing', action='store_true')
    add_state_arguments(commands.add_parser('verify'))
    snapshot = commands.add_parser('backup')
    add_state_arguments(snapshot)
    snapshot.add_argument('--output', type=Path, required=True)
    recovery = commands.add_parser('restore')
    add_state_arguments(recovery)
    recovery.add_argument('--backup', type=Path, required=True)
    recovery.add_argument('--sha256', required=True)
    add_evaluation_state_arguments(commands.add_parser('evaluation-status'))
    evaluation_export = commands.add_parser('evaluation-export')
    add_evaluation_state_arguments(evaluation_export)
    evaluation_export.add_argument('--output', type=Path, required=True)
    evaluation_export.add_argument('--sequence', type=int)
    evaluation_export.add_argument('--replace-existing', action='store_true')
    evaluation_backup = commands.add_parser('evaluation-backup')
    add_evaluation_state_arguments(evaluation_backup)
    evaluation_backup.add_argument('--output', type=Path, required=True)
    evaluation_backup.add_argument('--expected-report-sha256')
    evaluation_restore = commands.add_parser('evaluation-restore')
    add_evaluation_state_arguments(evaluation_restore)
    evaluation_restore.add_argument('--backup', type=Path, required=True)
    evaluation_restore.add_argument('--sha256', required=True)
    args = parser.parse_args(argv)
    try:
        if args.command in ('evaluation-status', 'evaluation-export', 'evaluation-backup', 'evaluation-restore'):
            store = EvaluationStore(args.evaluation_state, args.max_evaluation_mib, args.evaluation_timeout)
            if args.command == 'evaluation-status':
                value = store.status()
            elif args.command == 'evaluation-export':
                value = store.export(args.output, args.sequence, args.replace_existing)
            elif args.command == 'evaluation-backup':
                value = store.backup(args.output, args.expected_report_sha256)
            else:
                value = store.restore(args.backup, args.sha256)
        elif args.command == 'run':
            value = replay(args.binary, args.input, args.state, args.batch_frames, args.batch_bytes,
                           args.max_state_mib, args.timeout_seconds, args.max_frames)
        elif args.command == 'status':
            value = status(args.state.resolve())
        elif args.command == 'verify':
            value = verify(args.state, args.max_state_mib, args.timeout_seconds)
        elif args.command == 'backup':
            value = backup(args.state, args.output, args.max_state_mib, args.timeout_seconds)
        elif args.command == 'restore':
            value = restore(args.backup, args.state, args.sha256, args.max_state_mib, args.timeout_seconds)
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
