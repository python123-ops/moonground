import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_create,
  moonground_update,
  moonground_close,
  moonground_project,
  moonground_calibrate,
} from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binaryDirectory = path.join(
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
      .map((name) => path.join(binaryDirectory, name))
      .find(existsSync);
assert.ok(
  binary,
  "Build the native release command before running parity tests.",
);
const fixture = readFileSync(
  path.join(root, "examples", "warehouse.ndjson"),
  "utf8",
);
const unpack = (text) => {
  const value = JSON.parse(text);
  assert.equal(value.error, undefined, text);
  return value;
};
function closeNumeric(actual, expected) {
  if (typeof expected === "number") {
    assert.ok(
      Math.abs(actual - expected) <= 1e-9 * Math.max(1, Math.abs(expected)),
      `${actual} != ${expected}`,
    );
  } else if (Array.isArray(expected)) {
    assert.equal(actual.length, expected.length);
    expected.forEach((value, i) => closeNumeric(actual[i], value));
  } else if (expected && typeof expected === "object") {
    assert.deepEqual(Object.keys(actual).sort(), Object.keys(expected).sort());
    for (const key of Object.keys(expected))
      closeNumeric(actual[key], expected[key]);
  } else assert.equal(actual, expected);
}

test("native and JavaScript replay the same fixed-camera stream", () => {
  const native = spawnSync(binary, ["--stream"], {
    input: fixture,
    encoding: "utf8",
  });
  assert.equal(native.status, 0, native.stderr);
  const expected = native.stdout.trim().split("\n").map(JSON.parse);
  const [config, ...frames] = fixture.trim().split("\n");
  const { handle } = unpack(moonground_create(config));
  try {
    const actual = frames.map((frame) =>
      unpack(moonground_update(handle, frame)),
    );
    closeNumeric(actual, expected);
    assert.equal(actual[0].tracks[0].speed_mps, null);
    assert.equal(actual[2].tracks[0].status, "ready");
    assert.notEqual(
      actual[6].tracks[0].segment_id,
      actual[0].tracks[0].segment_id,
    );
  } finally {
    assert.equal(moonground_close(handle), true);
  }
});

test("failed browser frame preserves state and exact Int64 time", () => {
  const { handle } = unpack(
    moonground_create(
      JSON.stringify({ session_id: "transaction", mode: "ground" }),
    ),
  );
  try {
    const input = {
      timestamp_us: "9223372036854000000",
      observations: [{ track_id: 1, point: [0, 0] }],
    };
    unpack(moonground_update(handle, JSON.stringify(input)));
    assert.ok(
      JSON.parse(moonground_update(handle, JSON.stringify(input))).error,
    );
    input.timestamp_us = "9223372036854200000";
    const frame = unpack(moonground_update(handle, JSON.stringify(input)));
    assert.equal(frame.timestamp_us, input.timestamp_us);
    assert.equal(frame.tracks[0].accepted_count, 2);
  } finally {
    moonground_close(handle);
  }
});

test("projection bridge uses native schema", () => {
  const request = JSON.stringify({
    calibration: {
      matrix: [0.02, 0, 0, 0, 0.02, 0, 0, 0, 1],
      roi: [
        [0, 0],
        [100, 0],
        [100, 100],
        [0, 100],
      ],
    },
    points: [{ point: [20, 30] }],
  });
  const native = spawnSync(binary, ["--project"], {
    input: request,
    encoding: "utf8",
  });
  assert.equal(native.status, 0, native.stderr);
  closeNumeric(unpack(moonground_project(request)), JSON.parse(native.stdout));
});

test("closed handles stay invalid when later sessions are allocated", () => {
  const first = unpack(
    moonground_create('{"session_id":"first","mode":"ground"}'),
  ).handle;
  assert.equal(moonground_close(first), true);
  const second = unpack(
    moonground_create('{"session_id":"second","mode":"ground"}'),
  ).handle;
  try {
    assert.notEqual(first, second);
    assert.ok(JSON.parse(moonground_update(first, "{}")).error);
    assert.equal(moonground_close(first), false);
  } finally {
    moonground_close(second);
  }
});

test("manual fitting has the same held-out report in native and JavaScript", () => {
  const request = readFileSync(
    path.join(root, "examples", "calibration.json"),
    "utf8",
  );
  const native = spawnSync(binary, ["--calibrate"], {
    input: request,
    encoding: "utf8",
  });
  assert.equal(native.status, 0, native.stderr);
  const result = unpack(moonground_calibrate(request));
  closeNumeric(result, JSON.parse(native.stdout));
  assert.equal(result.report.fit_count, 6);
  assert.equal(result.report.check_count, 2);
  assert.ok(result.report.check_max_error_m < 1e-10);
});

test("browser session capacity is bounded and released", () => {
  const handles = [];
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(
            JSON.stringify({ session_id: `capacity-${i}`, mode: "ground" }),
          ),
        ).handle,
      );
    assert.ok(
      JSON.parse(moonground_create('{"session_id":"over","mode":"ground"}'))
        .error,
    );
  } finally {
    handles.forEach(moonground_close);
  }
});

test("raw camera measurements and uncertainty gates agree across runtimes", () => {
  const input = readFileSync(
    path.join(root, "examples", "distorted-camera.ndjson"),
    "utf8",
  );
  const native = spawnSync(binary, ["--stream"], { input, encoding: "utf8" });
  assert.equal(native.status, 0, native.stderr);
  const expected = native.stdout.trim().split("\n").map(JSON.parse);
  const [config, ...frames] = input.trim().split("\n");
  const { handle } = unpack(moonground_create(config));
  try {
    const actual = frames.map((frame) =>
      unpack(moonground_update(handle, frame)),
    );
    closeNumeric(actual, expected);
    assert.ok(actual.some((frame) => frame.tracks[0].status === "uncertain"));
    assert.equal(actual.at(-1).tracks[0].status, "ready");
    const uncertain = actual.find(
      (frame) => frame.tracks[0].status === "uncertain",
    ).tracks[0];
    assert.equal(uncertain.speed_mps, null);
    assert.equal(uncertain.velocity_mps.length, 2);
    assert.ok(uncertain.velocity_std_mps > 0.2);
    assert.ok(Math.abs(actual[0].tracks[0].position_m[0] - 3.6) < 1e-9);
  } finally {
    moonground_close(handle);
  }
});

test("camera fit returns its camera and reusable corrected-space ROI", () => {
  const input = readFileSync(
    path.join(root, "examples", "distorted-calibration.json"),
    "utf8",
  );
  const native = spawnSync(binary, ["--calibrate"], {
    input,
    encoding: "utf8",
  });
  assert.equal(native.status, 0, native.stderr);
  const fitted = unpack(moonground_calibrate(input));
  closeNumeric(fitted, JSON.parse(native.stdout));
  assert.deepEqual(fitted.camera, JSON.parse(input).camera);
  assert.deepEqual(fitted.calibration.roi, JSON.parse(input).roi);
  assert.ok(fitted.report.check_max_error_m < 1e-8);
  const config = {
    session_id: "fit-raw",
    calibration: fitted.calibration,
    camera: fitted.camera,
  };
  const { handle } = unpack(moonground_create(JSON.stringify(config)));
  try {
    const request = {
      timestamp_us: "0",
      observations: [{ track_id: 1, point: JSON.parse(input).check_pixels[0] }],
    };
    const output = unpack(moonground_update(handle, JSON.stringify(request)));
    closeNumeric(output.tracks[0].position_m, JSON.parse(input).check_world[0]);
  } finally {
    moonground_close(handle);
  }
});
