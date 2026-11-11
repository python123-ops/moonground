import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  moonground_calibrate,
  moonground_create,
  moonground_update,
  moonground_checkpoint,
  moonground_restore,
  moonground_close,
} from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const directory = path.join(
  root,
  "_build",
  "native",
  "release",
  "build",
  "cmd",
  "main",
);
const binary = process.env.MOONGROUND_CLI
  ? path.resolve(root, process.env.MOONGROUND_CLI)
  : ["main.exe", "main"]
      .map((name) => path.join(directory, name))
      .find(existsSync);
assert.ok(
  binary,
  "Build the native release command before robust-fit verification.",
);
const clone = (value) => JSON.parse(JSON.stringify(value));
const fixture = () =>
  JSON.parse(
    readFileSync(path.join(root, "examples/robust-calibration.json"), "utf8"),
  );
const unpack = (source) => {
  const item = JSON.parse(source);
  assert.equal(item.error, undefined, source);
  return item;
};
const rejected = (source) =>
  assert.equal(typeof JSON.parse(source).error, "string", source);

function closeNumeric(actual, expected, location = "$") {
  if (typeof expected === "number") {
    assert.equal(typeof actual, "number", location);
    assert.ok(Number.isFinite(actual), location);
    if (
      /\.(control_count|inlier_count|fit_count|check_count|trials_run|valid_hypotheses|refinement_steps|max_trials|seed|track_id|accepted_count)$/.test(
        location,
      )
    ) {
      assert.equal(actual, expected, location);
    } else {
      assert.ok(
        Math.abs(actual - expected) <= 2e-8 * Math.max(1, Math.abs(expected)),
        `${location}: ${actual} != ${expected}`,
      );
    }
  } else if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual), location);
    assert.equal(actual.length, expected.length, location);
    expected.forEach((item, index) =>
      closeNumeric(actual[index], item, `${location}[${index}]`),
    );
  } else if (expected && typeof expected === "object") {
    assert.deepEqual(
      Object.keys(actual).sort(),
      Object.keys(expected).sort(),
      location,
    );
    for (const key of Object.keys(expected))
      closeNumeric(actual[key], expected[key], `${location}.${key}`);
  } else assert.equal(actual, expected, location);
}

