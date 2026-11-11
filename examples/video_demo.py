"""Run real HOG detections through MBMOT and MoonGround native executables.

This offline demonstration does not implement tracking or measurement in Python.
It saves each process boundary and optionally renders the actual output. Its
detector is imported from the existing MBMOT checkout (--mbmot-repo); the native
tracker is built separately from the published MBMOT 0.3.0 module.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib
import io
import json
import math
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
import zipfile
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from fractions import Fraction
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, List, Optional, Sequence


ROOT = Path(__file__).resolve().parents[1]


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def write_ndjson(path: Path, rows: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        for row in rows:
            stream.write(json.dumps(row, separators=(",", ":"), allow_nan=False) + "\n")


def write_png(path: Path, frame: Any, cv2: Any) -> None:
    # imwrite on Windows may reject a Unicode absolute path without raising.
    success, encoded = cv2.imencode(".png", frame)
    if not success:
        raise RuntimeError("OpenCV could not encode a PNG preview")
    path.write_bytes(encoded.tobytes())


def run_native(command: Sequence[str], source: Path, destination: Path, timeout: int = 600) -> dict:
    started = time.perf_counter()
    with source.open("rb") as stdin, destination.open("wb") as stdout:
        completed = subprocess.run(command, stdin=stdin, stdout=stdout, stderr=subprocess.PIPE, timeout=timeout)
    stderr = completed.stderr.decode("utf-8", errors="replace")
    if completed.returncode:
        raise RuntimeError("native process failed: " + " ".join(command) + "\n" + stderr)
    return {"command": list(command), "exit_code": completed.returncode,
            "seconds": time.perf_counter() - started, "stderr": stderr.strip()}


def read_ndjson(path: Path) -> List[dict]:
    with path.open(encoding="utf-8") as source:
        return [json.loads(line) for line in source if line.strip()]


def published_mbmot() -> Path:
    """Build a disposable copy of the known registry release, never a sibling checkout."""
    destination = ROOT / "_build/mbmot-0.3.0"
    if (destination / "moon.mod").is_file():
        return destination
    installed = ROOT / "examples/consumer/.mooncakes/python123-ops/mbmot"
    if (installed / "moon.mod").is_file():
        metadata = (installed / "moon.mod").read_text(encoding="utf-8")
        if 'version = "0.3.0"' not in metadata:
            raise RuntimeError("consumer cache is not MBMOT 0.3.0")
        shutil.copytree(str(installed), str(destination),
                        ignore=shutil.ignore_patterns("_build", ".mooncakes", ".git"), dirs_exist_ok=True)
    else:
        url = "https://download.mooncakes.io/user/python123-ops/mbmot/0.3.0.zip"
        with urllib.request.urlopen(url, timeout=90) as response:
            archive = response.read()
        destination.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(io.BytesIO(archive)) as source:
            for item in source.infolist():
                relative = PurePosixPath(item.filename)
                if relative.is_absolute() or ".." in relative.parts or "\\" in item.filename:
                    raise RuntimeError("invalid registry archive path")
                if item.is_dir():
                    continue
                output = destination.joinpath(*relative.parts)
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(source.read(item))
    return destination


def source_tree_hash(repository: Path) -> str:
    value = hashlib.sha256()
    for path in sorted(repository.rglob("*")):
        relative = path.relative_to(repository)
        if path.is_file() and path.name != "moon.lock" and not any(part in {"_build", ".mooncakes", ".git"} for part in relative.parts):
            value.update(relative.as_posix().encode("utf-8") + b"\0")
            value.update(path.read_bytes())
    return value.hexdigest()


def native_binary(repository: Path, package: str, moon: str, supplied: Optional[Path], strict: bool = True) -> Path:
    if supplied is not None:
        binary = supplied.resolve()
    else:
        command = [moon, "build", package, "--target", "native", "--release"]
        if strict:
            command.append("--deny-warn")
        completed = subprocess.run(command,
                                   cwd=str(repository), capture_output=True, timeout=600)
        if completed.returncode:
            raise RuntimeError(completed.stderr.decode("utf-8", errors="replace"))
        relative = package[4:] if package.startswith("src/") else package
        binary = repository / "_build/native/release/build" / relative / (Path(package).name + ".exe")
        if not binary.exists() and os.name != "nt":
            binary = binary.with_suffix("")
    if not binary.is_file():
        raise RuntimeError("native executable not found: " + str(binary))
    return binary


def timestamp_us(index: int, fps: Fraction) -> int:
    # Round the rational frame-start timestamp, without rounding absolute floats.
    numerator = index * 1000000 * fps.denominator
    return (2 * numerator + fps.numerator) // (2 * fps.numerator)


def detect_video(args: argparse.Namespace, detector_class: Any, cv2: Any) -> tuple:
    capture = cv2.VideoCapture(str(args.source))
    if not capture.isOpened():
        raise RuntimeError("cannot open video: " + str(args.source))
    fps_value = float(capture.get(cv2.CAP_PROP_FPS))
    if not math.isfinite(fps_value) or fps_value <= 0:
        raise RuntimeError("video must contain a positive finite frame rate")
    fps = Fraction(str(fps_value)).limit_denominator(100000)
    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    target = int(math.floor(args.seconds * float(fps) + 1.0e-8))
    if target < 1:
        raise ValueError("requested interval contains no video frames")
    local = threading.local()

    def process(item: tuple) -> dict:
        index, frame = item
        if not hasattr(local, "detector"):
            local.detector = detector_class(args.confidence, args.nms_threshold)
        return {"frame": index + 1, "detections": local.detector.detect(frame)}

    started = time.perf_counter()
    rows: List[dict] = []
    first_frame = None
    # Bounded batches keep decoded video memory bounded and preserve frame order.
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        while len(rows) < target:
            batch = []
            for offset in range(min(args.workers * 2, target - len(rows))):
                ok, frame = capture.read()
                if not ok:
                    break
                if first_frame is None:
                    first_frame = frame.copy()
                batch.append((len(rows) + offset, frame))
            if not batch:
                break
            rows.extend(executor.map(process, batch))
            if len(rows) % 100 < len(batch):
                print("detected %d/%d frames" % (len(rows), target), file=sys.stderr, flush=True)
    capture.release()
    if len(rows) != target:
        raise RuntimeError("video ended after %d frames; requested %d" % (len(rows), target))
    return rows, fps, {"width": width, "height": height, "fps": float(fps),
                      "fps_fraction": str(fps), "frames": len(rows),
                      "interval_seconds": len(rows) / float(fps),
                      "first_timestamp_us": "0", "last_timestamp_us": str(timestamp_us(len(rows) - 1, fps)),
                      "detection_seconds": time.perf_counter() - started}, first_frame


def render(args: argparse.Namespace, tracks: List[dict], ground: List[dict], roi: list,
           info: dict, cv2: Any) -> dict:
    started = time.perf_counter()
    capture = cv2.VideoCapture(str(args.source))
    path = args.output / "measurement.mp4"
    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), info["fps"],
                             (info["width"], info["height"]))
    if not writer.isOpened():
        raise RuntimeError("OpenCV could not create the MP4 output")
    for index, (tracked, measured) in enumerate(zip(tracks, ground)):
        ok, frame = capture.read()
        if not ok:
            raise RuntimeError("source video ended during rendering")
        for left, right in zip(roi, roi[1:] + roi[:1]):
            cv2.line(frame, tuple(round(v) for v in left), tuple(round(v) for v in right), (70, 220, 100), 2)
        estimates = {item["track_id"]: item for item in measured["tracks"]}
        for item in tracked["tracks"]:
            box = item["xyxy"]
            estimate = estimates.get(item["track_id"], {})
            ready = estimate.get("status") == "ready"
            colour = (80, 220, 100) if ready else (60, 190, 255)
            p1 = (round(box[0]), round(box[1]))
            p2 = (round(box[2]), round(box[3]))
            anchor = (round((box[0] + box[2]) / 2), round(box[3]))
            label = "ID %s %s" % (item["track_id"], estimate.get("status", ""))
            if ready:
                label += " %.2f m/s" % estimate["speed_mps"]
            cv2.rectangle(frame, p1, p2, colour, 1)
            cv2.circle(frame, anchor, 3, colour, -1)
            cv2.putText(frame, label, (p1[0], max(15, p1[1] - 5)), cv2.FONT_HERSHEY_SIMPLEX, 0.4, colour, 1, cv2.LINE_AA)
        cv2.rectangle(frame, (0, 0), (info["width"], 43), (20, 25, 30), -1)
        cv2.putText(frame, "MoonGround | actual HOG -> MBMOT -> ground measurement", (10, 18),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (240, 240, 240), 1, cv2.LINE_AA)
        cv2.putText(frame, "Frame %d | %s us | fixed-calibration demonstration" % (index + 1, measured["timestamp_us"]),
                    (10, 36), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (200, 210, 220), 1, cv2.LINE_AA)
        writer.write(frame)
        if index == min(250, len(tracks) - 1):
            write_png(args.output / "preview.png", frame, cv2)
    capture.release()
    writer.release()
    check = cv2.VideoCapture(str(path))
    actual_frames = int(check.get(cv2.CAP_PROP_FRAME_COUNT))
    readable, _ = check.read()
    check.release()
    if not readable or actual_frames != len(tracks):
        raise RuntimeError("rendered MP4 did not reopen with the expected frame count")
    preview = args.output / "preview.png"
    return {"path": str(path), "sha256": digest(path), "bytes": path.stat().st_size,
            "frames": actual_frames, "first_frame_readable": readable, "audio": False,
            "preview": {"path": str(preview), "sha256": digest(preview)},
            "seconds": time.perf_counter() - started}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--homography", type=Path, required=True, help="3x3 text matrix mapping image (x,y) to ground metres")
    parser.add_argument("--homography-order", choices=("xy", "yx"), default="xy",
                        help="provided H input order; the original ETH hotel H uses yx (row,column)")
    parser.add_argument("--roi", required=True, help="JSON convex polygon in original image pixels")
    parser.add_argument("--seconds", type=float, default=60.0)
    parser.add_argument("--confidence", type=float, default=0.55)
    parser.add_argument("--nms-threshold", type=float, default=0.4)
    parser.add_argument("--pixel-std", type=float, default=2.0)
    parser.add_argument("--max-meters-per-pixel", type=float, default=0.5)
    parser.add_argument("--ground-noise-floor-m", type=float, default=0.001)
    parser.add_argument("--q", type=float, default=1.0)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--mbmot-repo", type=Path, default=ROOT.parent / "mbmot",
                        help="existing MBMOT checkout containing tools/video_demo/detector.py")
    parser.add_argument("--mbmot-binary", type=Path)
    parser.add_argument("--moonground-binary", type=Path)
    parser.add_argument("--moon", default=os.environ.get("MOON", "moon"))
    parser.add_argument("--output", type=Path, default=ROOT / "validation/data/video-hotel-60s")
    parser.add_argument("--report", type=Path, default=ROOT / "validation/video-results.json")
    parser.add_argument("--no-render", action="store_true")
    args = parser.parse_args()
    for name in ["seconds", "pixel_std", "max_meters_per_pixel", "ground_noise_floor_m", "q"]:
        if not math.isfinite(getattr(args, name)) or getattr(args, name) <= 0:
            raise ValueError(name + " must be finite and positive")
    if args.workers < 1 or args.workers > 32:
        raise ValueError("workers must be in [1,32]")
    if not 0 <= args.confidence <= 1 or not 0 <= args.nms_threshold <= 1:
        raise ValueError("confidence and NMS threshold must be in [0,1]")
    args.source = args.source.resolve()
    args.homography = args.homography.resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    roi = json.loads(args.roi)
    raw_matrix = [float(value) for value in args.homography.read_text().split()]
    if len(raw_matrix) != 9 or not all(math.isfinite(value) for value in raw_matrix):
        raise ValueError("homography must contain exactly nine finite numbers")
    # The core API always receives detector x/y coordinates. ETH hotel's
    # original H is defined for image row/column, so compose this adapter once.
    matrix = ([raw_matrix[i] for i in [1, 0, 2, 4, 3, 5, 7, 6, 8]]
              if args.homography_order == "yx" else raw_matrix)
    detector_directory = args.mbmot_repo.resolve() / "tools/video_demo"
    if not (detector_directory / "detector.py").is_file():
        raise RuntimeError("MBMOT detector helper not found; pass --mbmot-repo with an existing checkout")
    sys.path.insert(0, str(detector_directory))
    detector_module = importlib.import_module("detector")
    cv2 = detector_module.load_opencv()
    cv2.setNumThreads(1)
    config = {"session_id": "eth-hotel-video-hog", "mode": "pixel",
              "calibration": {"matrix": matrix, "roi": roi,
                              "max_meters_per_pixel": args.max_meters_per_pixel,
                              "ground_noise_floor_m": args.ground_noise_floor_m},
              "motion": {"q": args.q}}
    ground_binary = native_binary(ROOT, "cmd/main", args.moon, args.moonground_binary)
    tracker_source = published_mbmot()
    tracker_binary = native_binary(tracker_source, "src/replay", args.moon, args.mbmot_binary, strict=False)
    # Validate the native calibration before spending time on video detection.
    probe = "\n".join(json.dumps(row, allow_nan=False) for row in
                      [config, {"timestamp_us": "0", "observations": []}]) + "\n"
    checked = subprocess.run([str(ground_binary), "--stream"], input=probe.encode("utf-8"), capture_output=True, timeout=60)
    if checked.returncode:
        raise RuntimeError("native calibration validation failed: " + checked.stderr.decode("utf-8", errors="replace"))
    detections, fps, info, first_frame = detect_video(args, detector_module.HogPersonDetector, cv2)
    if first_frame is not None:
        write_png(args.output / "source-first-frame.png", first_frame, cv2)
    detection_path = args.output / "detections.ndjson"
    tracks_path = args.output / "tracks.ndjson"
    input_path = args.output / "measurements-input.ndjson"
    ground_path = args.output / "ground.ndjson"
    write_ndjson(detection_path, detections)
    tracker_run = run_native([str(tracker_binary)], detection_path, tracks_path)
    tracks = read_ndjson(tracks_path)
    if len(tracks) != len(detections) or any(row["frame"] != index + 1 for index, row in enumerate(tracks)):
        raise RuntimeError("MBMOT did not return exactly one ordered result per video frame")
    variance = args.pixel_std * args.pixel_std
    measurement_rows = [config]
    for index, row in enumerate(tracks):
        observations = [{"track_id": item["track_id"],
                         "point": [(item["xyxy"][0] + item["xyxy"][2]) / 2.0, item["xyxy"][3]],
                         "covariance": [variance, 0.0, variance]}
                        for item in row["tracks"]]
        measurement_rows.append({"timestamp_us": str(timestamp_us(index, fps)), "observations": observations,
                                 "lost": row["lost"], "removed": row["removed"]})
    write_ndjson(input_path, measurement_rows)
    ground_run = run_native([str(ground_binary), "--stream"], input_path, ground_path)
    ground = read_ndjson(ground_path)
    if len(ground) != len(tracks) or any(row["timestamp_us"] != str(timestamp_us(index, fps)) for index, row in enumerate(ground)):
        raise RuntimeError("MoonGround timestamps or frame counts do not match the decoded video")
    status = Counter(item["status"] for row in ground for item in row["tracks"])
    ids = {item["track_id"] for row in tracks for item in row["tracks"]}
    ready_ids = {item["track_id"] for row in ground for item in row["tracks"] if item["status"] == "ready"}
    report = {"schema_version": "0.1.0", "completed": True,
              "source": {"path": str(args.source), "sha256": digest(args.source),
                         "homography_path": str(args.homography), "homography_sha256": digest(args.homography),
                         "provided_homography_input_order": args.homography_order,
                         "provided_homography": raw_matrix,
                         "dataset": "ETH Walking Pedestrians, seq_hotel",
                         "source_url": "https://data.vision.ee.ethz.ch/cvl/aem/ewap_dataset_full.tgz"},
              "video": info,
              "parameters": {"confidence": args.confidence, "nms_threshold": args.nms_threshold,
                             "pixel_std": args.pixel_std, "workers": args.workers, "configuration": config},
              "pipeline": {"detector": "unmodified MBMOT HogPersonDetector / OpenCV built-in full-body HOG",
                           "opencv": cv2.__version__, "python": sys.version.split()[0],
                           "driver_sha256": digest(Path(__file__)),
                           "detector_source_sha256": digest(Path(detector_module.__file__)),
                           "mbmot_module": "python123-ops/mbmot@0.3.0",
                           "mbmot_registry_url": "https://download.mooncakes.io/user/python123-ops/mbmot/0.3.0.zip",
                           "mbmot_source_tree_sha256": source_tree_hash(tracker_source),
                           "mbmot_binary_sha256": digest(tracker_binary),
                           "moonground_binary_sha256": digest(ground_binary),
                           "tracker_run": tracker_run, "measurement_run": ground_run},
              "counts": {"frames": len(ground), "detections": sum(len(row["detections"]) for row in detections),
                         "visible_track_observations": sum(len(row["tracks"]) for row in tracks),
                         "unique_track_ids": len(ids), "ready_track_ids": len(ready_ids), "measurement_status": dict(sorted(status.items())),
                         "closed_segments": sum(len(row["closed_segment_ids"]) for row in ground)},
              "artifacts": {path.name: {"path": str(path), "sha256": digest(path), "bytes": path.stat().st_size}
                            for path in [detection_path, tracks_path, input_path, ground_path]},
              "interpretation": {"verified": "actual video detection -> native identity tracking -> native pixel-to-metre measurement",
                                 "speed_accuracy_measured": False,
                                 "distortion": "original EWAP image/H coordinates; independent lens calibration was not measured",
                                 "anchor": "HOG bounding-box bottom centre, not annotated ground-truth contact points",
                                 "detector_observation": "the inspected overhead scene produces oversized multi-person HOG boxes as well as missed people; identity counts are pipeline outputs, not tracking-quality scores",
                                 "coordinates": "core H maps detector [x,y,1] to dataset [pos_x,pos_y,1]; original H input order is explicitly adapted before calling the core",
                                 "uncertainty": "conditional on fixed homography and selected anchor; pixel noise is an explicit demonstration parameter"},
              "reproduce": [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]]}
    if not args.no_render:
        report["rendered_video"] = render(args, tracks, ground, roi, info, cv2)
    report["total_seconds"] = (info["detection_seconds"] + tracker_run["seconds"] +
                               ground_run["seconds"] + report.get("rendered_video", {}).get("seconds", 0.0))
    report["timing_scope"] = "sum of measured detection, native tracking, native measurement and render stages; excludes builds and file hashing"
    write_json(args.report, report)
    print(json.dumps({"frames": len(ground), "counts": report["counts"], "report": str(args.report)}, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        print("video demo: " + str(error), file=sys.stderr)
        raise SystemExit(2)
