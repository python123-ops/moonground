import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { moonground_measurement_evaluation } from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.env.MOONGROUND_CLI
  ? path.resolve(root, process.env.MOONGROUND_CLI)
  : ["main.exe", "main"]
      .map((name) =>
        path.join(root, "_build/native/release/build/cmd/main", name),
      )
      .find(existsSync);
assert.ok(
  binary,
  "Build the native command before evaluating measurement logs.",
);
const config = { session_id: "evaluation" };
const raw = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
const clone = (value) => JSON.parse(JSON.stringify(value));

function measurement(time, tracks = []) {
  return {
    schema_version: "0.2.0",
    session_id: "evaluation",
    timestamp_us: String(time),
    tracks,
    closed_segment_ids: [],
    uncertainty_scope: "conditional_on_fixed_calibration_camera_and_anchor",
  };
}
function track(id, time, status = "ready", point = [3, 4], speed = 2) {
  const accepted = ["ready", "initializing", "uncertain"].includes(status);
  const observable = ["ready", "uncertain"].includes(status);
  const value = {
    track_id: id,
    segment_id: String(id),
    status,
    position_m: accepted ? point : null,
    position_covariance: accepted ? [0.01, 0, 0.01] : null,
    position_std_m: accepted ? 0.1 : null,
    velocity_mps: observable ? [speed, 0] : null,
    velocity_covariance: observable ? [0.01, 0, 0.01] : null,
    velocity_std_mps: observable ? 0.1 : null,
    speed_mps: status === "ready" ? speed : null,
  };
  if (status === "rejected_projection")
    return { ...value, segment_id: null, reason: "outside ROI" };
  return {
    ...value,
    observed_path_length_m: 0,
    net_displacement_m: 0,
    accepted_count: 1,
    last_accepted_timestamp_us: String(time),
  };
}
function line(time, tracks = [], samples = []) {
  return {
    measurement: measurement(time, tracks),
    reference: { timestamp_us: String(time), samples },
  };
}
function native(source, frames, ending = "\n", extra = [], status = 0) {
  const input = [raw(source), ...frames.map(raw)].join(ending) + ending;
  const result = spawnSync(binary, ["--evaluate-measurements", ...extra], {
    input,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
    timeout: 30000,
  });
  assert.equal(result.status, status, result.stderr || result.error?.message);
  if (status) {
    assert.equal(result.stdout, "");
    return result;
  }
  assert.equal(result.stderr, "");
  assert.equal(result.stdout.trim().split("\n").length, 1);
  return JSON.parse(result.stdout);
}
function web(source, frames) {
  return JSON.parse(
    moonground_measurement_evaluation(
      JSON.stringify({
        source: raw(source),
        frames: frames.map(raw).join("\n"),
      }),
    ),
  );
}
function equal(source, frames) {
  const value = web(source, frames);
  assert.equal(value.error, undefined);
  assert.deepEqual(value, native(source, frames));
  return value;
}
function rejected(source, frames) {
  assert.equal(typeof web(source, frames).error, "string");
  native(source, frames, "\n", [], 2);
}

test("measurement evaluation preserves every reference status and both coverage denominators", () => {
  const statuses = [
    "initializing",
    "ready",
    "uncertain",
    "rejected_innovation",
    "numerical_failure",
    "rejected_projection",
  ];
  const samples = Array.from({ length: 7 }, (_, i) => ({
    track_id: i + 1,
    position_m: [0, 0],
    speed_mps: 0,
  }));
  const result = equal(config, [
    line(
      0,
      [...statuses.map((s, i) => track(i + 1, 0, s)), track(8, 0)],
      samples,
    ),
  ]);
  assert.equal(result.counts.references, 7);
  assert.equal(result.counts.without_reference, 1);
  for (const key of [...statuses, "missing"])
    assert.equal(result.counts[key], 1);
  assert.equal(result.position_error_m.samples, 3);
  assert.equal(result.position_error_m.root_mean_square_error, 5);
  assert.equal(result.speed_error_mps.samples, 1);
  assert.equal(result.position_coverage, 3 / 7);
  assert.equal(result.speed_coverage, 1 / 7);
});

test("exact large clocks optional speed truth and empty populations agree across runtimes", () => {
  const empty = equal(config, []);
  assert.equal(empty.position_error_m.maximum_absolute_error, null);
  assert.equal(empty.speed_coverage, null);
  const t = 9007199254740993n;
  const rows = [
    line(t, [track(1, t)], [{ track_id: 1, position_m: [0, 0] }]),
    line(t + 1n),
  ];
  const value = equal(config, rows);
  assert.equal(value.last_timestamp_us, String(t + 1n));
  assert.equal(value.speed_error_mps.samples, 0);
  assert.equal(value.speed_error_mps.mean_absolute_error, null);
  rejected(config, [rows[0], rows[0]]);
  const bad = clone(rows[0]);
  bad.reference.timestamp_us = String(t + 1n);
  rejected(config, [bad]);
});