function native(mode, records, status = 0) {
  const input =
    records
      .map((value) =>
        typeof value === "string" ? value : JSON.stringify(value),
      )
      .join("\n") + "\n";
  const process = spawnSync(binary, [mode], {
    input,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  assert.equal(
    process.status,
    status,
    process.stderr || process.error?.message,
  );
  if (status) {
    assert.equal(
      process.stdout,
      "",
      "failed stateless request produced output",
    );
    return [];
  }
  assert.equal(process.stderr, "");
  if (process.stdout) assert.ok(process.stdout.endsWith("\n"));
  return process.stdout.trim()
    ? process.stdout.trim().split("\n").map(JSON.parse)
    : [];
}

test("robust calibration and all effective diagnostics agree in native and JavaScript", () => {
  const request = fixture();
  for (const options of [request.robust, {}]) {
    const input = { ...request, robust: options };
    const actual = unpack(moonground_calibrate(JSON.stringify(input)));
    closeNumeric(actual, native("--calibrate", [input])[0]);
    assert.deepEqual(actual.robust_report.outlier_indices, [1, 7]);
    assert.deepEqual(actual.robust_report.inlier_mask, [
      true,
      false,
      true,
      true,
      true,
      true,
      true,
      false,
      true,
      true,
    ]);
    assert.equal(actual.robust_report.control_count, 10);
    assert.equal(actual.robust_report.inlier_count, 8);
    assert.equal(actual.report.fit_count, 8);
    assert.equal(actual.report.check_count, 3);
    assert.deepEqual(actual.camera, request.camera);
    assert.deepEqual(actual.calibration.roi, request.roi);
    assert.ok(actual.robust_report.valid_hypotheses > 0);
    assert.ok(
      actual.robust_report.trials_run <=
        actual.robust_report.options.max_trials,
    );
  }
  const strict = clone(request);
  delete strict.robust;
  rejected(moonground_calibrate(JSON.stringify(strict)));
  native("--calibrate", [strict], 2);
});

test("held-out labels cannot select or repair a robust control consensus", () => {
  const request = fixture();
  const expected = unpack(moonground_calibrate(JSON.stringify(request)));
  const alternate = clone(request);
  alternate.check_world = alternate.check_world.map(([x, y]) => [
    x + 0.005,
    y - 0.004,
  ]);
  const actual = unpack(moonground_calibrate(JSON.stringify(alternate)));
  assert.deepEqual(actual.calibration, expected.calibration);
  assert.deepEqual(actual.robust_report, expected.robust_report);
  closeNumeric(actual, native("--calibrate", [alternate])[0]);
  const bad = clone(request);
  bad.check_world[0][0] += 0.5;
  rejected(moonground_calibrate(JSON.stringify(bad)));
  native("--calibrate", [bad], 2);
});

test("robust options and raw numeric tokens retain strict JSON validation", () => {
  const request = fixture();
  const inputs = [];
  for (const [field, value] of [
    ["inlier_threshold_m", 0],
    ["min_inlier_ratio", 0],
    ["min_inlier_ratio", 1.1],
    ["max_trials", 4097],
    ["seed", 0],
    ["seed", 2147483648],
    ["typo", true],
  ]) {
    const item = clone(request);
    item.robust[field] = value;
    inputs.push(JSON.stringify(item));
  }
  const raw = JSON.stringify(request);
  inputs.push(
    raw.replace('"max_trials":512', '"max_trials":512.0000000000000000001'),
  );
  inputs.push(raw.replace('"seed":17', '"seed":17.0000000000000000001'));
  inputs.push(raw.replace('"seed":17', '"seed":17,"seed":18'));
  const reused = clone(request);
  reused.check_pixels[0] = reused.control_pixels[1];
  inputs.push(JSON.stringify(reused));
  const impossible = clone(request);
  impossible.robust = {
    ...request.robust,
    min_inlier_ratio: 1,
    max_trials: 1,
    inlier_threshold_m: 1e-5,
  };
  inputs.push(JSON.stringify(impossible));
  for (const source of inputs) {
    rejected(moonground_calibrate(source));
    native("--calibrate", [source], 2);
  }
});

test("a robust raw-camera calibration creates a measurement stream that resumes without fit metadata", () => {
  const request = fixture();
  const fitted = unpack(moonground_calibrate(JSON.stringify(request)));
  const configuration = {
    session_id: "robust-fit-session",
    diagnostics: true,
    calibration: fitted.calibration,
    camera: fitted.camera,
    motion: { max_velocity_std_mps: 0.5 },
  };
  const [x, y] = request.check_pixels[0];
  const frames = Array.from({ length: 8 }, (_, index) => ({
    timestamp_us: String(index * 100000),
    observations: [
      {
        track_id: 7,
        point: [x + index * 0.5, y + index * 0.2],
        covariance: [4, 0.2, 9],
      },
    ],
  }));
  const baseline = native("--stream", [configuration, ...frames]);
  const initial = unpack(
    moonground_create(JSON.stringify(configuration)),
  ).handle;
  let restored;
  try {
    const prefix = frames
      .slice(0, 3)
      .map((frame) =>
        unpack(moonground_update(initial, JSON.stringify(frame))),
      );
    closeNumeric(prefix, baseline.slice(0, 3));
    const saved = unpack(moonground_checkpoint(initial));
    for (const field of [
      "robust_report",
      "report",
      "inlier_mask",
      "control_pixels",
      "control_world",
    ])
      assert.equal(Object.hasOwn(saved.configuration, field), false);
    assert.deepEqual(saved.configuration.calibration, fitted.calibration);
    assert.deepEqual(saved.configuration.camera, fitted.camera);
    restored = unpack(moonground_restore(JSON.stringify(saved))).handle;
    const suffix = frames
      .slice(3)
      .map((frame) =>
        unpack(moonground_update(restored, JSON.stringify(frame))),
      );
    closeNumeric(suffix, baseline.slice(3));
    closeNumeric(
      native("--stream", [{ resume: saved }, ...frames.slice(3)]),
      baseline.slice(3),
    );
    const final = unpack(moonground_checkpoint(restored));
    closeNumeric(final, native("--checkpoint", [configuration, ...frames])[0]);
    assert.equal(final.motion.tracks[0].accepted_count, 8);
    assert.equal(final.motion.next_segment_id, "2");
    assert.ok(suffix.some((frame) => frame.tracks[0].status === "ready"));
  } finally {
    moonground_close(initial);
    if (restored !== undefined) moonground_close(restored);
  }
});
