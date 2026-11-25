#!/usr/bin/env python3
"""Verify complete evaluation snapshots, failed publication and native resumption."""

import argparse
import contextlib
import io
import json
from pathlib import Path
import platform
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from unittest import mock

from cli_jobs_verify import execute, fixture, jobs, records, wait_line
from public_reports import portable_report

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'examples'))
import evaluate_measurements as adapter
import moonground_cli as manager
import package_cli as packager


def fault_worker(args):
    original = jobs.os.link
    def publish(source, target):
        if args.fault_phase == 'before':
            print('paused', flush=True)
            sys.stdin.read(1)
        original(source, target)
        if args.fault_phase == 'after':
            print('paused', flush=True)
            sys.stdin.read(1)
    with mock.patch.object(jobs.os, 'link', side_effect=publish):
        if args.operation == 'backup':
            jobs.EvaluationStore(args.source).backup(args.destination)
        else:
            jobs.EvaluationStore(args.destination).restore(args.source, args.sha256)


def rows(path):
    with contextlib.closing(sqlite3.connect(str(path))) as connection:
        return connection.execute('SELECT sequence,parent_sha256,sha256,document FROM evaluations ORDER BY sequence').fetchall()


def suite(binary):
    cases = []
    def passed(name):
        cases.append(dict(name=name, passed=True))
    with tempfile.TemporaryDirectory(prefix='moonground-evaluation-backup-') as temporary:
        directory = Path(temporary)/'space \u6d4b\u8bd5'
        directory.mkdir()
        source, job, refs, state, report = [directory/name for name in ['input.ndjson', 'job.sqlite', 'reference.ndjson', 'evaluations.sqlite', 'report.json']]
        source.write_bytes(records(fixture(frames=12)))
        truths = [dict(timestamp_us=str(i*200000), samples=[dict(track_id=1, position_m=[1+i*0.01, 0])]) for i in range(15)]
        refs.write_bytes(records(truths))
        jobs.replay(binary, source, job, max_frames=3, batch_frames=3)
        def evaluate(path, max_samples=None, output=report):
            options = ['--binary', str(binary), '--references', str(refs), '--committed-only',
                       '--evaluation-state', str(path), '--output', str(output)]
            if max_samples is not None:
                options += ['--max-samples', str(max_samples)]
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                assert adapter.main(options, jobs.MeasurementSource(job, True)) == 0
            return json.loads(output.read_bytes())
        initial = evaluate(state, 100)
        store = jobs.EvaluationStore(state)
        first = report.read_bytes()
        first_status = store.status()
        first_rows = rows(state)
        snapshot = directory/'snapshot.sqlite'
        saved = store.backup(snapshot, first_status['latest_sha256'].upper())
        assert saved['sha256'] == jobs.digest_file(snapshot) and saved['bytes'] == snapshot.stat().st_size
        assert saved['records'] == '1' and saved['latest_frames'] == '3'
        assert {key:saved[key] for key in first_status} == first_status
        assert rows(snapshot) == first_rows and store.status() == first_status
        assert not any(snapshot.with_name(snapshot.name+s).exists() for s in ['-journal','-wal','-shm'])
        passed('snapshot-preserves-every-report-byte-and-committed-head-at-the-requested-hash')
        frozen = snapshot.read_bytes()
        jobs.replay(binary, source, job, max_frames=3)
        middle = evaluate(state)
        assert snapshot.read_bytes() == frozen and store.status()['records'] == '2'
        passed('later-evaluation-progress-does-not-change-the-published-snapshot')
        restored = directory/'restored.sqlite'
        restored_store = jobs.EvaluationStore(restored)
        restored_info = restored_store.restore(snapshot, saved['sha256'].upper())
        assert restored_info['records'] == '1' and restored_info['latest_sha256'] == first_status['latest_sha256']
        assert rows(restored) == first_rows
        exported = directory/'first.json'
        restored_store.export(exported, sequence=1)
        assert exported.read_bytes() == first
        passed('checksum-restoration-accepts-uppercase-and-retains-historical-report-bytes')
        resumed = evaluate(restored)
        assert resumed['evaluation'] == middle['evaluation'] and resumed['resume'] == middle['resume']
        assert resumed['measurement_source']['evaluated_frames'] == 3
        assert resumed['inputs']['resume_sha256'] == first_status['latest_sha256']
        passed('restored-state-continues-only-the-three-newly-committed-measurement-frames')
        jobs.replay(binary, source, job)
        final = evaluate(state)
        continued = evaluate(restored)
        fresh_args = argparse.Namespace(binary=binary, measurements=None, references=refs, requirements=None,
                                        checkpoint=False, committed_only=True, resume=None, output=None,
                                        session_id=None, max_tracks=None, max_samples=100, max_line_bytes=1048576, timeout=300)
        fresh = adapter.evaluate(fresh_args, jobs.MeasurementSource(job))
        assert final['evaluation'] == continued['evaluation'] == fresh['evaluation']
        assert final['resume'] == continued['resume'] == fresh['resume']
        assert continued['measurement_source']['evaluated_frames'] == 6
        passed('restored-completion-matches-the-original-chain-and-a-fresh-native-calculation')
        complete_snapshot = directory/'complete.sqlite'
        complete_saved = restored_store.backup(complete_snapshot)
        complete_store = jobs.EvaluationStore(directory/'complete-restored.sqlite')
        complete_store.restore(complete_snapshot, complete_saved['sha256'])
        idle = evaluate(complete_store.path)
        assert idle['resume'] == final['resume'] and idle['measurement_source']['evaluated_frames'] == 0
        passed('completed-evaluation-restores-without-repeating-any-samples')
        zero = jobs.EvaluationStore(directory/'empty.sqlite')
        with zero.open():
            pass
        empty_snapshot = directory/'empty-backup.sqlite'
        empty_saved = zero.backup(empty_snapshot)
        empty_restored = jobs.EvaluationStore(directory/'empty-restored.sqlite')
        empty_restored.restore(empty_snapshot, empty_saved['sha256'])
        assert empty_restored.status()['records'] == '0'
        assert evaluate(empty_restored.path, 100)['resume'] == final['resume']
        passed('initialized-empty-evaluation-state-can-be-snapshotted-and-start-later')

        protected = [source, job, state, snapshot, restored, complete_snapshot]
        def rejected(name, operation, destination=None):
            before = {p:p.read_bytes() for p in protected}
            try:
                operation()
            except (ValueError, OSError, sqlite3.Error):
                pass
            else:
                raise AssertionError('expected rejection: '+name)
            assert all(p.read_bytes() == content for p,content in before.items()), name
            if destination is not None:
                assert not destination.exists(), name
            passed(name)
        mismatch = directory/'mismatch.sqlite'
        rejected('stale-expected-report-hash-refuses-a-later-head',
                 lambda:store.backup(mismatch, first_status['latest_sha256']), mismatch)
        for token in ['', 'f'*63, 'x'*64]:
            rejected('invalid-report-hash-'+str(len(token)), lambda token=token:store.backup(mismatch, token), mismatch)
        for token in ['', 'f'*63, 'x'*64, 'f'*64]:
            rejected('invalid-backup-checksum-'+str(len(token))+'-'+token[:1],
                     lambda token=token:jobs.EvaluationStore(mismatch).restore(snapshot, token), mismatch)
        rejected('backup-refuses-an-existing-destination', lambda:store.backup(snapshot))
        rejected('restore-refuses-an-existing-destination', lambda:store.restore(snapshot, saved['sha256']))
        rejected('backup-refuses-source-path', lambda:store.backup(state))
        rejected('restore-refuses-backup-path', lambda:jobs.EvaluationStore(snapshot).restore(snapshot, saved['sha256']))
        for suffix in ['-journal', '-wal', '-shm', '.lock']:
            path = state.with_name(state.name+suffix)
            rejected('backup-refuses-source-sidecar-'+suffix, lambda path=path:store.backup(path))
        for suffix in ['-journal', '-wal', '-shm']:
            name = directory/('destination-'+suffix+'.sqlite')
            sidecar = name.with_name(name.name+suffix)
            sidecar.write_bytes(b'preserve journal\n')
            rejected('backup-refuses-destination-journal-'+suffix, lambda name=name:store.backup(name), name)
            assert sidecar.read_bytes() == b'preserve journal\n'
        # A closed backup with external journals must not be recovered before
        # its expected bytes are checked or used as a restoration source.
        journal_source = directory/'external-journal.sqlite'
        shutil.copyfile(snapshot, journal_source)
        for suffix in ['-journal', '-wal', '-shm']:
            sidecar = journal_source.with_name(journal_source.name+suffix)
            sidecar.write_bytes(b'preserve external journal\n')
            rejected('restore-refuses-external-backup-journal-'+suffix,
                     lambda:jobs.EvaluationStore(mismatch).restore(journal_source, saved['sha256']), mismatch)
            assert sidecar.read_bytes() == b'preserve external journal\n'
            sidecar.unlink()
        rejected('measurement-database-is-not-an-evaluation-snapshot', lambda:jobs.EvaluationStore(job).backup(mismatch), mismatch)
        rejected('measurement-restore-cannot-consume-an-evaluation-database', lambda:jobs.restore(snapshot, mismatch, saved['sha256']), mismatch)
        for name, mutate in [
            ('wrong-application', lambda c:c.execute('PRAGMA application_id=123')),
            ('future-version', lambda c:c.execute('PRAGMA user_version=2')),
            ('extra-table', lambda c:c.execute('CREATE TABLE unrelated(x)')),
            ('broken-digest', lambda c:c.execute('UPDATE evaluations SET sha256=? WHERE sequence=1', ('f'*64,))),
            ('missing-generation', lambda c:c.execute('DELETE FROM evaluations WHERE sequence=2')),
        ]:
            invalid = directory/(name+'.sqlite')
            shutil.copyfile(state, invalid)
            with contextlib.closing(sqlite3.connect(str(invalid))) as connection, connection:
                mutate(connection)
            rejected('backup-rejects-'+name, lambda invalid=invalid:jobs.EvaluationStore(invalid).backup(mismatch), mismatch)
            rejected('restore-rejects-self-checksummed-'+name,
                     lambda invalid=invalid:jobs.EvaluationStore(mismatch).restore(invalid, jobs.digest_file(invalid)), mismatch)
        with store.open():
            rejected('active-evaluation-refuses-a-concurrent-backup', lambda:store.backup(mismatch), mismatch)
        with jobs.state_lock(mismatch):
            rejected('restore-refuses-a-concurrently-held-destination', lambda:jobs.EvaluationStore(mismatch).restore(snapshot, saved['sha256']), mismatch)
        for operation in ['backup', 'restore']:
            with mock.patch.object(jobs.os, 'link', side_effect=OSError('simulated publication failure')):
                rejected(operation+'-publication-failure-keeps-source-and-destination',
                         (lambda:store.backup(mismatch)) if operation == 'backup' else (lambda:jobs.EvaluationStore(mismatch).restore(snapshot, saved['sha256'])), mismatch)
        large = directory/'retired-pages.sqlite'
        shutil.copyfile(state, large)
        with contextlib.closing(sqlite3.connect(str(large))) as connection, connection:
            connection.execute('CREATE TABLE retired(payload BLOB)')
            connection.execute('INSERT INTO retired VALUES(zeroblob(2097152))')
            connection.execute('DROP TABLE retired')
        assert large.stat().st_size > 1024*1024
        large_digest = jobs.digest_file(large)
        rejected('backup-database-budget-refuses-retired-pages',
                 lambda:jobs.EvaluationStore(large, max_state_mib=1).backup(mismatch), mismatch)
        rejected('restore-database-budget-refuses-retired-pages',
                 lambda:jobs.EvaluationStore(mismatch, max_state_mib=1).restore(large, large_digest), mismatch)
        jobs.EvaluationStore(mismatch, max_state_mib=4).restore(large, large_digest)
        assert rows(mismatch) == rows(state)
        mismatch.unlink()
        passed('larger-budget-restores-the-same-complete-report-history')
        for operation in ['backup', 'restore']:
            ticks = iter([100.0])
            with mock.patch.object(jobs.time, 'monotonic', side_effect=lambda:next(ticks, 200.0)):
                rejected(operation+'-expired-budget-does-not-publish-a-destination',
                         (lambda:store.backup(mismatch)) if operation == 'backup' else (lambda:jobs.EvaluationStore(mismatch).restore(snapshot, saved['sha256'])), mismatch)
        # Reject a copy whose database header no longer identifies its type.
        original_connect = jobs.sqlite3.connect
        class BadCopy(sqlite3.Connection):
            def backup(self, target, **options):
                super().backup(target, **options)
                target.execute('PRAGMA application_id=123')
        def connect(*arguments, **options):
            options['factory'] = BadCopy
            return original_connect(*arguments, **options)
        with mock.patch.object(jobs.sqlite3, 'connect', connect):
            rejected('copied-database-header-is-checked-before-publication', lambda:store.backup(mismatch), mismatch)
        for operation in ['backup', 'restore']:
            for phase in ['before', 'after']:
                destination = directory/(operation+'-crash-'+phase+'.sqlite')
                source_path = state if operation == 'backup' else snapshot
                command = [sys.executable, str(Path(__file__)), '--fault-phase', phase, '--operation', operation,
                           '--source', str(source_path), '--destination', str(destination), '--sha256', jobs.digest_file(source_path)]
                child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    assert wait_line(child) == b'paused'
                finally:
                    child.kill()
                    child.wait(timeout=15)
                    for stream in [child.stdin, child.stdout, child.stderr]:
                        stream.close()
                assert destination.exists() == (phase == 'after')
                if phase == 'after':
                    assert rows(destination) == rows(source_path)
                else:
                    if operation == 'backup':
                        store.backup(destination)
                    else:
                        jobs.EvaluationStore(destination).restore(source_path, jobs.digest_file(source_path))
                assert jobs.EvaluationStore(destination).status()['records'] == jobs.EvaluationStore(source_path).status()['records']
                passed(operation+'-survives-process-death-'+phase+'-publication')
        # Exercise WAL-backed source databases through the SQLite snapshot API.
        wal_state = directory/'wal.sqlite'
        shutil.copyfile(state, wal_state)
        with contextlib.closing(sqlite3.connect(str(wal_state))) as keeper:
            assert keeper.execute('PRAGMA journal_mode=WAL').fetchone()[0] == 'wal'
            wal_report = evaluate(wal_state)
            wal_snapshot = directory/'wal-backup.sqlite'
            wal_saved = jobs.EvaluationStore(wal_state).backup(wal_snapshot)
            assert rows(wal_snapshot) == rows(wal_state)
            wal_restore = jobs.EvaluationStore(directory/'wal-restored.sqlite')
            wal_restore.restore(wal_snapshot, wal_saved['sha256'])
            assert evaluate(wal_restore.path)['resume'] == wal_report['resume']
        passed('wal-source-creates-a-restorable-standalone-snapshot')
        bundle = packager.create_bundle(binary, directory/'bundle', packager.module_version(), '0'*40, True)
        prefix = directory/'installed'
        manager.install_archive(prefix, directory/'bundle'/bundle['archive'], bundle['sha256'])
        command = [sys.executable, str(ROOT/'tools/moonground_cli.py'), '--prefix', str(prefix)]
        installed_backup, installed_restore = directory/'installed-backup.sqlite', directory/'installed-restored.sqlite'
        info = json.loads(execute(command+['evaluation-backup', '--evaluation-state', str(state), '--output', str(installed_backup),
                                         '--expected-report-sha256', store.status()['latest_sha256']]))
        execute(command+['evaluation-restore', '--evaluation-state', str(installed_restore), '--backup', str(installed_backup), '--sha256', info['sha256']])
        assert rows(installed_restore) == rows(state)
        passed('installed-manager-backs-up-and-restores-with-verified-helper-payloads')
        execute(command+['evaluate', '--state', str(job), '--committed-only', '--evaluation-state', str(installed_restore), '--references', str(refs), '--output', str(report)])
        assert json.loads(report.read_bytes())['resume'] == final['resume']
        passed('installed-restoration-continues-the-native-checkpoint-without-new-samples')
        for destination in [prefix/'current.json', prefix/'versions/new.sqlite', ROOT/'tools/moonground_cli.py']:
            execute(command+['evaluation-backup', '--evaluation-state', str(state), '--output', str(destination)], expected=2)
            execute(command+['evaluation-restore', '--evaluation-state', str(destination), '--backup', str(installed_backup), '--sha256', info['sha256']], expected=2)
        passed('manager-protects-installed-versions-metadata-and-its-own-script')
        assert not list((prefix/'versions').rglob('__pycache__'))
        manager.status(prefix)
        passed('installed-helpers-remain-immutable-after-snapshot-and-restoration')
    digest = jobs.digest_file
    return dict(status='passed', cases=cases, binary_sha256=digest(binary), source_sha256=digest(Path(__file__)),
                runner_sha256=digest(Path(jobs.__file__)), adapter_sha256=digest(Path(adapter.__file__)),
                manager_sha256=digest(Path(manager.__file__)), support_sha256=digest(ROOT/'validation/cli_jobs_verify.py'),
                python=platform.python_version(), sqlite_version=sqlite3.sqlite_version, platform=platform.platform(),
                forced_publication_crashes=4, wal_restoration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--fault-phase', choices=['before', 'after'])
    parser.add_argument('--operation', choices=['backup', 'restore'])
    parser.add_argument('--source', type=Path)
    parser.add_argument('--destination', type=Path)
    parser.add_argument('--sha256')
    args = parser.parse_args()
    if args.fault_phase:
        return fault_worker(args)
    if args.binary is None:
        parser.error('--binary is required')
    result = portable_report(suite(args.binary.resolve()))
    result['command'] = portable_report('python '+' '.join(sys.argv))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(result))


if __name__ == '__main__':
    sys.exit(main())
