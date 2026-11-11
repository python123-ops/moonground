#!/usr/bin/env python3
"""Exercise the real NDJSON process and measure bounded long-stream I/O.

Uses Python's standard library. Throughput includes pipes and SHA-256 hashing;
latency is one flushed subprocess frame round trip, including pipe overhead.
Only aggregate counts, hashes, timings and memory statistics are persisted.
"""

import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BINARY = ROOT / "_build/native/release/build/cmd/main/main.exe"


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def configuration(targets=10, session="stream-protocol"):
    return encode({"session_id": session, "mode": "ground", "motion": {"max_tracks": targets}})


def frame(timestamp_us, targets=1):
    return encode({
        "timestamp_us": str(timestamp_us),
        "observations": [
            {"track_id": identity, "point": [float(identity), 0.0],
             "covariance": [0.01, 0.0, 0.01]}
            for identity in range(1, targets + 1)
        ],
    })


def decoded_lines(output):
    if output and not output.endswith(b"\n"):
        raise AssertionError("stdout contains an incomplete final line")
    return [json.loads(line) for line in output.splitlines()]


def run_case(binary, data, exit_code=0, frames=0, error_line=None, extra=()):
    process = subprocess.run(
        [str(binary), "--stream", *extra], input=data,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
    )
    if process.returncode != exit_code:
        raise AssertionError(f"exit {process.returncode}, expected {exit_code}: {process.stderr!r}")
    output = decoded_lines(process.stdout)
    if len(output) != frames:
        raise AssertionError(f"{len(output)} complete output frames, expected {frames}")
    stderr = process.stderr.decode("utf-8", errors="strict")
    if error_line is not None and f"line {error_line}:" not in stderr:
        raise AssertionError(f"wrong physical input line: {stderr!r}")
    if exit_code == 0 and stderr:
        raise AssertionError(f"unexpected stderr: {stderr!r}")
    return {
        "exit_code": process.returncode,
        "complete_output_frames": len(output),
        "stdout_bytes": len(process.stdout),
        "stdout_sha256": hashlib.sha256(process.stdout).hexdigest(),
        "stderr": stderr.strip(),
    }, output


def protocol_checks(binary):
    cases = []
    config = configuration()
    good = [frame(100000 * index) for index in range(3)]
    baseline_data = config + b"\n" + b"\n".join(good) + b"\n"
    baseline, expected = run_case(binary, baseline_data, frames=3)
    cases.append({"name": "valid_three_frame_prefix", "passed": True, **baseline})

    def check(name, data, **kwargs):
        result, output = run_case(binary, data, **kwargs)
        if output != expected[:len(output)]:
            raise AssertionError(f"{name}: preceding successful output was changed")
        cases.append({"name": name, "passed": True, **result})

    check("empty_input", b"", exit_code=2)
    check("blank_configuration", b"\n", exit_code=2, error_line=1)
    check("invalid_configuration", b'{"mode":"ground"}\n', exit_code=2, error_line=1)
    check("complete_prefix_before_bad_json", baseline_data + b"{\n",
          exit_code=2, frames=3, error_line=5)
    check("complete_prefix_before_schema_error", baseline_data +
          b'{"timestamp_us":"300000","observations":[],"extra":true}\n',
          exit_code=2, frames=3, error_line=5)
    check("invalid_utf8_after_success", config + b"\n" + good[0] + b"\n\xff\n",
          exit_code=2, frames=1, error_line=3)
    check("invalid_utf8_at_eof", config + b"\n" + good[0] + b"\n\xc3",
          exit_code=2, frames=1, error_line=3)
    check("crlf_and_final_line_without_newline", config + b"\r\n" +
          b"\r\n".join(good), frames=3)
    check("lf_and_final_line_without_newline", config + b"\n" +
          b"\n".join(good), frames=3)
    check("physical_blank_line_is_counted", config + b"\n" + good[0] + b"\n\n",
          exit_code=2, frames=1, error_line=3)

    invalid_frames = {
        "fractional_track_id": b'{"timestamp_us":"0","observations":[{"track_id":1.5,"point":[0,0]}]}',
        "overflowing_track_id": b'{"timestamp_us":"0","observations":[{"track_id":2147483648,"point":[0,0]}]}',
        "duplicate_json_key": b'{"timestamp_us":"0","observations":[],"timestamp_us":"1"}',
        "overflowing_timestamp": b'{"timestamp_us":"9223372036854775808","observations":[]}',
        "numeric_timestamp": b'{"timestamp_us":0,"observations":[]}',
        "noncanonical_timestamp": b'{"timestamp_us":"00","observations":[]}',
        "nonfinite_coordinate": b'{"timestamp_us":"0","observations":[{"track_id":1,"point":[1e999,0]}]}',
        "duplicate_observation": b'{"timestamp_us":"0","observations":[{"track_id":1,"point":[0,0]},{"track_id":1,"point":[1,0]}]}',
        "excessive_json_depth": b'{"timestamp_us":"0","observations":[],"x":' + b"[" * 40 + b"0" + b"]" * 40 + b"}",
    }
    for name, invalid in invalid_frames.items():
        check(name, config + b"\n" + invalid + b"\n", exit_code=2, error_line=2)

    # Non-ASCII configuration proves the transport limit counts UTF-8 bytes.
    unicode_config = configuration(session="仓储测量")
    limit = 512
    padded_frame = good[0] + b" " * (limit - len(good[0]))
    data = unicode_config + b"\n" + padded_frame + b"\n"
    exact, parsed = run_case(binary, data, frames=1,
                             extra=("--max-line-bytes", str(limit)))
    if parsed[0]["session_id"] != "仓储测量":
        raise AssertionError("UTF-8 session identifier changed")
    cases.append({"name": "line_byte_limit_exact", "passed": True,
                  "line_bytes_excluding_lf": limit, **exact})
    minus, _ = run_case(binary, data, exit_code=2, error_line=2,
                        extra=("--max-line-bytes", str(limit - 1)))
    cases.append({"name": "line_byte_limit_one_less", "passed": True, **minus})

    # A shared regular-file offset reveals how much the child actually read.
    # The sparse suffix is never loaded by this test process or by the child.
    total_bytes = 64 * 1024 * 1024
    with tempfile.TemporaryFile() as source:
        source.write(config + b"\n" + b" " * (limit + 1))
        source.seek(total_bytes - 1)
        source.write(b"x")
        source.flush()
        source.seek(0)
        process = subprocess.run(
            [str(binary), "--stream", "--max-line-bytes", str(limit)],
            stdin=source, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
        )
        read_offset = os.lseek(source.fileno(), 0, os.SEEK_CUR)
    if process.returncode != 2 or process.stdout or b"line 2:" not in process.stderr:
        raise AssertionError(f"early oversized-line exit failed: {process.stderr!r}")
    if not 0 < read_offset < total_bytes:
        raise AssertionError(f"child consumed full oversized input ({read_offset} bytes)")
    cases.append({
        "name": "oversized_line_stops_before_complete_file",
        "passed": True, "exit_code": process.returncode,
        "input_file_bytes": total_bytes, "shared_file_read_offset_bytes": read_offset,
        "stderr": process.stderr.decode("utf-8").strip(),
    })
    return cases


