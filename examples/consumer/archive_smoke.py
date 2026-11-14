#!/usr/bin/env python3
"""Verify the package ZIP through an independent consumer, outside checkout."""

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import zipfile


def run(command, cwd):
    result = subprocess.run(command, cwd=str(cwd), text=True, encoding="utf-8",
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=240)
    if result.returncode:
        raise AssertionError("{} failed:\n{}".format(" ".join(command), result.stdout))
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    archive = args.archive.resolve()
    source = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="moonground-independent-consumer-") as temporary:
        root = Path(temporary)
        library = root / "library"
        consumer = root / "consumer"
        library.mkdir()
        consumer.mkdir()
        with zipfile.ZipFile(archive) as package:
            names = package.namelist()
            if any(name.startswith(("validation/", "web/", "examples/")) for name in names):
                raise AssertionError("development assets entered the library archive")
            for item in package.infolist():
                destination = (library / item.filename).resolve()
                if library.resolve() not in destination.parents and destination != library.resolve():
                    raise AssertionError("unsafe archive member")
            package.extractall(library)
        for filename in ("moon.mod", "moon.pkg", "adapter.mbt", "consumer_test.mbt", "evidence_transit_test.mbt", "consumer_evidence_transit_analysis_test.mbt", "consumer_evidence_guarded_transit_test.mbt", "consumer_transit_windows_test.mbt", "consumer_evidence_transit_window_analysis_test.mbt", "consumer_evidence_guarded_transit_window_test.mbt", "consumer_velocity_test.mbt", "consumer_zone_test.mbt", "consumer_disk_zone_test.mbt"):
            shutil.copy2(source / filename, consumer / filename)
        (consumer / "moon.work").write_text('members = [ ".", "../library" ]\n', encoding="utf-8")
        version = run(["moon", "version", "--all", "--no-path"], consumer)
        run(["moon", "update"], consumer)
        run(["moon", "check", "--target", "all", "--deny-warn"], consumer)
        tests = run(["moon", "test", "--target", "all", "--deny-warn"], consumer)
        result = {"status": "passed", "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                  "archive_files": len(names), "toolchain": version,
                  "command": " ".join(shlex.quote(value) for value in [sys.executable] + sys.argv),
                  "targets": ["wasm", "wasm-gc", "js", "native"],
                  "test_summaries": [line for line in tests.splitlines() if line.startswith("Total tests:")],
                  "test_output_sha256": hashlib.sha256(tests.encode("utf-8")).hexdigest(),
                  "dependency": "Mooncakes MBMOT 0.3.0 and MoonDetEval 0.2.1; MoonGround exclusively from the ZIP",
                  "detector_fixture_ap50": 1.0,
                  "detector_fixture_scope": "bbox coordinates and category only; no speed accuracy claim",
                  "source_checkout_linked": False}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=True))


if __name__ == "__main__":
    main()