test("raw duplicate unknown underflow and malformed late records fail without a summary prefix", () => {
  const good = line(
    0,
    [track(1, 0)],
    [{ track_id: 1, position_m: [0, 0], speed_mps: 0 }],
  );
  const next = line(
    1,
    [track(1, 1)],
    [{ track_id: 1, position_m: [0, 0], speed_mps: 0 }],
  );
  const base = JSON.stringify(next);
  const malformed = [
    base.replace('"speed_mps":0', '"speed_mps":1e-999'),
    base.replace('"speed_mps":0', '"speed_mps":1e999'),
    base.replace('"speed_mps":0', '"speed_mps":-1'),
    base.replace('"speed_mps":0', '"speed_mps":null'),
    base.replace('"speed_mps":0', '"speed_mps":0,"speed_mps":0'),
    base.replace('"track_id":1', '"track_id":1.00000000000000001'),
  ];
  for (const value of malformed) rejected(config, [good, value]);
  for (const mutate of [
    (x) => {
      x.reference.samples.push(x.reference.samples[0]);
    },
    (x) => {
      x.measurement.tracks.push(x.measurement.tracks[0]);
    },
    (x) => {
      x.reference.unknown = 1;
    },
    (x) => {
      x.measurement.tracks[0].last_accepted_timestamp_us = "0";
    },
    (x) => {
      x.measurement.session_id = "other";
    },
    (x) => {
      x.measurement.schema_version = "1";
    },
    (x) => {
      x.reference.timestamp_us = "01";
    },
    (x) => {
      x.reference.timestamp_us = "9223372036854775808";
    },
  ]) {
    const value = clone(next);
    mutate(value);
    rejected(config, [good, value]);
  }
  rejected('{"session_id":"evaluation","session_id":"other"}', []);
  rejected({ ...config, max_samples: 1 }, [good, next]);
});

test("maximum configured frame and independent sample budgets are enforced", () => {
  const count = 1024;
  const tracks = Array.from({ length: count }, (_, i) => track(i + 1, 0));
  const refs = Array.from({ length: count }, (_, i) => ({
    track_id: i + 1,
    position_m: [0, 0],
  }));
  const result = equal({ ...config, max_tracks: count, max_samples: count }, [
    line(0, tracks, refs),
  ]);
  assert.equal(result.position_error_m.samples, count);
  rejected({ ...config, max_tracks: count - 1 }, [line(0, tracks, refs)]);
  rejected({ ...config, max_samples: count - 1 }, [line(0, tracks, refs)]);
});

test("pure batches cap at 5000 lines while native accumulation continues past that boundary", () => {
  const frames = Array.from({ length: 5000 }, (_, i) => line(i));
  assert.equal(equal(config, frames).counts.frames, "5000");
  frames.push(line(5000));
  assert.equal(typeof web(config, frames).error, "string");
  assert.equal(native(config, frames).counts.frames, "5001");
  for (const text of [
    " ".repeat(16777217),
    JSON.stringify({ source: raw(config), frames: " ".repeat(8388609) }),
  ]) {
    assert.equal(
      typeof JSON.parse(moonground_measurement_evaluation(text)).error,
      "string",
    );
  }
});

test("native LF CRLF EOF byte limits and invalid UTF8 preserve final-only output", () => {
  const row = line(0, [track(1, 0)], [{ track_id: 1, position_m: [0, 0] }]);
  const expected = native(config, [row]);
  assert.deepEqual(native(config, [row], "\r\n"), expected);
  const noLf = spawnSync(binary, ["--evaluate-measurements"], {
    input: raw(config) + "\n" + raw(row),
    encoding: "utf8",
    timeout: 30000,
  });
  assert.equal(noLf.status, 0, noLf.stderr);
  assert.deepEqual(JSON.parse(noLf.stdout), expected);
  native(config, [row], "\n", ["--max-line-bytes", "64"], 2);
  const invalid = spawnSync(binary, ["--evaluate-measurements"], {
    input: Buffer.concat([
      Buffer.from(raw(config) + "\n" + raw(row) + "\n"),
      Buffer.from([255]),
    ]),
    timeout: 30000,
  });
  assert.equal(invalid.status, 2);
  assert.equal(invalid.stdout.length, 0);
  native(config, [row, ""], "\n", [], 2);
});