def process_memory(process):
    if os.name == "nt":
        from ctypes import wintypes

        class Counters(ctypes.Structure):
            _fields_ = [
                ("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                *[(name, ctypes.c_size_t) for name in (
                    "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
                    "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage",
                    "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage")],
            ]

        counters = Counters()
        counters.cb = ctypes.sizeof(counters)
        query = ctypes.windll.psapi.GetProcessMemoryInfo
        query.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
        query.restype = wintypes.BOOL
        if query(wintypes.HANDLE(int(process._handle)), ctypes.byref(counters), counters.cb):
            return counters.WorkingSetSize, counters.PeakWorkingSetSize
    elif sys.platform.startswith("linux"):
        try:
            values = {}
            for line in Path(f"/proc/{process.pid}/status").read_text().splitlines():
                if line.startswith(("VmRSS:", "VmHWM:")):
                    name, amount, _ = line.split()
                    values[name] = int(amount) * 1024
            return values["VmRSS:"], values["VmHWM:"]
        except (FileNotFoundError, KeyError, ProcessLookupError):
            pass
    return None


def launch(binary):
    return subprocess.Popen(
        [str(binary), "--stream"], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=65536,
    )


def frame_builder(targets):
    observations = frame(0, targets).split(b',"observations":', 1)[1]

    def build(index):
        return b'{"timestamp_us":"' + str(index * 100000).encode("ascii") + b'","observations":' + observations + b"\n"

    return build


