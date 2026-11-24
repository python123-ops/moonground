#!/usr/bin/env python3
"""Run paced SQLite replay jobs with backup/restore and bounded disk retention."""

import argparse
import contextlib
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
from types import SimpleNamespace

from cli_jobs_verify import jobs, records
from public_reports import portable_report
from stream_test import process_memory

ROOT = Path(__file__).resolve().parent.parent


def write_report(path, report):
    report['updated_utc'] = datetime.now(timezone.utc).isoformat()
    staging = path.with_name(path.name+'.tmp')
    staging.write_bytes((json.dumps(portable_report(report), indent=2)+'\n').encode('utf-8'))
    os.replace(str(staging), str(path))


def prefix_hash(path, frames):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for _ in range(frames):
            line = stream.readline()
            if not line or not line.endswith(b'\n'):
                raise AssertionError('reference output is missing a complete frame')
            digest.update(line)
    return digest.hexdigest()


def workload(path, frames, targets):
    with path.open('wb') as stream:
        stream.write(records([dict(session_id='sqlite-soak', mode='ground', diagnostics=True,
                                   motion=dict(max_tracks=targets))]))
        for index in range(frames):
            cohort, phase = divmod(index, 33)
            identities = [cohort*targets+i for i in range(1, targets+1)]
            frame = dict(timestamp_us=str(index*100000), observations=[])
            if phase == 32:
                frame['removed'] = identities
            else:
                frame['observations'] = [dict(track_id=identity, point=[i+phase*0.01, 0], covariance=[0.01, 0, 0.01])
                                         for i, identity in enumerate(identities)]
            stream.write(records([frame]))


@contextlib.contextmanager
def keep_running():
    # A day-long test should keep the machine awake without keeping its display
    # on. Manual suspend is detected by the sampling-gap check below.
    if os.name == 'nt':
        import ctypes
        state = ctypes.windll.kernel32.SetThreadExecutionState(0x80000001)
        if not state:
            raise OSError('cannot request system wakefulness for the soak test')
    try:
        yield
    finally:
        if os.name == 'nt':
            ctypes.windll.kernel32.SetThreadExecutionState(0x80000000)


