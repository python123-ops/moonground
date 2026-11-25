#!/usr/bin/env python3
"""Exercise durable evaluation commits, process death and public CLI recovery."""

import argparse
import contextlib
import copy
import hashlib
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
    original = jobs.sqlite3.connect
    class Connection(sqlite3.Connection):
        def execute(self, statement, parameters=()):
            if statement == 'COMMIT':
                try:
                    armed = self.execute('SELECT count(*) FROM evaluations').fetchone()[0] > 0
                except sqlite3.Error:
                    armed = False
                if armed and args.fault_phase == 'before':
                    print('paused', flush=True)
                    sys.stdin.read(1)
                result = super().execute(statement, parameters)
                if armed and args.fault_phase == 'after':
                    print('paused', flush=True)
                    sys.stdin.read(1)
                return result
            return super().execute(statement, parameters)
    def connect(*values, **options):
        options['factory'] = Connection
        return original(*values, **options)
    with mock.patch.object(jobs.sqlite3, 'connect', connect):
        return adapter.main(['--binary', str(args.binary), '--references', str(args.references),
                             '--committed-only', '--evaluation-state', str(args.evaluation_state),
                             '--output', str(args.report)], jobs.MeasurementSource(args.job, True))


def suite(binary):
    cases = []
    def passed(name):
        cases.append(dict(name=name, passed=True))
    with tempfile.TemporaryDirectory(prefix='moonground-evaluation-state-') as temporary:
        directory = Path(temporary)/'space \u6d4b\u8bd5'
        directory.mkdir()
        source, job, refs, state, report = [directory/name for name in ['input.ndjson', 'job.sqlite', 'reference.ndjson', 'evaluations.sqlite', 'report.json']]
        source.write_bytes(records(fixture(frames=12)))
        truths = [dict(timestamp_us=str(i*200000), samples=[dict(track_id=1, position_m=[1+i*0.01, 0])]) for i in range(15)]
        refs.write_bytes(records(truths))
        jobs.replay(binary, source, job, max_frames=3, batch_frames=3)
        store = jobs.EvaluationStore(state)
        report.write_bytes(b'previous report\n')
        def run(expected=0, evaluation_state=state, job_path=job, reference_path=refs, output=report, extra=(), committed=True):
            options = ['--binary', str(binary), '--references', str(reference_path), '--evaluation-state', str(evaluation_state)]
            if committed:
                options += ['--committed-only']
            if output is not None:
                options += ['--output', str(output)]
            options += list(extra)
            diagnostic, stdout = io.StringIO(), io.StringIO()
            with contextlib.redirect_stderr(diagnostic), contextlib.redirect_stdout(stdout):
                try:
                    status = adapter.main(options, jobs.MeasurementSource(job_path, True))
                except SystemExit as error:
                    status = error.code
            assert status == expected, (status, expected, diagnostic.getvalue())
            return stdout.getvalue(), diagnostic.getvalue()
        run(expected=2, committed=False)
        assert not state.exists() and report.read_bytes() == b'previous report\n'
        passed('state-mode-must-explicitly-select-the-committed-reference-window')
        limits = directory/'requirements.json'
        limits.write_text('{"position_m":{"min_samples":12,"min_coverage":1,"max_rmse":1}}', encoding='utf-8')
        run(expected=3, extra=['--requirements', str(limits), '--max-samples', '100'])
        first = report.read_bytes()
        initial = json.loads(first)
        assert initial['evaluation_state'] == dict(version=1, sequence='1', parent_sha256=None)
        assert initial['acceptance']['accepted'] is False
        status = store.status()
        assert status['records'] == '1' and status['latest_sha256'] == hashlib.sha256(first).hexdigest()
        assert status['latest_frames'] == '3' and not status['complete']
        passed('failed-acceptance-still-commits-a-complete-initial-report-and-checkpoint')
        first_export = directory/'first.json'
        info = store.export(first_export)
        assert first_export.read_bytes() == first and info['sha256'] == status['latest_sha256']
        passed('export-preserves-every-original-report-byte')
        jobs.replay(binary, source, job, max_frames=3)
        run()
        second = report.read_bytes()
        middle = json.loads(second)
        assert middle['evaluation_state']['sequence'] == '2'
        assert middle['evaluation_state']['parent_sha256'] == middle['inputs']['resume_sha256'] == hashlib.sha256(first).hexdigest()
        assert middle['measurement_source']['evaluated_frames'] == 3 and middle['evaluation']['counts']['frames'] == '6'
        assert 'acceptance' not in middle and middle['configuration']['max_samples'] == 100
        passed('later-call-automatically-restores-capacity-and-calculates-only-new-commits')
        jobs.replay(binary, source, job)
        run(extra=['--requirements', str(limits)])
        final = json.loads(report.read_bytes())
        assert final['evaluation_state']['sequence'] == '3' and final['acceptance']['accepted']
        fresh_args = argparse.Namespace(binary=binary, measurements=None, references=refs, requirements=limits,
                                        checkpoint=False, committed_only=True, resume=None, output=None,
                                        session_id=None, max_tracks=None, max_samples=100, max_line_bytes=1048576, timeout=300)
        fresh = adapter.evaluate(fresh_args, jobs.MeasurementSource(job))
        assert fresh['evaluation'] == final['evaluation'] and fresh['resume'] == final['resume']
        passed('cumulative-acceptance-and-native-checkpoint-match-a-fresh-calculation')
        historical = directory/'historical.json'
        store.export(historical, sequence=1)
        assert historical.read_bytes() == first
        passed('earlier-generations-remain-exportable-after-later-commits')
        before = store.status()['latest_sha256']
        saved = report.read_bytes()
        bad = copy.deepcopy(truths)
        bad[0]['samples'][0]['position_m'][0] = 99
        refs.write_bytes(records(bad))
        run(expected=2)
        assert store.status()['latest_sha256'] == before and report.read_bytes() == saved
        refs.write_bytes(records(truths))
        passed('historical-reference-changes-keep-the-last-committed-evaluation-and-output')
        malformed = directory/'bad.ndjson'
        malformed.write_bytes(b'{bad}\n')
        empty = directory/'empty.sqlite'
        run(expected=2, evaluation_state=empty, reference_path=malformed)
        assert jobs.EvaluationStore(empty).status()['records'] == '0'
        run(evaluation_state=empty)
        assert jobs.EvaluationStore(empty).status()['records'] == '1'
        passed('failed-first-calculation-leaves-an-empty-state-that-can-be-retried')
        with store.open():
            run(expected=2)
        assert store.status()['latest_sha256'] == before
        passed('one-evaluation-writer-holds-the-state-until-publication-finishes')
        # The report commits before its optional display/export file is saved.
        with mock.patch.object(adapter, 'save_atomic', side_effect=OSError('simulated output failure')):
            run(expected=2)
        committed = store.status()
        assert committed['records'] == '4' and committed['latest_sha256'] != before
        recovered = directory/'recovered.json'
        store.export(recovered)
        assert json.loads(recovered.read_bytes())['resume'] == final['resume']
        assert report.read_bytes() != recovered.read_bytes()
        run()
        assert store.status()['records'] == '5'
        assert json.loads(report.read_bytes())['resume'] == final['resume']
        assert json.loads(report.read_bytes())['measurement_source']['evaluated_frames'] == 0
        passed('output-save-failure-leaves-a-recoverable-commit-and-does-not-repeat-samples')
        for phase, expected_records in [('before', '0'), ('after', '1')]:
            crashed = directory/('crash-'+phase+'.sqlite')
            output = directory/('crash-'+phase+'.json')
            output.write_bytes(b'previous report\n')
            command = [sys.executable, str(Path(__file__)), '--fault-phase', phase, '--binary', str(binary),
                       '--job', str(job), '--references', str(refs), '--evaluation-state', str(crashed), '--report', str(output)]
            child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                assert wait_line(child) == b'paused'
            finally:
                child.kill()
                child.wait(timeout=15)
                for stream in [child.stdin, child.stdout, child.stderr]:
                    stream.close()
            crashed_store = jobs.EvaluationStore(crashed)
            assert crashed_store.status()['records'] == expected_records
            assert output.read_bytes() == b'previous report\n'
            run(evaluation_state=crashed, output=output)
            value = json.loads(output.read_bytes())
            assert value['evaluation']['counts']['frames'] == '12'
            assert crashed_store.status()['records'] == str(int(expected_records)+1)
            passed('forced-process-death-'+phase+'-commit-recovers-the-correct-generation')
        # Even a writer which ignores the file lock cannot make this writer
        # silently replace progress calculated from an older parent.
        with store.open() as writer:
            number, parent, raw = writer.head
            candidate = json.loads(raw)
            candidate['evaluation_state'] = dict(version=1, sequence=str(number+1), parent_sha256=parent)
            candidate['inputs']['resume_sha256'] = parent
            content = adapter.report_bytes(candidate)
            with contextlib.closing(sqlite3.connect(str(state))) as connection, connection:
                connection.execute('INSERT INTO evaluations VALUES(?,?,?,?)', (number+1, parent, hashlib.sha256(content).hexdigest(), content))
            try:
                writer.append(content)
            except ValueError as error:
                assert 'changed during' in str(error)
            else:
                raise AssertionError('stale writer appended another generation')
        assert store.status()['records'] == str(number+1)
        passed('generation-comparison-rejects-a-state-changed-during-calculation')
        with store.open() as writer:
            number, parent, raw = writer.head
            candidate = json.loads(raw)
            candidate['evaluation_state'] = dict(version=1, sequence=str(number+1), parent_sha256=parent)
            candidate['inputs']['resume_sha256'] = parent
            candidate['measurement_source']['input_sha256'] = 'a'*64
            try:
                writer.append(adapter.report_bytes(candidate))
            except ValueError as error:
                assert 'replay identity' in str(error)
            else:
                raise AssertionError('writer committed a different replay identity')
        assert store.status()['records'] == str(number)
        passed('writer-rejects-a-different-replay-before-creating-a-record')
        now = [100.0]
        with mock.patch.object(jobs.time, 'monotonic', side_effect=lambda:now[0]):
            with store.open() as writer:
                number, parent, raw = writer.head
                candidate = json.loads(raw)
                candidate['evaluation_state'] = dict(version=1, sequence=str(number+1), parent_sha256=parent)
                candidate['inputs']['resume_sha256'] = parent
                now[0] = 1000.0
                writer.append(adapter.report_bytes(candidate))
        assert store.status()['records'] == str(number+1)
        passed('native-calculation-time-does-not-consume-the-next-storage-phase-budget')
        with mock.patch.object(jobs.time, 'monotonic', side_effect=[100.0, 200.0]):
            try:
                store.status()
            except ValueError as error:
                assert 'timed out' in str(error)
            else:
                raise AssertionError('state inspection exceeded its deadline')
        assert store.status()['records'] == str(number+1)
        passed('expired-inspection-budget-preserves-committed-records')
        for field, mutation in [
            ('digest', lambda c:c.execute("UPDATE evaluations SET sha256=? WHERE sequence=1", ('f'*64,))),
            ('parent', lambda c:c.execute("UPDATE evaluations SET parent_sha256=? WHERE sequence=2", ('f'*64,))),
            ('missing-generation', lambda c:c.execute('DELETE FROM evaluations WHERE sequence=2')),
            ('foreign-application', lambda c:c.execute('PRAGMA application_id=123')),
            ('future-version', lambda c:c.execute('PRAGMA user_version=2')),
            ('extra-table', lambda c:c.execute('CREATE TABLE unrelated(x)')),
        ]:
            corrupt = directory/(field+'.sqlite')
            shutil.copyfile(state, corrupt)
            with contextlib.closing(sqlite3.connect(str(corrupt))) as connection, connection:
                mutation(connection)
            saved = report.read_bytes()
            run(expected=2, evaluation_state=corrupt)
            assert report.read_bytes() == saved
            passed('reject-'+field+'-without-publishing-a-new-report')
        for field in ['duplicate-field', 'numeric-underflow', 'numeric-watermark', 'generation-mismatch', 'different-replay']:
            corrupt = directory/(field+'.sqlite')
            shutil.copyfile(state, corrupt)
            with contextlib.closing(sqlite3.connect(str(corrupt))) as connection, connection:
                sequence, payload = connection.execute('SELECT sequence,document FROM evaluations ORDER BY sequence DESC LIMIT 1').fetchone()
                value = json.loads(payload)
                if field == 'duplicate-field':
                    content = payload.replace(b'"schema_version":', b'"schema_version":"0.1.0","schema_version":', 1)
                elif field == 'numeric-underflow':
                    value['elapsed_seconds'] = 'UNDERFLOW'
                    content = adapter.report_bytes(value).replace(b'"UNDERFLOW"', b'1e-9999')
                else:
                    if field == 'numeric-watermark':
                        value['reference_cursor']['through_timestamp_us'] = int(value['reference_cursor']['through_timestamp_us'])
                    elif field == 'generation-mismatch':
                        value['evaluation_state']['sequence'] = '1'
                    else:
                        value['measurement_source']['input_sha256'] = 'a'*64
                    content = adapter.report_bytes(value)
                connection.execute('UPDATE evaluations SET document=?,sha256=? WHERE sequence=?', (content, hashlib.sha256(content).hexdigest(), sequence))
            saved = report.read_bytes()
            run(expected=2, evaluation_state=corrupt)
            assert report.read_bytes() == saved
            passed('reject-self-checksummed-'+field)
        for destination in [job, source, binary]:
            saved = report.read_bytes()
            run(expected=2, evaluation_state=destination)
            assert report.read_bytes() == saved
        passed('evaluation-state-cannot-overwrite-replay-or-input-files-and-the-executable')
        for destination in store.protected_paths:
            run(expected=2, output=destination)
        passed('reports-cannot-overwrite-evaluation-state-or-its-sidecars')
        # A state lock file must never be created over an input reference log.
        lock_reference = directory/'reference-as-lock.sqlite.lock'
        lock_reference.write_bytes(b'')
        lock_store = directory/'reference-as-lock.sqlite'
        run(expected=2, evaluation_state=lock_store, reference_path=lock_reference)
        assert not lock_store.exists() and lock_reference.read_bytes() == b''
        passed('state-sidecar-paths-cannot-overlap-reference-inputs')
        for arguments in [['--resume', str(first_export)], ['--max-evaluation-mib', '0'], ['--evaluation-timeout', '0']]:
            run(expected=2, extra=arguments)
        passed('manual-resume-and-invalid-storage-budgets-are-rejected')
        blank = directory/'blank.sqlite'
        blank.write_bytes(b'')
        run(expected=2, evaluation_state=blank)
        assert blank.read_bytes() == b''
        passed('preexisting-empty-or-foreign-files-are-not-initialized-as-evaluation-state')
        # Controlled failures before and after initialized-file publication.
        for phase in ['before-link', 'after-link']:
            initializing = directory/(phase+'.sqlite')
            target = jobs.EvaluationStore(initializing)
            function = 'link' if phase == 'before-link' else '_sync_directory'
            owner = jobs.os if phase == 'before-link' else jobs
            with mock.patch.object(owner, function, side_effect=OSError('simulated initialization interruption')):
                try:
                    with target.open():
                        raise AssertionError('initialization unexpectedly succeeded')
                except OSError:
                    pass
            assert initializing.exists() == (phase == 'after-link')
            run(evaluation_state=initializing)
            assert target.status()['records'] == '1'
            passed('initialized-database-publication-recovers-'+phase)
        # A full SQLite database must retain its last committed report.
        bounded = jobs.EvaluationStore(directory/'bounded.sqlite', max_state_mib=1)
        with bounded.open() as writer:
            value = json.loads(first)
            value['padding'] = 'x'*600000
            payload = adapter.report_bytes(value)
            writer.append(payload)
            value['evaluation_state'] = dict(version=1, sequence='2', parent_sha256=writer.head[1])
            value['inputs']['resume_sha256'] = writer.head[1]
            try:
                writer.append(adapter.report_bytes(value))
            except sqlite3.Error:
                pass
            else:
                raise AssertionError('database unexpectedly exceeded its budget')
        assert bounded.status()['records'] == '1'
        passed('database-budget-exhaustion-rolls-back-the-new-generation')
        run(evaluation_state=bounded.path, extra=['--max-evaluation-mib', '2'])
        assert jobs.EvaluationStore(bounded.path).status()['records'] == '2'
        passed('larger-budget-resumes-from-the-last-committed-evaluation')
        zero_input, zero_job, zero_evaluations = [directory/name for name in ['zero.ndjson', 'zero.sqlite', 'zero-evaluations.sqlite']]
        zero_input.write_bytes(records(fixture(frames=0)))
        jobs.replay(binary, zero_input, zero_job)
        run(job_path=zero_job, evaluation_state=zero_evaluations, extra=['--session-id', 'durable-replay'])
        run(job_path=zero_job, evaluation_state=zero_evaluations)
        zero_status = jobs.EvaluationStore(zero_evaluations).status()
        assert zero_status['records'] == '2' and zero_status['latest_frames'] == '0' and zero_status['last_timestamp_us'] is None
        passed('zero-frame-evaluations-retain-null-watermarks-and-can-be-resumed')
        # Export failures and aliases preserve both the state and destination.
        existing = directory/'existing.json'
        existing.write_bytes(b'old export\n')
        try:
            store.export(existing)
        except ValueError:
            pass
        else:
            raise AssertionError('export replaced an existing destination implicitly')
        with mock.patch.object(jobs.os, 'replace', side_effect=OSError('simulated export interruption')):
            try:
                store.export(existing, replace_existing=True)
            except OSError:
                pass
        assert existing.read_bytes() == b'old export\n'
        store.export(existing, replace_existing=True)
        assert hashlib.sha256(existing.read_bytes()).hexdigest() == store.status()['latest_sha256']
        passed('atomic-export-failure-preserves-existing-output-and-allows-retry')
        for destination in [state, source, binary]:
            try:
                store.export(destination, replace_existing=True)
            except ValueError:
                pass
            else:
                raise AssertionError('export overwrote a protected source')
        passed('export-protects-the-state-input-and-producing-binary')
        missing_export = directory/'missing.json'
        for sequence in [0, 999999]:
            try:
                store.export(missing_export, sequence=sequence)
            except ValueError:
                pass
            else:
                raise AssertionError('invalid export generation succeeded')
            assert not missing_export.exists()
        passed('missing-generation-does-not-create-an-export-file')
        before_publication = int(store.status()['records'])
        original_save = adapter.save_atomic
        contended = [False]
        def save_with_contender(path, content):
            if not contended[0]:
                contended[0] = True
                run(expected=2)
            return original_save(path, content)
        with mock.patch.object(adapter, 'save_atomic', side_effect=save_with_contender):
            run()
        assert contended[0] and int(store.status()['records']) == before_publication+1
        assert json.loads(report.read_bytes())['evaluation_state']['sequence'] == str(before_publication+1)
        passed('writer-lock-remains-held-through-optional-report-publication')
        # The real installed manager includes all three entry points.
        bundle = packager.create_bundle(binary, directory/'bundle', packager.module_version(), '0'*40, True)
        prefix = directory/'install'
        manager.install_archive(prefix, directory/'bundle'/bundle['archive'], bundle['sha256'])
        command = [sys.executable, str(ROOT/'tools/moonground_cli.py'), '--prefix', str(prefix)]
        installed_state = directory/'installed.sqlite'
        execute(command+['evaluate', '--state', str(job), '--committed-only', '--evaluation-state', str(installed_state), '--references', str(refs), '--output', str(report)])
        installed_status = json.loads(execute(command+['evaluation-status', '--evaluation-state', str(installed_state)]))
        assert installed_status['records'] == '1' and installed_status['latest_frames'] == '12'
        installed_export = directory/'installed.json'
        execute(command+['evaluation-export', '--evaluation-state', str(installed_state), '--output', str(installed_export)])
        assert installed_export.read_bytes() == report.read_bytes()
        passed('installed-manager-evaluates-queries-and-exports-verified-storage')
        execute(command+['evaluation-export', '--evaluation-state', str(installed_state), '--sequence', '0', '--output', str(installed_export), '--replace-existing'], expected=2)
        assert installed_export.read_bytes() == report.read_bytes()
        passed('absent-generation-export-is-a-controlled-error-and-preserves-output')
        for destination in [prefix/'current.json', prefix/'versions/new.sqlite', ROOT/'tools/moonground_cli.py']:
            execute(command+['evaluate', '--state', str(job), '--committed-only', '--evaluation-state', str(destination), '--references', str(refs)], expected=2)
        passed('manager-protects-its-installation-and-own-script-from-storage-writes')
        assert not list((prefix/'versions').rglob('__pycache__'))
        manager.status(prefix)
        passed('all-installed-helper-payloads-remain-immutable')
    digest = jobs.digest_file
    return dict(status='passed', cases=cases, binary_sha256=digest(binary),
                source_sha256=digest(Path(__file__)), runner_sha256=digest(Path(jobs.__file__)),
                adapter_sha256=digest(Path(adapter.__file__)), manager_sha256=digest(Path(manager.__file__)),
                support_sha256=digest(ROOT/'validation/cli_jobs_verify.py'), python=platform.python_version(),
                sqlite_version=sqlite3.sqlite_version, platform=platform.platform(),
                forced_commit_crashes=2, initialized_publication_failures=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--fault-phase', choices=['before', 'after'])
    parser.add_argument('--job', type=Path)
    parser.add_argument('--references', type=Path)
    parser.add_argument('--evaluation-state', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if args.fault_phase:
        return fault_worker(args)
    result = portable_report(suite(args.binary.resolve()))
    result['command'] = portable_report('python '+' '.join(sys.argv))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(result))


if __name__ == '__main__':
    sys.exit(main())
