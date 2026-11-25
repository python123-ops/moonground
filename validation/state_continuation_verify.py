#!/usr/bin/env python3
"""Check append-only SQLite evaluation against fresh native and Decimal results."""

import argparse
import contextlib
import copy
from decimal import getcontext
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import sqlite3
import sys
import tempfile
from types import SimpleNamespace
from unittest import mock

from cli_jobs_verify import execute, fixture, jobs, records
from public_reports import portable_report
import measurement_evaluation_verify as reference

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'examples'))
import evaluate_measurements as adapter
import moonground_cli as manager
import package_cli as packager


def suite(binary):
    getcontext().prec = 160
    cases = []
    statistics = dict(scalars=0, exact_fields=0, maximum_tolerance_fraction=0,
                      maximum_absolute_error_by_unit=dict(m=0, mps=0, dimensionless=0))
    def passed(name):
        cases.append(dict(name=name, passed=True))
    with tempfile.TemporaryDirectory(prefix='moonground-state-continuation-') as temporary:
        directory = Path(temporary)/'space \u6d4b\u8bd5'
        directory.mkdir()
        source, state, refs = [directory/name for name in ['input.ndjson', 'job.sqlite', 'reference.ndjson']]
        source.write_bytes(records(fixture(frames=12)))
        truths = [dict(timestamp_us=str(i*100000), samples=[
            dict(track_id=identity, position_m=[identity+i*0.005, 0], speed_mps=0.05)
            for identity in range(1, 4)]) for i in range(27)]
        refs.write_bytes(records(truths))
        config = SimpleNamespace(binary=binary, measurements=None, references=refs, requirements=None,
                                 checkpoint=False, committed_only=True, resume=None, output=None,
                                 session_id=None, max_tracks=None, max_samples=None,
                                 max_line_bytes=1048576, timeout=60)
        parent, output = directory/'parent.json', directory/'output.json'
        output.write_bytes(b'previous report\n')
        config.output = output
        def save(report, path=parent):
            path.write_text(json.dumps(report, separators=(',', ':'), allow_nan=False)+'\n', encoding='utf-8')
        def evaluate(path=state, partial=True):
            return adapter.evaluate(config, jobs.MeasurementSource(path, partial))
        def rejected(name, path=state, text=None):
            saved_output = output.read_bytes()
            saved_parent = parent.read_bytes() if parent.exists() else None
            try:
                evaluate(path)
            except (ValueError, OSError) as error:
                if text:
                    assert text in str(error), str(error)
            else:
                raise AssertionError('expected rejection: '+name)
            assert output.read_bytes() == saved_output
            if saved_parent is not None:
                assert parent.read_bytes() == saved_parent
            passed(name)
        def independent(report, path=state):
            rows = []
            with contextlib.closing(sqlite3.connect(str(path))) as connection:
                observed = [json.loads(row[0]) for row in connection.execute('SELECT payload FROM results ORDER BY sequence')]
            measured = {int(row['timestamp_us']):row for row in observed}
            through = max(measured) if measured else -1
            selected = {int(row['timestamp_us']):row for row in truths if int(row['timestamp_us']) <= through}
            for clock in sorted(set(measured)|set(selected)):
                rows.append(dict(measurement=measured.get(clock, json.loads(adapter.empty_measurement('durable-replay', clock))),
                                 reference=selected.get(clock, dict(timestamp_us=str(clock), samples=[]))))
            expected, scales = reference.offline_report(rows, session_id='durable-replay')
            reference.compare(report['evaluation'], expected, scales, statistics)

        jobs.replay(binary, source, state, max_frames=3, batch_frames=3)
        with contextlib.suppress(ValueError):
            evaluate(partial=False)
            raise AssertionError('incomplete state accepted implicitly')
        passed('committed-window-still-requires-explicit-partial-selection')
        first = evaluate()
        assert first['alignment'] == dict(paired_frames=3, measurement_only_frames=0, reference_only_frames=2)
        assert first['reference_cursor']['prefix_records'] == '5'
        assert first['reference_cursor']['deferred_records'] == '22'
        assert first['resume']['last_timestamp_us'] == '400000'
        assert first['measurement_source']['evaluated_frames'] == 3
        independent(first)
        passed('initial-window-includes-reference-only-gaps-and-defers-future-references')
        partial_copy = directory/'prefix.sqlite'
        shutil.copyfile(state, partial_copy)
        config.committed_only = False
        all_refs = evaluate()
        assert all_refs['alignment']['reference_only_frames'] == 24
        assert int(all_refs['evaluation']['counts']['missing']) > int(first['evaluation']['counts']['missing'])
        passed('default-snapshot-retains-all-future-reference-misses')
        config.checkpoint = True
        save(evaluate())
        config.committed_only, config.resume = True, parent
        rejected('old-snapshot-checkpoint-cannot-silently-acquire-a-reference-cursor', text='--committed-only report')
        config.checkpoint = False
        save(first)
        unchanged = evaluate()
        assert unchanged['evaluation'] == first['evaluation'] and unchanged['resume'] == first['resume']
        assert sum(unchanged['alignment'].values()) == 0
        assert unchanged['measurement_source']['evaluated_frames'] == 0
        passed('unchanged-state-continuation-does-not-repeat-any-calculation')
        refs.write_bytes(records(truths + [dict(timestamp_us='2800000', samples=[])]))
        future = evaluate()
        assert future['resume'] == first['resume']
        assert future['reference_cursor']['file_sha256'] != first['reference_cursor']['file_sha256']
        passed('unprocessed-future-reference-appends-are-allowed-and-fingerprinted')
        refs.write_bytes(records(truths).replace(b'\n', b'\r\n'))
        assert evaluate()['resume'] == first['resume']
        passed('reference-prefix-identity-survives-line-ending-normalization')
        refs.write_bytes(records(truths))
        for count, previous_frames, expected_refs in [(3, 3, '6'), (6, 6, '12')]:
            jobs.replay(binary, source, state, max_frames=count, batch_frames=3)
            continued = evaluate()
            assert continued['measurement_source']['previous_frames'] == previous_frames
            assert continued['measurement_source']['evaluated_frames'] == count
            assert continued['reference_cursor']['evaluated_records'] == expected_refs
            config.resume = None
            fresh = evaluate()
            assert continued['evaluation'] == fresh['evaluation'] and continued['resume'] == fresh['resume']
            independent(continued)
            config.resume = parent
            save(continued)
            passed('append-{}-frames-matches-fresh-native-and-independent-decimal-statistics'.format(count))
        final = continued
        assert final['measurement_source']['complete'] and final['reference_cursor']['prefix_records'] == '23'
        assert final['reference_cursor']['deferred_records'] == '4'
        rejected('older-database-snapshot-cannot-follow-a-newer-report', partial_copy, 'behind')
        bad_state = directory/'changed.sqlite'
        mutations = [
            ('old-measurement-edit', None),
            ('different-input', lambda c:c.execute("UPDATE job SET document=replace(document,?,?)", (jobs.digest_file(source), 'a'*64))),
            ('different-producer', lambda c:c.execute("UPDATE job SET document=replace(document,?,?)", (jobs.digest_file(binary), 'b'*64))),
        ]
        for name, mutate in mutations:
            shutil.copyfile(state, bad_state)
            with contextlib.closing(sqlite3.connect(str(bad_state))) as connection, connection:
                if name == 'old-measurement-edit':
                    raw, = connection.execute('SELECT payload FROM results WHERE sequence=1').fetchone()
                    value = json.loads(raw)
                    value['tracks'][0]['position_m'][0] += 1
                    connection.execute('UPDATE results SET payload=? WHERE sequence=1', (records([value]),))
                else:
                    mutate(connection)
            rejected('reject-'+name, bad_state)
        # Reference changes before the watermark cannot change an existing result.
        changed = copy.deepcopy(truths)
        changed[0]['samples'][0]['position_m'][0] += 1
        bad_logs = [
            ('historical-reference-edit', records(changed)),
            ('historical-reference-delete', records(truths[1:])),
            ('historical-reference-backfill', records(truths[:1]+[dict(timestamp_us='1', samples=[])]+truths[1:])),
            ('historical-reference-truncate', records(truths[:5])),
            ('invalid-future-json', records(truths)+b'{bad}\n'),
            ('future-order-error', records(truths)+records([dict(timestamp_us='1', samples=[])])),
            ('future-duplicate-key', records(truths)+b'{"timestamp_us":"3000000","samples":[],"samples":[]}\n'),
        ]
        for name, data in bad_logs:
            refs.write_bytes(data)
            rejected('reject-'+name)
        refs.write_bytes(records(truths))
        save(first)
        invalid_truths = records(truths).replace(b'"position_m":[1.03,0]', b'"position_m":[1e-9999,0]')
        assert b'1e-9999' in invalid_truths
        refs.write_bytes(invalid_truths)
        config.resume = None
        assert evaluate(partial_copy)['resume'] == first['resume']
        config.resume = parent
        rejected('deferred-sample-schema-is-checked-when-it-enters-the-window', text='evaluation failed')
        refs.write_bytes(records(truths))
        shutil.copyfile(state, bad_state)
        with contextlib.closing(sqlite3.connect(str(bad_state))) as connection, connection:
            raw, = connection.execute('SELECT payload FROM results WHERE sequence=4').fetchone()
            raw = re.sub(br'("position_m":\[)[^,]+', br'\g<1>1e-9999', raw, count=1)
            assert b'1e-9999' in raw
            connection.execute('UPDATE results SET payload=? WHERE sequence=4', (raw,))
        rejected('new-raw-measurement-underflow-is-rejected-by-native-validation', bad_state, 'evaluation failed')
        save(final)
        # A new record at/before the old watermark is a backfill even when the
        # old prefix is empty, e.g. measurements originally had no references.
        no_refs = directory/'no-refs.ndjson'
        no_refs.write_bytes(b'')
        config.references, config.resume = no_refs, None
        no_reference_report = evaluate()
        save(no_reference_report)
        config.resume = parent
        no_refs.write_bytes(records([dict(timestamp_us='2200000', samples=[])]))
        rejected('reject-new-reference-at-already-evaluated-watermark', text='backfill')
        config.references = refs
        save(final)
        for name, mutate in [
            ('cursor-version', lambda d:d['reference_cursor'].update(version=2)),
            ('cursor-count-type', lambda d:d['reference_cursor'].update(prefix_records=23)),
            ('cursor-count-spelling', lambda d:d['reference_cursor'].update(prefix_records='023')),
            ('cursor-hash', lambda d:d['reference_cursor'].update(record_prefix_sha256='f'*64)),
            ('cursor-watermark', lambda d:d['reference_cursor'].update(through_timestamp_us='0')),
            ('checkpoint-watermark', lambda d:d['resume'].update(last_timestamp_us='0')),
            ('snapshot-count-type', lambda d:d['measurement_source'].update(frames='12')),
            ('snapshot-offset-regression', lambda d:d['measurement_source'].update(input_offset=d['measurement_source']['input_bytes']+1)),
            ('snapshot-digest', lambda d:d['measurement_source'].update(results_sha256='F'*64)),
        ]:
            invalid = copy.deepcopy(final)
            mutate(invalid)
            save(invalid)
            rejected('reject-invalid-'+name)
        save(final)
        snapshot, restored = directory/'backup.sqlite', directory/'restored.sqlite'
        backup = jobs.backup(state, snapshot)
        jobs.restore(snapshot, restored, backup['sha256'])
        assert evaluate(restored)['resume'] == final['resume']
        passed('physical-backup-and-restore-preserve-logical-continuation-identity')
        limits = directory/'requirements.json'
        limits.write_text('{"position_m":{"min_samples":1,"min_coverage":1,"max_error":1}}', encoding='utf-8')
        config.requirements = limits
        assert evaluate()['acceptance']['accepted'] is False
        passed('new-requirements-check-the-complete-cumulative-statistics')
        config.requirements = None
        assert 'acceptance' not in evaluate()
        passed('requirements-are-explicit-per-call-and-not-inherited-from-a-parent')
        # The source can be initialized before any native batch has committed.
        empty_state = directory/'zero.sqlite'
        with mock.patch.object(jobs, '_native', side_effect=ValueError('before first commit')):
            with contextlib.suppress(ValueError):
                jobs.replay(binary, source, empty_state)
        config.resume, config.session_id = None, 'durable-replay'
        zero = evaluate(empty_state)
        assert zero['reference_cursor']['prefix_records'] == '0' and zero['reference_cursor']['through_timestamp_us'] is None
        assert zero['evaluation']['counts']['frames'] == '0'
        save(zero)
        config.resume = parent
        jobs.replay(binary, source, empty_state)
        assert evaluate(empty_state)['resume'] == final['resume']
        passed('zero-committed-frames-defer-all-references-and-can-start-later')
        # Preserve exact Int64 clocks above JavaScript's integer precision.
        exact_source, exact_state = directory/'exact.ndjson', directory/'exact.sqlite'
        values = fixture(frames=3)
        for row in values[1:]:
            row['timestamp_us'] = str(int(row['timestamp_us'])+9007199254740993)
        exact_source.write_bytes(records(values))
        exact_truths = [dict(timestamp_us=row['timestamp_us'], samples=[]) for row in values[1:]]
        refs.write_bytes(records(exact_truths[:1]).rstrip(b'\n'))
        config.resume = None
        jobs.replay(binary, exact_source, exact_state, max_frames=1)
        exact_first = evaluate(exact_state)
        assert exact_first['reference_cursor']['through_timestamp_us'] == '9007199254740993'
        save(exact_first)
        config.resume = parent
        refs.write_bytes(records(exact_truths))
        jobs.replay(binary, exact_source, exact_state)
        exact_final = evaluate(exact_state)
        assert exact_final['resume']['last_timestamp_us'] == '9007199255140993'
        assert exact_final['measurement_source']['evaluated_frames'] == 2
        passed('int64-clocks-and-append-after-missing-final-newline-remain-exact')
        refs.write_bytes(records(truths))
        config.resume, config.session_id = None, None
        bundle = packager.create_bundle(binary, directory/'bundle', packager.module_version(), '0'*40, True)
        prefix = directory/'installed'
        manager.install_archive(prefix, directory/'bundle'/bundle['archive'], bundle['sha256'])
        command = [sys.executable, str(ROOT/'tools/moonground_cli.py'), '--prefix', str(prefix), 'evaluate',
                   '--state', str(state), '--committed-only', '--references', str(refs), '--output', str(output)]
        execute(command)
        installed_first = json.loads(output.read_text(encoding='utf-8'))
        assert installed_first['evaluation'] == final['evaluation']
        save(installed_first)
        execute(command+['--resume', str(parent)])
        installed_repeat = json.loads(output.read_text(encoding='utf-8'))
        assert installed_repeat['resume'] == final['resume'] and sum(installed_repeat['alignment'].values()) == 0
        passed('installed-manager-loads-verified-helpers-and-continues-only-new-rows')
        execute(command+['--resume', str(parent), '--requirements', str(limits)], expected=3)
        assert json.loads(output.read_text(encoding='utf-8'))['acceptance']['accepted'] is False
        passed('installed-cumulative-acceptance-failure-publishes-report-and-exits-three')
        saved = output.read_bytes()
        bad_command = list(command)
        bad_command.remove('--committed-only')
        execute(bad_command+['--resume', str(parent)], expected=2)
        assert output.read_bytes() == saved
        passed('state-resume-requires-explicit-committed-window-mode')
        log = directory/'export.ndjson'
        jobs.export(state, log)
        bad_command = list(command)
        bad_command[bad_command.index('--state')] = '--measurements'
        bad_command[bad_command.index(str(state))] = str(log)
        execute(bad_command, expected=2)
        assert output.read_bytes() == saved
        passed('committed-window-mode-is-state-only')
        assert not list((prefix/'versions').rglob('__pycache__'))
        manager.status(prefix)
        passed('installed-version-slots-stay-immutable')
    digest = jobs.digest_file
    return dict(status='passed', cases=cases, independent_statistics=statistics,
                binary_sha256=digest(binary), python=platform.python_version(), sqlite_version=sqlite3.sqlite_version,
                platform=platform.platform(), source_sha256=digest(Path(__file__)),
                runner_sha256=digest(Path(jobs.__file__)), adapter_sha256=digest(Path(adapter.__file__)),
                manager_sha256=digest(Path(manager.__file__)), support_sha256=digest(ROOT/'validation/cli_jobs_verify.py'),
                reference_sha256=digest(Path(reference.__file__)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = portable_report(suite(args.binary.resolve()))
    result['command'] = portable_report('python '+' '.join(sys.argv))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