def run(args):
    run_dir = args.run_dir.resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    if any(run_dir.iterdir()):
        raise ValueError('run-dir must be empty; use a new directory for each continuous run')
    directory = run_dir/'workload'
    directory.mkdir()
    binary = args.binary.resolve()
    report_path = run_dir/'result.json'
    source, expected = directory/'input.ndjson', directory/'expected.ndjson'
    workload(source, args.frames_per_job, args.targets)
    with source.open('rb') as incoming, expected.open('wb') as outgoing:
        subprocess.run([str(binary), '--stream'], stdin=incoming, stdout=outgoing, stderr=subprocess.PIPE, check=True, timeout=60)
    expected_digest = prefix_hash(expected, args.frames_per_job)
    current = SimpleNamespace(pid=os.getpid(), _handle=-1)
    first_sample = process_memory(current)
    for _ in range(2000):
        last_sample = process_memory(current)
    if not first_sample or not last_sample or last_sample[0]-first_sample[0] > 4*1024*1024:
        raise AssertionError('resource sampler grew by more than 4 MiB in 2,000 repeated queries')
    started = time.monotonic()
    report = dict(status='running', started_utc=datetime.now(timezone.utc).isoformat(),
                  requested_seconds=args.seconds, wall_seconds=0, committed_frames=0, completed_jobs=0,
                  backup_restore_cycles=0, batches=0, batch_seconds_total=0, batch_seconds_max=0,
                  targets_per_active_frame=args.targets, frames_per_job=args.frames_per_job,
                  batch_frames=args.batch_frames, paced_frames_per_second=args.frames_per_second,
                  max_work_bytes=args.max_work_mib*1024*1024, disk_peak_bytes=0, minimum_free_bytes=None,
                  memory_samples=0, worker_peak_rss_bytes=0, native_peak_rss_bytes=0,
                  worker_early_min_bytes=None, worker_late_max_bytes=None, largest_sample_gap_seconds=0,
                  source_sha256=jobs.digest_file(Path(__file__).resolve()), runner_sha256=jobs.digest_file(ROOT/'tools/moonground_jobs.py'),
                  sampler_sha256=jobs.digest_file(ROOT/'validation/stream_test.py'),
                  support_sha256=jobs.digest_file(ROOT/'validation/cli_jobs_verify.py'),
                  sampler_selfcheck_queries=2000, sampler_selfcheck_growth_bytes=last_sample[0]-first_sample[0],
                  binary_sha256=jobs.digest_file(binary), input_sha256=jobs.digest_file(source), reference_sha256=expected_digest,
                  python=platform.python_version(), sqlite_version=sqlite3.sqlite_version, platform=platform.platform(),
                  workload='fixed files; 32 observed frames then explicit identity removal; restore each job from a halfway snapshot; delete retired job files',
                  command='python '+' '.join(sys.argv))
    stop = threading.Event()
    failures = []
    active = []
    original_popen = subprocess.Popen
    def observed_popen(*parameters, **options):
        process = original_popen(*parameters, **options)
        active[:] = [process]
        return process
    def sample():
        previous = time.monotonic()
        last_disk = previous-5
        while not stop.wait(0.05):
            now = time.monotonic()
            report['largest_sample_gap_seconds'] = max(report['largest_sample_gap_seconds'], now-previous)
            if now-previous > 60:
                failures.append('sampling gap exceeded 60 seconds; continuous execution was interrupted')
            previous = now
            elapsed = now-started
            memory = process_memory(current)
            if memory:
                rss = memory[0]
                report['memory_samples'] += 1
                report['worker_peak_rss_bytes'] = max(report['worker_peak_rss_bytes'], rss)
                if args.seconds/4 <= elapsed < args.seconds/2:
                    report['worker_early_min_bytes'] = min(report['worker_early_min_bytes'] or rss, rss)
                if elapsed >= args.seconds/2:
                    report['worker_late_max_bytes'] = max(report['worker_late_max_bytes'] or 0, rss)
                if rss > 256*1024*1024:
                    failures.append('SQLite worker RSS exceeded 256 MiB')
            for process in active[:]:
                native_memory = process_memory(process)
                if native_memory:
                    report['native_peak_rss_bytes'] = max(report['native_peak_rss_bytes'], native_memory[0])
                    if native_memory[0] > 256*1024*1024:
                        failures.append('native batch RSS exceeded 256 MiB')
            if now-last_disk >= 5:
                total = 0
                for path in directory.iterdir():
                    try:
                        if path.is_file():
                            total += path.stat().st_size
                    except FileNotFoundError:
                        pass  # A completed native batch can remove its temporary file.
                free = shutil.disk_usage(directory).free
                report['disk_peak_bytes'] = max(report['disk_peak_bytes'], total)
                report['minimum_free_bytes'] = min(report['minimum_free_bytes'] or free, free)
                if total > report['max_work_bytes'] or free < 128*1024*1024:
                    failures.append('workload disk budget or free-space reserve was exhausted')
                report['wall_seconds'] = now-started
                write_report(report_path, report)
                last_disk = now
            if failures:
                stop.set()
                for process in active[:]:
                    if process.poll() is None:
                        process.kill()
                return
    def monitor():
        try:
            sample()
        except BaseException as error:
            failures.append('resource monitor failed: '+str(error))
            stop.set()
    def healthy():
        if failures:
            raise AssertionError(failures[0])
    def retire(paths):
        for path in paths:
            for suffix in ['', '.lock', '-journal', '-wal', '-shm']:
                item = path.with_name(path.name+suffix)
                if item.exists():
                    item.unlink()
    state, restored = directory/'job.sqlite', directory/'restored.sqlite'
    snapshot, exported = directory/'snapshot.sqlite', directory/'export.ndjson'
    active_state = state
    snapshot_done = False
    sampler = threading.Thread(target=monitor, daemon=True)
    write_report(report_path, report)
    subprocess.Popen = observed_popen
    try:
        with keep_running():
            sampler.start()
            while time.monotonic()-started < args.seconds:
                healthy()
                if report.get('last_job', {}).get('complete'):
                    retire([state, restored, snapshot, exported])
                    active_state, snapshot_done = state, False
                before = report.get('last_job', {}).get('frames', 0) if active_state.exists() else 0
                call_start = time.monotonic()
                progress = jobs.replay(binary, source, active_state, batch_frames=args.batch_frames,
                                       max_frames=args.batch_frames, max_state_mib=args.max_work_mib)
                duration = time.monotonic()-call_start
                report['batches'] += 1
                report['batch_seconds_total'] += duration
                report['batch_seconds_max'] = max(report['batch_seconds_max'], duration)
                report['committed_frames'] += progress['frames']-before
                report['last_job'] = progress
                if not snapshot_done and progress['frames'] >= args.frames_per_job//2:
                    saved = jobs.backup(active_state, snapshot, max_state_mib=args.max_work_mib)
                    jobs.restore(snapshot, restored, saved['sha256'], max_state_mib=args.max_work_mib)
                    assert jobs.verify(restored, max_state_mib=args.max_work_mib)['results_sha256'] == prefix_hash(expected, progress['frames'])
                    active_state, snapshot_done = restored, True
                    report['backup_restore_cycles'] += 1
                if progress['complete']:
                    jobs.export(active_state, exported)
                    assert jobs.digest_file(exported) == expected_digest
                    report['completed_jobs'] += 1
                healthy()
                # Pace the committed frame count, with no busy waiting. This is
                # a durability/stability profile, not a throughput benchmark.
                due = min(started+args.seconds, started+report['committed_frames']/args.frames_per_second)
                while time.monotonic() < due:
                    if stop.wait(min(1.0, due-time.monotonic())):
                        healthy()
                healthy()
            if not report['last_job']['complete']:
                jobs.export(active_state, exported)
                assert jobs.digest_file(exported) == prefix_hash(expected, report['last_job']['frames'])
            verified = jobs.verify(active_state, max_state_mib=args.max_work_mib)
            assert verified['frames'] == report['last_job']['frames']
            assert report['backup_restore_cycles'] and report['completed_jobs']
            healthy()
            early, late = report['worker_early_min_bytes'], report['worker_late_max_bytes']
            assert early is not None and late is not None and report['native_peak_rss_bytes'] > 0
            report['worker_late_growth_bytes'] = late-early
            assert report['worker_late_growth_bytes'] <= 32*1024*1024, 'SQLite worker late RSS growth exceeded 32 MiB'
            assert time.monotonic()-started >= args.seconds
            report['status'] = 'passed'
    except BaseException as error:
        report['status'] = 'interrupted' if isinstance(error, KeyboardInterrupt) else 'failed'
        report['error'] = str(error) or type(error).__name__
        raise
    finally:
        stop.set()
        if sampler.is_alive():
            sampler.join(timeout=10)
        subprocess.Popen = original_popen
        report['wall_seconds'] = time.monotonic()-started
        report['finished_utc'] = datetime.now(timezone.utc).isoformat()
        write_report(report_path, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--run-dir', type=Path, required=True)
    parser.add_argument('--seconds', type=float, default=86400)
    parser.add_argument('--targets', type=int, default=10)
    parser.add_argument('--frames-per-job', type=int, default=1024)
    parser.add_argument('--batch-frames', type=int, default=128)
    parser.add_argument('--frames-per-second', type=float, default=10)
    parser.add_argument('--max-work-mib', type=int, default=256)
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or not 10 <= args.seconds <= 259200 or not 1 <= args.targets <= 32:
        parser.error('seconds must be 10..259200 and targets 1..32')
    if not 32 <= args.frames_per_job <= 4096 or not 1 <= args.batch_frames <= args.frames_per_job//2:
        parser.error('frames-per-job must be 32..4096 and batch-frames no more than half a job')
    if not math.isfinite(args.frames_per_second) or not 1 <= args.frames_per_second <= 4096 or not 16 <= args.max_work_mib <= 4096:
        parser.error('frames-per-second must be 1..4096 and max-work-mib 16..4096')
    if args.seconds*args.frames_per_second < args.frames_per_job*2:
        parser.error('duration and frame rate must allow at least two complete jobs')
    result = run(args)
    print(json.dumps(dict(status=result['status'], wall_seconds=result['wall_seconds'], frames=result['committed_frames'],
                          completed_jobs=result['completed_jobs'], backup_restore_cycles=result['backup_restore_cycles'])))


if __name__ == '__main__':
    main()
