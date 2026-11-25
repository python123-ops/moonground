#!/usr/bin/env python3
"""Compare checked SQLite replay inputs with exported-log evaluation."""

import argparse
import contextlib
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
import tracemalloc
from types import SimpleNamespace
from unittest import mock

from cli_jobs_verify import execute, fixture, jobs, records
from public_reports import portable_report

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'examples'))
import evaluate_measurements as adapter
import moonground_cli as manager
import package_cli as packager


def suite(binary):
    cases = []
    def passed(name):
        cases.append(dict(name=name, passed=True))
    with tempfile.TemporaryDirectory(prefix='moonground-sqlite-evaluation-') as temporary:
        directory = Path(temporary)/'space \u6d4b\u8bd5'
        directory.mkdir()
        source, state, reference = [directory/name for name in ('input.ndjson','state.sqlite','reference.ndjson')]
        source.write_bytes(records(fixture()))
        reference.write_bytes(records([dict(timestamp_us=str(i*200000),samples=[
            dict(track_id=identity,position_m=[identity+i*0.01,0],speed_mps=0.05)
            for identity in range(1,4)]) for i in range(24)]))
        jobs.replay(binary, source, state, batch_frames=4, max_frames=9)
        prefix = directory/'prefix.ndjson'
        jobs.export(state, prefix)
        config = SimpleNamespace(binary=binary,measurements=prefix,references=reference,requirements=None,
                                 output=None,session_id=None,max_tracks=4096,max_samples=10000000,
                                 max_line_bytes=1048576,timeout=60)
        def evaluate(path, partial=False, **options):
            return adapter.evaluate(config, jobs.MeasurementSource(path,partial,**options))
        def rejected(path=state, text=None, **options):
            try:
                evaluate(path, **options)
            except (ValueError, OSError) as error:
                if text is not None:
                    assert text in str(error), str(error)
            else:
                raise AssertionError('expected source rejection')
        rejected(text='incomplete')
        passed('incomplete-replay-requires-explicit-partial-selection')
        partial = evaluate(state, True)
        baseline = adapter.evaluate(config)
        assert partial['evaluation'] == baseline['evaluation'] and partial['alignment'] == baseline['alignment']
        assert partial['inputs'] == baseline['inputs']
        info = partial['measurement_source']
        assert not info['complete'] and info['partial_requested'] and info['frames'] == 9
        assert info['results_sha256'] == partial['inputs']['measurements_sha256'] == jobs.digest_file(prefix)
        assert info['input_sha256'] == jobs.digest_file(source)
        assert info['binary_sha256'] == jobs.digest_file(binary)
        assert info['reader_sha256'] == jobs.digest_file(Path(jobs.__file__))
        assert info['checkpoint_sha256'] == jobs.verify(state)['checkpoint_sha256']
        assert partial['alignment']['reference_only_frames'] == 15
        assert partial['evaluation']['position_coverage'] == 9/24
        passed('partial-snapshot-matches-export-and-retains-all-future-references')
        limits = directory/'requirements.json'
        limits.write_text('{"position_m":{"min_samples":1,"min_coverage":0.95,"max_rmse":1}}',encoding='utf-8')
        config.requirements = limits
        assert evaluate(state, True)['acceptance']['accepted'] is False
        passed('partial-snapshot-cannot-hide-missing-data-from-coverage-requirements')
        config.requirements = None
        # A new commit may start while the evaluator runs: the snapshot has
        # already been checked, aligned and closed before launching native code.
        original_run = subprocess.run
        def advance(*args, **kwargs):
            jobs.replay(binary, source, state)
            return original_run(*args, **kwargs)
        with mock.patch.object(adapter.subprocess,'run',side_effect=advance):
            snapshot = evaluate(state, True)
        assert snapshot['measurement_source']['frames'] == 9 and jobs.status(state)['frames'] == 24
        assert snapshot['evaluation'] == partial['evaluation']
        passed('snapshot-and-lock-close-before-native-evaluation-and-later-commits')
        complete_log = directory/'complete.ndjson'
        jobs.export(state,complete_log)
        config.measurements = complete_log
        complete = evaluate(state)
        baseline = adapter.evaluate(config)
        for key in ['evaluation','alignment','inputs','binary_sha256']:
            assert complete[key] == baseline[key], key
        assert complete['measurement_source']['complete'] is True
        assert complete['measurement_source']['partial_requested'] is False
        passed('complete-snapshot-and-export-have-identical-native-statistics-and-raw-hashes')
        before = state.read_bytes()
        with jobs.MeasurementSource(state).open() as (stream, _):
            assert stream.readline(0) == b''
            first = stream.readline(7)
            assert first + stream.readline() == complete_log.read_bytes().splitlines(keepends=True)[0]
            with contextlib.suppress(ValueError):
                # A reader uses the same OS lock as a writer and backups.
                jobs.replay(binary,source,state)
                raise AssertionError('writer unexpectedly acquired the reader lock')
        assert state.read_bytes() == before
        passed('reader-is-readonly-bounded-and-excludes-concurrent-writers')
        # Retain the partially consumed reader while renaming the database.
        # Windows forbids this if a statement still owns its file handle.
        renamed = directory/'renamed.sqlite'
        state.replace(renamed)
        renamed.replace(state)
        try:
            with jobs.MeasurementSource(state).open() as (failed_stream, _):
                failed_stream.readline(7)
                raise ValueError('caller stopped reading')
        except ValueError as error:
            assert str(error) == 'caller stopped reading'
        state.replace(renamed)
        renamed.replace(state)
        passed('partial-read-and-caller-failure-release-database-file-handles')
        # Failed native evaluation must leave an already published report intact.
        output = directory/'report.json'
        output.write_bytes(b'previous report\n')
        config.output = output
        for destination in [state, state.with_name(state.name+'.lock'), state.with_name(state.name+'-journal')]:
            config.output = destination
            rejected(text='output must differ')
        alias = directory/'state-alias'
        os.link(str(state),str(alias))
        config.output = alias
        rejected(text='output must differ')
        passed('state-sidecars-and-hardlink-aliases-cannot-be-report-destinations')
        for original in [source,binary]:
            config.output = original
            rejected(text='output')
        passed('original-input-and-producing-executable-are-protected-by-hash')
        config.output = output
        malformed = directory/'bad-reference.ndjson'
        malformed.write_bytes(reference.read_bytes()+b'{bad}\n')
        config.references = malformed
        rejected(text='reference line')
        assert output.read_bytes() == b'previous report\n'
        config.references = reference
        passed('late-reference-error-preserves-the-published-report')
        # Advance across a real budget boundary; do not depend on the host's
        # monotonic clock resolving an interval smaller than its clock tick.
        with mock.patch.object(jobs.time, 'monotonic', side_effect=[100.0, 101.0]):
            rejected(timeout=0.5, text='timed out')
        passed('state-inspection-deadline-is-enforced')
        for name, mutate in [
            ('future-version', lambda c:c.execute('PRAGMA user_version=2')),
            ('foreign-database', lambda c:c.execute('PRAGMA application_id=123')),
            ('extra-schema', lambda c:c.execute('CREATE TABLE unrelated (x)')),
            ('missing-result', lambda c:c.execute('DELETE FROM results WHERE sequence=3')),
            ('nonblob-result', lambda c:c.execute("UPDATE results SET payload='{}' WHERE sequence=3")),
            ('multiline-result', lambda c:c.execute('UPDATE results SET payload=? WHERE sequence=3',(b'{}\n{}\n',))),
            ('budget', lambda c:c.execute('UPDATE results SET payload=? WHERE sequence=3',(b'x'*2097152,))),
        ]:
            invalid = directory/(name+'.sqlite')
            shutil.copyfile(state,invalid)
            with contextlib.closing(sqlite3.connect(str(invalid))) as connection, connection:
                mutate(connection)
            rejected(invalid, max_state_mib=1 if name=='budget' else 256)
            assert output.read_bytes() == b'previous report\n'
            passed('reject-'+name+'-without-replacing-output')
        invalid = directory/'corrupt.sqlite'
        invalid.write_bytes(b'not a SQLite database')
        rejected(invalid,text='cannot read replay')
        passed('corrupt-sqlite-is-a-controlled-input-error')
        invalid = directory/'numeric-underflow.sqlite'
        shutil.copyfile(state,invalid)
        with contextlib.closing(sqlite3.connect(str(invalid))) as connection, connection:
            payload, = connection.execute('SELECT payload FROM results WHERE sequence=1').fetchone()
            payload = payload.replace(b'"position_m":[1,0]',b'"position_m":[1e-9999,0]')
            assert b'1e-9999' in payload
            connection.execute('UPDATE results SET payload=? WHERE sequence=1',(payload,))
        rejected(invalid,text='evaluation failed')
        passed('stored-raw-underflow-tokens-reach-native-validation')
        empty_input, empty_state = directory/'empty.ndjson', directory/'empty.sqlite'
        empty_input.write_bytes(records(fixture(frames=0)))
        jobs.replay(binary,empty_input,empty_state)
        config.session_id = 'durable-replay'
        config.requirements = limits
        empty = evaluate(empty_state)
        assert empty['measurement_source']['complete'] and empty['measurement_source']['frames'] == 0
        assert empty['evaluation']['position_coverage'] == 0 and empty['acceptance']['accepted'] is False
        config.session_id, config.requirements = None, None
        passed('complete-empty-job-retains-reference-misses-and-cannot-pass')
        config.output = None
        # An actual larger job checks the memory cost of inspection and reading.
        large_input, large_state = directory/'large.ndjson', directory/'large.sqlite'
        large_input.write_bytes(records(fixture(frames=4096, targets=1)))
        jobs.replay(binary,large_input,large_state,batch_frames=128)
        tracemalloc.start()
        with jobs.MeasurementSource(large_state).open() as (stream, large_info):
            digest, count = hashlib.sha256(), 0
            while True:
                line = stream.readline(1048578)
                if not line:
                    break
                digest.update(line)
                count += 1
        _, peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        assert count == 4096 and digest.hexdigest() == large_info['results_sha256']
        assert peak < 8*1024*1024, peak
        passed('larger-native-job-streams-4096-rows-with-bounded-python-memory')
        # Exercise the actual installed manager and both bundled helper scripts.
        bundle = packager.create_bundle(binary,directory/'bundle',packager.module_version(),
                                        '0'*40,True)
        prefix = directory/'install'
        manager.install_archive(prefix,directory/'bundle'/bundle['archive'],bundle['sha256'])
        command = [sys.executable,str(ROOT/'tools/moonground_cli.py'),'--prefix',str(prefix),'evaluate',
                   '--state',str(state),'--references',str(reference),'--output',str(output)]
        execute(command)
        installed = json.loads(output.read_text(encoding='utf-8'))
        assert installed['evaluation'] == complete['evaluation']
        assert installed['measurement_source']['results_sha256'] == complete['measurement_source']['results_sha256']
        passed('installed-manager-uses-both-verified-helpers-for-direct-state-evaluation')
        execute(command+['--requirements',str(limits)])
        assert json.loads(output.read_text(encoding='utf-8'))['acceptance']['accepted'] is True
        passed('installed-state-acceptance-uses-the-native-decision')
        strict = directory/'strict.json'
        strict.write_text('{"position_m":{"min_samples":1,"min_coverage":1,"max_error":0}}',encoding='utf-8')
        execute(command+['--requirements',str(strict)],expected=3)
        assert json.loads(output.read_text(encoding='utf-8'))['acceptance']['accepted'] is False
        passed('installed-state-acceptance-failure-publishes-report-and-exits-three')
        saved = output.read_bytes()
        partial_state = directory/'partial.sqlite'
        jobs.replay(binary,source,partial_state,max_frames=9)
        partial_command = list(command)
        partial_command[partial_command.index('--state')+1] = str(partial_state)
        execute(partial_command,expected=2)
        assert output.read_bytes() == saved
        execute(partial_command+['--allow-partial','--requirements',str(limits)],expected=3)
        partial_report = json.loads(output.read_text(encoding='utf-8'))
        assert partial_report['measurement_source']['frames'] == 9 and not partial_report['measurement_source']['complete']
        assert partial_report['evaluation']['position_coverage'] == 9/24
        passed('installed-partial-selection-is-explicit-and-keeps-coverage-failures')
        saved = output.read_bytes()
        corrupt_command = list(command)
        corrupt_command[corrupt_command.index('--state')+1] = str(directory/'corrupt.sqlite')
        execute(corrupt_command,expected=2)
        assert output.read_bytes() == saved
        passed('installed-corrupt-state-returns-two-and-keeps-the-existing-report')
        execute(command+['--measurements',str(complete_log)],expected=2)
        execute(command[:command.index('--state')]+['--measurements',str(complete_log),'--references',str(reference),'--allow-partial'],expected=2)
        assert output.read_bytes() == saved
        passed('state-and-log-arguments-are-exclusive-and-partial-is-state-only')
        assert not list((prefix/'versions').rglob('__pycache__'))
        manager.status(prefix)
        passed('helper-loading-leaves-installed-slots-immutable')
    return dict(status='passed',cases=cases,binary_sha256=jobs.digest_file(binary),
                python=platform.python_version(),sqlite_version=sqlite3.sqlite_version,platform=platform.platform(),
                source_sha256=jobs.digest_file(Path(__file__)),runner_sha256=jobs.digest_file(Path(jobs.__file__)),
                adapter_sha256=jobs.digest_file(Path(adapter.__file__)),manager_sha256=jobs.digest_file(Path(manager.__file__)),
                support_sha256=jobs.digest_file(ROOT/'validation/cli_jobs_verify.py'),
                larger_job=dict(frames=4096,python_peak_bytes=peak,logical_state_bytes=large_info['logical_state_bytes']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--output',type=Path)
    args = parser.parse_args()
    result = portable_report(suite(args.binary.resolve()))
    result['command'] = portable_report('python '+' '.join(sys.argv))
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result))


if __name__=='__main__':
    main()
