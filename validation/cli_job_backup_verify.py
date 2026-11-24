#!/usr/bin/env python3
"""Verify SQLite snapshots, failed publication and exact native continuation."""

import argparse
import contextlib
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from unittest import mock

from cli_jobs_verify import execute, fixture, jobs, native, records, wait_line
from public_reports import portable_report

ROOT = Path(__file__).resolve().parent.parent


def fault_worker(source, target, phase):
    link = os.link
    def paused(before, after):
        if phase == 'before':
            print('paused', flush=True)
            sys.stdin.read(1)
        link(before, after)
        if phase == 'after':
            print('paused', flush=True)
            sys.stdin.read(1)
    with mock.patch.object(jobs.os, 'link', side_effect=paused):
        jobs.backup(source, target)


def suite(binary):
    cases = []
    def passed(name):
        cases.append(dict(name=name, passed=True))
    with tempfile.TemporaryDirectory(prefix='moonground-backup-') as temporary:
        directory = Path(temporary)/'space \u6d4b\u8bd5'
        directory.mkdir()
        source, state = directory/'input.ndjson', directory/'state.sqlite'
        source.write_bytes(records(fixture()))
        baseline = native(binary, '--stream', source.read_bytes())
        prefix = b''.join(baseline.splitlines(keepends=True)[:9])
        jobs.replay(binary, source, state, batch_frames=4, max_frames=9)
        initial = jobs.status(state)
        verified = jobs.verify(state)
        assert verified['frames'] == 9 and verified['integrity'] == 'ok'
        assert verified['results_sha256'] == hashlib.sha256(prefix).hexdigest()
        passed('verify-hashes-raw-committed-results')
        snapshot = directory/'snapshot.sqlite'
        report = jobs.backup(state, snapshot)
        assert report['sha256'] == jobs.digest_file(snapshot)
        assert report['bytes'] == snapshot.stat().st_size
        assert {key: report[key] for key in verified} == verified
        assert jobs.status(state) == initial
        passed('partial-backup-preserves-offset-checkpoint-and-results')
        frozen = snapshot.read_bytes()
        jobs.replay(binary, source, state, batch_frames=5)
        assert snapshot.read_bytes() == frozen
        passed('source-progress-does-not-change-the-backup')
        recovered = directory/'recovered.sqlite'
        restored = jobs.restore(snapshot, recovered, report['sha256'].upper())
        assert {key: restored[key] for key in verified} == verified
        exported = directory/'prefix.ndjson'
        jobs.export(recovered, exported)
        assert exported.read_bytes() == prefix
        passed('restore-accepts-uppercase-checksum-and-preserves-raw-prefix')
        jobs.replay(binary, source, recovered, batch_frames=7)
        output = directory/'complete.ndjson'
        jobs.export(recovered, output)
        assert output.read_bytes() == baseline
        assert jobs.replay(binary, source, recovered)['commits'] == jobs.status(recovered)['commits']
        passed('restored-prefix-continues-without-duplicate-or-missing-results')
        complete = directory/'complete.sqlite'
        saved = jobs.backup(recovered, complete)
        final = directory/'final.sqlite'
        jobs.restore(complete, final, saved['sha256'])
        assert jobs.replay(binary, source, final)['complete']
        assert jobs.verify(final)['results_sha256'] == hashlib.sha256(baseline).hexdigest()
        passed('completed-backup-restores-idempotently')
        config = directory/'config-only.ndjson'
        config.write_bytes(records(fixture()[:1]))
        config_state = directory/'config-only.sqlite'
        jobs.replay(binary, config, config_state)
        config_snapshot = directory/'config-only-backup.sqlite'
        config_report = jobs.backup(config_state, config_snapshot)
        jobs.restore(config_snapshot, directory/'config-restored.sqlite', config_report['sha256'])
        assert config_report['complete'] and config_report['frames'] == 0
        passed('configuration-only-job-can-be-backed-up-and-restored')

        def rejected(name, operation, destination=None):
            before = {path: path.read_bytes() for path in [source, state, snapshot, recovered]}
            try:
                operation()
            except (OSError, ValueError, sqlite3.Error):
                pass
            else:
                raise AssertionError(name+' was accepted')
            assert all(path.read_bytes() == data for path, data in before.items()), name
            if destination is not None:
                assert not destination.exists(), name
            assert not list(directory.glob('.moonground-snapshot-*')), name
            passed(name)

        rejected('backup-never-replaces-an-existing-file', lambda: jobs.backup(state, snapshot))
        rejected('restore-never-replaces-an-existing-state', lambda: jobs.restore(snapshot, recovered, report['sha256']))
        rejected('backup-cannot-replace-source-state', lambda: jobs.backup(state, state))
        for suffix in ['.lock', '-journal', '-wal', '-shm']:
            target = state.with_name(state.name+suffix)
            rejected('backup-refuses-source-sidecar-'+suffix, lambda target=target: jobs.backup(state, target))
        for name, digest in [('wrong', '0'*64), ('malformed', 'not-a-checksum')]:
            target = directory/(name+'.sqlite')
            rejected('restore-rejects-'+name+'-checksum', lambda target=target, digest=digest: jobs.restore(snapshot, target, digest), target)
        target = directory/'journal-conflict.sqlite'
        (directory/'journal-conflict.sqlite-journal').write_bytes(b'operator-owned journal')
        rejected('restore-refuses-existing-destination-journal', lambda: jobs.restore(snapshot, target, report['sha256']), target)
        (directory/'journal-conflict.sqlite-journal').unlink()
        journal = snapshot.with_name(snapshot.name+'-journal')
        journal.write_bytes(b'not part of the signed backup')
        rejected('restore-refuses-external-backup-journal', lambda: jobs.restore(snapshot, target, report['sha256']), target)
        journal.unlink()
        for name, change in [
            ('future-schema', lambda c: c.execute('PRAGMA user_version=2')),
            ('foreign-application', lambda c: c.execute('PRAGMA application_id=1')),
            ('missing-result', lambda c: c.execute('DELETE FROM results WHERE sequence=3')),
            ('invalid-result-json', lambda c: c.execute("UPDATE results SET payload=? WHERE sequence=1", (sqlite3.Binary(b'{\n'),))),
            ('text-instead-of-blob', lambda c: c.execute("UPDATE results SET payload='{}' WHERE sequence=1")),
            ('extra-trigger', lambda c: c.execute('CREATE TRIGGER surprise AFTER INSERT ON results BEGIN DELETE FROM results; END')),
            ('extra-table', lambda c: c.execute('CREATE TABLE unrelated(value TEXT)')),
            ('repeated-timestamp', lambda c: c.execute('UPDATE results SET payload=(SELECT payload FROM results WHERE sequence=1) WHERE sequence=2')),
        ]:
            invalid = directory/(name+'-backup.sqlite')
            shutil.copyfile(snapshot, invalid)
            with contextlib.closing(sqlite3.connect(str(invalid))) as connection:
                change(connection)
                connection.commit()
            rejected('restore-rejects-'+name, lambda invalid=invalid: jobs.restore(invalid, target, jobs.digest_file(invalid)), target)
        for name, data in [('truncated', frozen[:100]), ('foreign-file', b'not a database')]:
            invalid = directory/(name+'-backup.sqlite')
            invalid.write_bytes(data)
            rejected('restore-rejects-'+name, lambda invalid=invalid: jobs.restore(invalid, target, jobs.digest_file(invalid)), target)
        with mock.patch.object(jobs.os, 'fsync', side_effect=OSError(errno.ENOSPC, 'injected full disk')):
            rejected('sync-full-disk-publishes-no-backup', lambda: jobs.backup(state, target), target)
        real_connect = sqlite3.connect
        class FullConnection(sqlite3.Connection):
            def backup(self, *args, **kwargs):
                raise OSError(errno.ENOSPC, 'injected full disk during SQLite copy')
        def full_connect(*args, **kwargs):
            kwargs['factory'] = FullConnection
            return real_connect(*args, **kwargs)
        with mock.patch.object(jobs.sqlite3, 'connect', side_effect=full_connect):
            rejected('copy-full-disk-publishes-no-backup', lambda: jobs.backup(state, target), target)
        with mock.patch.object(jobs.os, 'link', side_effect=OSError('injected publication failure')):
            rejected('failed-publication-retains-source-and-removes-staging', lambda: jobs.backup(state, target), target)
        def collide(before, after):
            Path(after).write_bytes(b'concurrent operator file')
            os_link(before, after)
        os_link = os.link
        with mock.patch.object(jobs.os, 'link', side_effect=collide):
            rejected('publication-race-preserves-the-concurrent-file', lambda: jobs.backup(state, target))
        assert target.read_bytes() == b'concurrent operator file'
        target.unlink()
        rejected('expired-operation-publishes-no-backup', lambda: jobs.backup(state, target, timeout=1e-12), target)
        for name, options in [('nan-timeout', dict(timeout=float('nan'))), ('zero-budget', dict(max_state_mib=0))]:
            rejected(name, lambda options=options: jobs.backup(state, target, **options), target)
        with jobs.state_lock(state):
            rejected('backup-refuses-an-active-replay', lambda: jobs.backup(state, target), target)
            rejected('verify-refuses-an-active-replay', lambda: jobs.verify(state))
        with jobs.state_lock(snapshot):
            rejected('restore-refuses-an-active-backup-file', lambda: jobs.restore(snapshot, target, report['sha256']), target)
        large = directory/'large.ndjson'
        large.write_bytes(records(fixture(512, 10)))
        large_state = directory/'large.sqlite'
        jobs.replay(binary, large, large_state, max_state_mib=16)
        assert large_state.stat().st_size > 1024*1024
        rejected('backup-refuses-a-source-over-budget', lambda: jobs.backup(large_state, target, max_state_mib=1), target)
        rejected('verify-refuses-a-source-over-budget', lambda: jobs.verify(large_state, max_state_mib=1))
        saved_large = jobs.backup(large_state, directory/'large-backup.sqlite', max_state_mib=16)
        rejected('restore-refuses-an-oversized-backup', lambda: jobs.restore(directory/'large-backup.sqlite', target, saved_large['sha256'], max_state_mib=1), target)
        altered = directory/'changed.ndjson'
        altered.write_bytes(source.read_bytes()+b'{}\n')
        untouched = directory/'untouched.sqlite'
        jobs.restore(snapshot, untouched, report['sha256'])
        rejected('restored-job-still-refuses-a-different-input', lambda: jobs.replay(binary, altered, untouched))

        for phase in ['before', 'after']:
            crash_dir = directory/('crash-'+phase)
            crash_dir.mkdir()
            target = crash_dir/'snapshot.sqlite'
            child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '_fault', str(state), str(target), phase],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                assert wait_line(child) == b'paused'
                child.kill()
                child.communicate(timeout=15)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.communicate(timeout=15)
            assert jobs.verify(state)['frames'] == 24
            if phase == 'before':
                assert not target.exists()
                jobs.backup(state, target)
            assert jobs.verify(target)['results_sha256'] == hashlib.sha256(baseline).hexdigest()
            recovered_crash = crash_dir/'restored.sqlite'
            jobs.restore(target, recovered_crash, jobs.digest_file(target))
            assert jobs.replay(binary, source, recovered_crash)['complete']
            passed('hard-kill-'+phase+'-snapshot-publication-recovers')

        interrupted = directory/'interrupted.sqlite'
        child = subprocess.Popen([sys.executable, str(ROOT/'validation/cli_jobs_verify.py'), '_fault', str(binary), str(source), str(interrupted), 'before'],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            assert wait_line(child) == b'paused'
            child.kill()
            child.communicate(timeout=15)
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate(timeout=15)
        assert interrupted.with_name(interrupted.name+'-journal').exists()
        interrupted_backup = directory/'interrupted-backup.sqlite'
        interrupted_report = jobs.backup(interrupted, interrupted_backup)
        assert interrupted_report['frames'] == 4
        interrupted_restore = directory/'interrupted-restored.sqlite'
        jobs.restore(interrupted_backup, interrupted_restore, interrupted_report['sha256'])
        jobs.replay(binary, source, interrupted_restore)
        interrupted_output = directory/'interrupted.ndjson'
        jobs.export(interrupted_restore, interrupted_output)
        assert interrupted_output.read_bytes() == baseline
        passed('backup-after-writer-kill-recovers-only-committed-rows')

        cli = [sys.executable, str(ROOT/'tools/moonground_jobs.py')]
        result = json.loads(execute(cli+['verify', '--state', str(state)]))
        assert result['frames'] == 24
        target = directory/'cli-backup.sqlite'
        result = json.loads(execute(cli+['backup', '--state', str(state), '--output', str(target)]))
        execute(cli+['restore', '--backup', str(target), '--state', str(directory/'cli-restored.sqlite'), '--sha256', result['sha256']])
        execute(cli+['restore', '--backup', str(target), '--state', str(directory/'bad-cli.sqlite'), '--sha256', '0'*64], expected=2)
        passed('standalone-backup-verify-restore-cli-and-error-exit')
    return cases


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '_fault':
        fault_worker(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    started = time.monotonic()
    binary = args.binary.resolve()
    cases = suite(binary)
    result = dict(status='passed', cases=cases, case_count=len(cases),
                  source_sha256=jobs.digest_file(Path(__file__).resolve()), runner_sha256=jobs.digest_file(ROOT/'tools/moonground_jobs.py'),
                  binary_sha256=jobs.digest_file(binary), sqlite_version=sqlite3.sqlite_version,
                  python=platform.python_version(), platform=platform.platform(),
                  elapsed_seconds=time.monotonic()-started, command='python '+' '.join(sys.argv))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes((json.dumps(portable_report(result), indent=2)+'\n').encode('utf-8'))
    print(json.dumps(dict(status='passed', cases=len(cases))))


if __name__ == '__main__':
    main()