def throughput_check(binary, frames, targets):
    process = launch(binary)
    build = frame_builder(targets)
    errors = []
    progress = {"written": 0, "read": 0}
    memory = {"samples": 0, "peak_working_set_bytes": 0,
              "sampled_peak_rss_bytes": 0, "first_rss_bytes": None,
              "last_rss_bytes": None, "late_min_rss_bytes": None,
              "late_max_rss_bytes": None}
    done = threading.Event()

    def writer():
        try:
            process.stdin.write(configuration(targets=targets) + b"\n")
            for index in range(frames):
                process.stdin.write(build(index))
                progress["written"] += 1
            process.stdin.close()
        except (OSError, BrokenPipeError) as error:
            errors.append(str(error))

    def monitor():
        while not done.is_set():
            measurement = process_memory(process)
            if measurement:
                current, peak = measurement
                memory["samples"] += 1
                memory["peak_working_set_bytes"] = max(memory["peak_working_set_bytes"], peak)
                memory["sampled_peak_rss_bytes"] = max(memory["sampled_peak_rss_bytes"], current)
                memory["first_rss_bytes"] = memory["first_rss_bytes"] or current
                memory["last_rss_bytes"] = current
                if progress["read"] >= frames // 2:
                    old_min = memory["late_min_rss_bytes"]
                    memory["late_min_rss_bytes"] = min(old_min, current) if old_min is not None else current
                    old_max = memory["late_max_rss_bytes"]
                    memory["late_max_rss_bytes"] = max(old_max, current) if old_max is not None else current
            done.wait(0.05)

    start = time.perf_counter()
    producer = threading.Thread(target=writer, daemon=True)
    sampler = threading.Thread(target=monitor, daemon=True)
    producer.start()
    sampler.start()
    digest = hashlib.sha256()
    output_bytes = 0
    first = None
    last = None
    try:
        for line in process.stdout:
            if not line.endswith(b"\n"):
                raise AssertionError("benchmark produced a partial output line")
            digest.update(line)
            output_bytes += len(line)
            progress["read"] += 1
            if first is None:
                first = json.loads(line)
            last = line
        code = process.wait(timeout=30)
    finally:
        done.set()
        producer.join(timeout=5)
        sampler.join(timeout=5)
        if process.poll() is None:
            process.kill()
            process.wait()
    elapsed = time.perf_counter() - start
    stderr = process.stderr.read().decode("utf-8", errors="replace")
    if code != 0 or errors or stderr or progress["read"] != frames:
        raise AssertionError(f"long stream failed: exit={code}, frames={progress}, errors={errors}, stderr={stderr!r}")
    last = json.loads(last)
    if len(first["tracks"]) != targets or len(last["tracks"]) != targets:
        raise AssertionError("benchmark target count changed")
    if any(track["accepted_count"] != frames or track["status"] != "ready" for track in last["tracks"]):
        raise AssertionError("benchmark target did not retain its accepted segment")
    return {
        "frames": frames, "targets_per_frame": targets,
        "target_observations": frames * targets,
        "wall_seconds": elapsed, "frames_per_second": frames / elapsed,
        "target_observations_per_second": frames * targets / elapsed,
        "average_frame_ms": elapsed * 1000.0 / frames,
        "stdout_bytes_hashed": output_bytes, "stdout_sha256": digest.hexdigest(),
        "output_storage": "No accumulated stdout; first and final frames only.",
        "measurement_scope": "Native subprocess + Python producer, pipes, line counting and SHA-256; not isolated kernel time.",
        "memory": memory,
    }


def percentile(values, fraction):
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    left = math.floor(position)
    right = math.ceil(position)
    return ordered[left] + (ordered[right] - ordered[left]) * (position - left)


def latency_check(binary, samples, targets):
    process = launch(binary)
    process.stdin.write(configuration(targets=targets) + b"\n")
    process.stdin.flush()
    build = frame_builder(targets)
    times = []
    digest = hashlib.sha256()
    warmup = 100
    for index in range(samples + warmup):
        data = build(index)
        start = time.perf_counter_ns()
        process.stdin.write(data)
        process.stdin.flush()
        line = process.stdout.readline()
        elapsed = (time.perf_counter_ns() - start) / 1000000.0
        if not line.endswith(b"\n"):
            raise AssertionError("latency process closed or emitted an incomplete line")
        digest.update(line)
        if index >= warmup:
            times.append(elapsed)
    process.stdin.close()
    trailing = process.stdout.read()
    code = process.wait(timeout=20)
    stderr = process.stderr.read().decode("utf-8", errors="replace")
    if code != 0 or stderr or trailing:
        raise AssertionError(f"latency process failed: {code}, {stderr!r}")
    return {
        "samples": samples, "warmup_frames": warmup,
        "targets_per_frame": targets, "average_ms": sum(times) / len(times),
        "p50_ms": percentile(times, 0.50), "p95_ms": percentile(times, 0.95),
        "min_ms": min(times), "max_ms": max(times),
        "stdout_sha256": digest.hexdigest(),
        "measurement_scope": "One flushed frame write and one complete output line read, including subprocess pipes and scheduling.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
    parser.add_argument("--frames", type=int, default=100000)
    parser.add_argument("--targets", type=int, default=10)
    parser.add_argument("--latency-samples", type=int, default=500)
    parser.add_argument("--protocol-only", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/stream-results.json")
    args = parser.parse_args()
    if args.frames < 3 or not 1 <= args.targets <= 1000 or args.latency_samples < 1:
        parser.error("frames>=3, targets in [1,1000], and latency-samples>=1 are required")
    binary = args.binary.resolve()
    results = {
        "command": subprocess.list2cmdline([sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]]),
        "python": platform.python_version(), "platform": platform.platform(),
        "binary": str(binary), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "protocol": protocol_checks(binary),
    }
    print(f"protocol: {len(results['protocol'])}/{len(results['protocol'])} passed", flush=True)
    if not args.protocol_only:
        results["throughput"] = throughput_check(binary, args.frames, args.targets)
        print("throughput: " + json.dumps(results["throughput"], ensure_ascii=False), flush=True)
        results["latency"] = latency_check(binary, args.latency_samples, args.targets)
        print("latency: " + json.dumps(results["latency"], ensure_ascii=False), flush=True)
    args.output.write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"saved {args.output}", flush=True)


if __name__ == "__main__":
    main()
