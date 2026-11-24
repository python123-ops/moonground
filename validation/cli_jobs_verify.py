#!/usr/bin/env python3
"""Exercise real native replay, SQLite commit crashes and bounded long streams."""

import argparse
import copy
import contextlib
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import queue
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'tools'))
import moonground_jobs as jobs
from public_reports import portable_report
from stream_test import process_memory


def records(values):
    return ('\n'.join(jobs.encode(value) for value in values)+'\n').encode('utf-8')


def fixture(frames=24, targets=3, diagnostics=True):
    header = dict(session_id='durable-replay', mode='ground', diagnostics=diagnostics,
                  motion=dict(max_tracks=targets))
    rows = [dict(timestamp_us=str(i*200000), observations=[
        dict(track_id=identity, point=[identity+i*0.01,0], covariance=[0.01,0,0.01])
        for identity in range(1,targets+1)]) for i in range(frames)]
    return [header]+rows


def execute(command, data=None, expected=0, timeout=120):
    result = subprocess.run(command, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    assert result.returncode == expected, (result.returncode,result.stderr.decode('utf-8','replace')[-3000:])
    return result.stdout


def native(binary, mode, data, expected=0):
    return execute([str(binary),mode],data,expected)


def equivalent(left, right):
    assert [json.loads(line) for line in left.splitlines()] == [json.loads(line) for line in right.splitlines()]


def fault_worker(binary, source, state, phase):
    real_connect = sqlite3.connect
    class Connection(sqlite3.Connection):
        def execute(self, statement, parameters=()):
            if statement == 'COMMIT':
                try:
                    document = self.execute('SELECT document FROM job WHERE id=1').fetchone()
                    armed = document is not None and json.loads(document[0])['commits'] == 2
                except sqlite3.Error:
                    armed = False
                if armed and phase == 'before':
                    print('paused',flush=True)
                    sys.stdin.read(1)
                value = super().execute(statement, parameters)
                if armed and phase == 'after':
                    print('paused',flush=True)
                    sys.stdin.read(1)
                return value
            return super().execute(statement, parameters)
    def connect(*args, **kwargs):
        kwargs['factory'] = Connection
        return real_connect(*args, **kwargs)
    with mock.patch.object(jobs.sqlite3,'connect',connect):
        jobs.replay(binary,source,state,batch_frames=4)


def wait_line(process):
    result = queue.Queue()
    threading.Thread(target=lambda: result.put(process.stdout.readline()),daemon=True).start()
    return result.get(timeout=30).strip()


def suite(binary):
    cases = []
    def passed(name):
        cases.append(dict(name=name,passed=True))
    with tempfile.TemporaryDirectory(prefix='moonground-jobs-') as temporary:
        directory = Path(temporary)/'space \u6d4b\u8bd5'
        directory.mkdir()
        source, state = directory/'input.ndjson', directory/'measurements.sqlite'
        values = fixture()
        source.write_bytes(records(values))
        baseline = native(binary,'--stream',source.read_bytes())
        journal = native(binary,'--stream-checkpoint',source.read_bytes())
        lines = journal.splitlines(keepends=True)
        equivalent(b''.join(lines[:-1]),baseline)
        assert set(json.loads(lines[-1])) == {'resume'}
        assert json.loads(lines[-1])['resume'] == json.loads(native(binary,'--checkpoint',source.read_bytes()))
        passed('one-pass-measurements-and-final-checkpoint')
        partial = native(binary,'--stream-checkpoint',records(values[:6]))
        head = partial.splitlines()[-1]
        suffix = native(binary,'--stream',head+b'\n'+records(values[6:]))
        equivalent(suffix,b''.join(baseline.splitlines(keepends=True)[5:]))
        passed('journal-final-header-resumes-native-stream')
        empty = native(binary,'--stream-checkpoint',records(values[:1]))
        assert len(empty.splitlines())==1 and 'resume' in json.loads(empty)
        passed('configuration-only-checkpoint')
        crlf = records(values).replace(b'\n',b'\r\n').rstrip(b'\r\n')
        equivalent(native(binary,'--stream-checkpoint',crlf),journal)
        passed('journal-crlf-and-no-final-newline')
        failed = native(binary,'--stream-checkpoint',records(values[:5])+b'{\n',expected=2)
        assert len(failed.splitlines())==4 and all('resume' not in json.loads(line) for line in failed.splitlines())
        passed('native-failure-has-no-final-checkpoint')

        first = jobs.replay(binary,source,state,batch_frames=4,max_frames=9)
        assert first['frames']==9 and not first['complete'] and first['commits']==3
        prefix = directory/'prefix.ndjson'
        jobs.export(state,prefix)
        equivalent(prefix.read_bytes(),b''.join(baseline.splitlines(keepends=True)[:9]))
        passed('partial-replay-exports-committed-prefix')
        finished = jobs.replay(binary,source,state,batch_frames=7)
        assert finished['complete'] and finished['frames']==24
        output = directory/'output.ndjson'
        jobs.export(state,output)
        equivalent(output.read_bytes(),baseline)
        passed('resume-with-different-batch-size-without-duplicate-rows')
        commits = finished['commits']
        assert jobs.replay(binary,source,state)['commits']==commits
        passed('completed-replay-is-idempotent')
        assert jobs.status(state)['frames']==24
        passed('status-reports-only-committed-progress')

        read_state, next_state = directory/'reader.sqlite', directory/'writer.sqlite'
        jobs.replay(binary,source,read_state,max_frames=4)
        jobs.replay(binary,source,next_state,max_frames=5)
        with contextlib.closing(sqlite3.connect(str(next_state))) as connection:
            next_document = connection.execute('SELECT document FROM job WHERE id=1').fetchone()[0]
            next_payload = connection.execute('SELECT payload FROM results WHERE sequence=5').fetchone()[0]
        entered, committed = threading.Event(), threading.Event()
        writer_errors = []
        def concurrent_commit():
            try:
                with contextlib.closing(sqlite3.connect(str(read_state),timeout=5)) as connection:
                    connection.execute('BEGIN IMMEDIATE')
                    connection.execute('INSERT INTO results(sequence,payload) VALUES(5,?)',(sqlite3.Binary(next_payload),))
                    connection.execute('UPDATE job SET document=? WHERE id=1',(next_document,))
                    entered.set()
                    connection.commit()
                    committed.set()
            except BaseException as error:
                writer_errors.append(str(error))
                entered.set()
        writer = threading.Thread(target=concurrent_commit,daemon=True)
        real_decode = jobs.decode
        def read_then_commit(data):
            value = real_decode(data)
            if isinstance(value,dict) and 'input_sha256' in value:
                writer.start()
                assert entered.wait(5)
                committed.wait(0.2)
            return value
        with mock.patch.object(jobs,'decode',side_effect=read_then_commit):
            assert jobs.status(read_state)['frames']==4
        writer.join(timeout=5)
        assert not writer.is_alive() and not writer_errors and committed.is_set()
        assert jobs.status(read_state)['frames']==5
        passed('status-pins-one-snapshot-during-a-concurrent-commit')

        def rejects(name, operation, database=state):
            before = jobs.status(database)
            try:
                operation()
            except (ValueError,OSError,sqlite3.Error):
                pass
            else:
                raise AssertionError(name+' was accepted')
            assert jobs.status(database)==before,name
            passed(name)

        altered = directory/'altered.ndjson'
        altered.write_bytes(source.read_bytes()+records([values[-1]]))
        rejects('changed-input-is-rejected',lambda:jobs.replay(binary,altered,state))
        other = directory/'other.exe'
        shutil.copy2(binary,other)
        with other.open('ab') as stream: stream.write(b'changed')
        rejects('changed-native-binary-is-rejected',lambda:jobs.replay(other,source,state))
        for name,target in [('input',source),('binary',binary),('database',state)]:
            rejects('export-cannot-overwrite-'+name,lambda target=target:jobs.export(state,target,True))
        rejects('export-existing-file-requires-explicit-replacement',lambda:jobs.export(state,output))
        original = output.read_bytes()
        with mock.patch.object(jobs.os,'replace',side_effect=OSError('injected export replacement failure')):
            rejects('failed-export-retains-existing-file',lambda:jobs.export(state,output,True))
        assert output.read_bytes()==original
        assert not list(directory.glob('.moonground-export-*'))
        with mock.patch.object(jobs.os,'fsync',side_effect=OSError('injected export sync failure')):
            rejects('failed-export-sync-retains-existing-file',lambda:jobs.export(state,output,True))
        assert output.read_bytes()==original
        passed('export-temporary-files-are-cleaned')

        for phase,expected in [('before',4),('after',8)]:
            interrupted = directory/(phase+'.sqlite')
            process = subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'_fault',
                str(binary),str(source),str(interrupted),phase],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                assert wait_line(process)==b'paused'
                process.kill()
                process.wait(timeout=10)
            finally:
                if process.poll() is None: process.kill()
                process.communicate(timeout=10)
            assert jobs.status(interrupted)['frames']==expected
            jobs.replay(binary,source,interrupted,batch_frames=5)
            restored = directory/(phase+'.ndjson')
            jobs.export(interrupted,restored)
            equivalent(restored.read_bytes(),baseline)
            passed('hard-kill-'+phase+'-commit-recovers-exactly-once')

        locked = directory/'locked.sqlite'
        lock_code = ('import sys; from pathlib import Path;sys.path.insert(0,sys.argv[1]);import moonground_jobs as j;'
                     '\nwith j.state_lock(Path(sys.argv[2])):\n print("locked",flush=True)\n sys.stdin.read(1)\n')
        process = subprocess.Popen([sys.executable,'-c',lock_code,str(ROOT/'tools'),str(locked)],
                                   stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            assert wait_line(process)==b'locked'
            try:
                jobs.replay(binary,source,locked)
            except ValueError as error:
                assert 'another replay' in str(error)
            else: raise AssertionError('concurrent replay was accepted')
            assert not locked.exists()
            process.kill()
            process.wait(timeout=10)
        finally:
            if process.poll() is None: process.kill()
            process.communicate(timeout=10)
        jobs.replay(binary,source,locked)
        passed('writer-lock-and-hard-kill-lock-release')

        bad_source = directory/'bad.ndjson'
        bad_source.write_bytes(records(values[:9])+b'{\n')
        bad_state = directory/'bad.sqlite'
        try:
            jobs.replay(binary,bad_source,bad_state,batch_frames=4)
        except ValueError: pass
        else: raise AssertionError('invalid frame committed')
        assert jobs.status(bad_state)['frames']==8
        passed('bad-later-batch-retains-earlier-commits')

        timed = directory/'timeout.sqlite'
        real_popen = subprocess.Popen
        children = []
        def stalled(command,**kwargs):
            if '--stream-checkpoint' in command:
                command = [sys.executable,'-c','import time; time.sleep(120)']
            child = real_popen(command,**kwargs)
            children.append(child)
            return child
        with mock.patch.object(jobs.subprocess,'Popen',stalled):
            try:
                jobs.replay(binary,source,timed,timeout=0.1)
            except ValueError as error: assert 'timed out' in str(error)
            else: raise AssertionError('stalled worker did not time out')
        assert all(child.poll() is not None for child in children)
        assert jobs.status(timed)['frames']==0
        jobs.replay(binary,source,timed)
        passed('native-timeout-terminates-child-and-retains-progress')

        large = directory/'large.ndjson'
        large.write_bytes(records(fixture(160,32)))
        quota = directory/'quota.sqlite'
        try:
            jobs.replay(binary,large,quota,batch_frames=8,max_state_mib=1)
        except sqlite3.OperationalError as error: assert 'full' in str(error)
        else: raise AssertionError('database quota was not reached')
        quota_prefix = jobs.status(quota)
        assert 0 < quota_prefix['frames'] < 160 and quota_prefix['frames']%8==0
        assert quota_prefix['logical_state_bytes']<=1024*1024
        jobs.replay(binary,large,quota,batch_frames=8,max_state_mib=16)
        large_output = directory/'large-output.ndjson'
        jobs.export(quota,large_output)
        equivalent(large_output.read_bytes(),native(binary,'--stream',large.read_bytes()))
        passed('sqlite-full-rolls-back-and-larger-budget-resumes')

        foreign = directory/'foreign.sqlite'
        with contextlib.closing(sqlite3.connect(str(foreign))) as db:
            db.execute('CREATE TABLE unrelated(value TEXT)')
            db.commit()
        original = foreign.read_bytes()
        try: jobs.replay(binary,source,foreign)
        except ValueError: pass
        else: raise AssertionError('unrelated database was reused')
        assert foreign.read_bytes()==original
        passed('unrelated-database-remains-unchanged')
        partial_state = directory/'metadata.sqlite'
        jobs.replay(binary,source,partial_state,max_frames=4)
        with contextlib.closing(sqlite3.connect(str(partial_state))) as db:
            db.execute('DELETE FROM results WHERE sequence=2')
            db.commit()
        try: jobs.replay(binary,source,partial_state)
        except ValueError: pass
        else: raise AssertionError('checkpoint/result mismatch was ignored')
        passed('checkpoint-and-result-gap-is-rejected')
    return cases


def soak(binary, seconds, targets):
    process = subprocess.Popen([str(binary),'--stream'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE,bufsize=65536)
    started = time.monotonic()
    progress = dict(written=0,read=0)
    errors = []
    done = threading.Event()
    memory = dict(samples=0,native_peak=0,parent_peak=0,first_min=None,late_max=None)
    current = SimpleNamespace(pid=os.getpid(), _handle=-1)
    def writer():
        try:
            process.stdin.write(records([dict(session_id='continuous-churn',mode='ground',motion=dict(max_tracks=targets))]))
            index = 0
            while time.monotonic()-started < seconds:
                cohort,phase = divmod(index,33)
                identities = [cohort*targets+identity for identity in range(1,targets+1)]
                value = dict(timestamp_us=str(index*100000),observations=[])
                if phase==32: value['removed']=identities
                else: value['observations']=[dict(track_id=identity,point=[j+phase*0.01,0],covariance=[0.01,0,0.01]) for j,identity in enumerate(identities)]
                process.stdin.write(records([value]))
                index+=1
                progress['written']=index
            process.stdin.close()
        except BaseException as error: errors.append(str(error))
    def monitor():
        while not done.wait(0.1):
            native_memory,parent_memory = process_memory(process),process_memory(current)
            elapsed = time.monotonic()-started
            if elapsed > seconds+30:
                errors.append('native process did not finish within the drain timeout')
                process.kill()
                break
            if native_memory and parent_memory:
                memory['samples']+=1
                memory['native_peak']=max(memory['native_peak'],native_memory[0])
                memory['parent_peak']=max(memory['parent_peak'],parent_memory[0])
                if seconds/4<=elapsed<seconds/2:
                    memory['first_min']=min(memory['first_min'] if memory['first_min'] is not None else native_memory[0],native_memory[0])
                if elapsed>=seconds/2:
                    memory['late_max']=max(memory['late_max'] or 0,native_memory[0])
            if native_memory and native_memory[0]>256*1024*1024:
                errors.append('native RSS exceeded 256 MiB')
                process.kill()
                break
    producer = threading.Thread(target=writer,daemon=True)
    sampler = threading.Thread(target=monitor,daemon=True)
    producer.start()
    sampler.start()
    digest = hashlib.sha256()
    try:
        for line in process.stdout:
            assert line.endswith(b'\n')
            value = json.loads(line)
            cohort,phase = divmod(progress['read'],33)
            if phase==32:
                assert len(value['tracks'])==0 and len(value['closed_segment_ids'])==targets
            else:
                assert len(value['tracks'])==targets
                assert all(track['accepted_count']==phase+1 for track in value['tracks'])
            assert value['timestamp_us']==str(progress['read']*100000)
            digest.update(line)
            progress['read']+=1
            # Periodic slow consumption exercises actual pipe backpressure.
            if progress['read']%1000==0: time.sleep(0.02)
        assert process.wait(timeout=30)==0
        assert not process.stderr.read()
        producer.join(timeout=5)
        assert not producer.is_alive() and not errors and progress['read']==progress['written']
    finally:
        done.set()
        if process.poll() is None: process.kill()
        process.wait()
        sampler.join(timeout=5)
        producer.join(timeout=5)
    elapsed = time.monotonic()-started
    assert elapsed>=seconds and memory['samples'] and memory['first_min'] is not None and memory['late_max'] is not None
    growth = memory['late_max']-memory['first_min']
    assert growth<=32*1024*1024, 'native late RSS growth exceeded 32 MiB'
    return dict(status='passed',requested_seconds=seconds,wall_seconds=elapsed,targets_per_active_frame=targets,
                frames=progress['read'],frames_per_second=progress['read']/elapsed,stdout_sha256=digest.hexdigest(),
                workload='32 observed frames then explicit removal; fresh identities in each cycle; slowed reader every 1000 results',
                memory_samples=memory['samples'],native_peak_rss_bytes=memory['native_peak'],
                parent_peak_rss_bytes=memory['parent_peak'],native_late_growth_bytes=growth,
                native_rss_limit_bytes=256*1024*1024,native_late_growth_limit_bytes=32*1024*1024)


def main():
    if len(sys.argv)>1 and sys.argv[1]=='_fault':
        fault_worker(Path(sys.argv[2]),Path(sys.argv[3]),Path(sys.argv[4]),sys.argv[5])
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--soak-seconds',type=float,default=30)
    parser.add_argument('--targets',type=int,default=10)
    args = parser.parse_args()
    if not 4<=args.soak_seconds<=259200 or not 1<=args.targets<=128:
        parser.error('soak-seconds must be 4..259200 and targets 1..128')
    binary = args.binary.resolve()
    started = time.monotonic()
    cases = suite(binary)
    result = dict(status='passed',cases=cases,case_count=len(cases),soak=soak(binary,args.soak_seconds,args.targets),
                  sqlite_version=sqlite3.sqlite_version,python=platform.python_version(),platform=platform.platform(),
                  source_sha256=jobs.digest_file(Path(__file__).resolve()),runner_sha256=jobs.digest_file(ROOT/'tools/moonground_jobs.py'),
                  sampler_sha256=jobs.digest_file(ROOT/'validation/stream_test.py'),
                  binary_sha256=jobs.digest_file(binary),elapsed_seconds=time.monotonic()-started,
                  command='python '+' '.join(sys.argv))
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_bytes((json.dumps(portable_report(result),indent=2)+'\n').encode('utf-8'))
    print(json.dumps(dict(status='passed',cases=len(cases),soak=result['soak'])))


if __name__=='__main__':
    main()
