import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_guarded,
  moonground_analysis,
  moonground_health,
  moonground_create,
  moonground_close,
} from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.env.MOONGROUND_CLI
  ? path.resolve(root, process.env.MOONGROUND_CLI)
  : ["main.exe", "main"]
      .map((name) =>
        path.join(root, "_build/native/release/build/cmd/main", name),
      )
      .find(existsSync);
assert.ok(binary, "Build the native release CLI before guarded verification.");
const clone = (value) => JSON.parse(JSON.stringify(value));
const line = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
const ndjson = (records) =>
  records.map(line).join("\n") + (records.length ? "\n" : "");
const objects = (timestamp, observations = [], lost = [], removed = []) => ({
  timestamp_us: String(timestamp),
  observations,
  lost,
  removed,
});
const landmarks = (timestamp, observations = []) => ({
  timestamp_us: String(timestamp),
  observations,
});
const wrap = (measurement, health) => ({
  measurement: line(measurement),
  health: line(health),
});
const pair = (analysis, health) => ({
  analysis: line(analysis),
  health: line(health),
});
const combine = (analysis, health) => ({
  format: "moonground.guarded",
  checkpoint_version: "1",
  analysis,
  health,
});

function unpack(text) {
  const value = JSON.parse(text);
  assert.equal(value.error, undefined, text.slice(0, 1000));
  return value;
}

function failure(text) {
  const value = JSON.parse(text);
  assert.equal(typeof value.error, "string", text.slice(0, 1000));
  assert.deepEqual(
    Object.keys(value),
    ["error"],
    "failed pure batch exposed partial output",
  );
  return value.error;
}

function closeNumeric(actual, expected, location = "$") {
  if (typeof expected === "number") {
    assert.equal(typeof actual, "number", location);
    assert.ok(Number.isFinite(actual), location);
    if (
      /\.(track_id|accepted_count|usable_count|streak_observations|min_observations|max_tracks)$/.test(
        location,
      )
    )
      assert.equal(actual, expected, location);
    else
      assert.ok(
        Math.abs(actual - expected) <= 2e-8 * Math.max(1, Math.abs(expected)),
        `${location}: ${actual} != ${expected}`,
      );
  } else if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual), location);
    assert.equal(actual.length, expected.length, location);
    expected.forEach((value, index) =>
      closeNumeric(actual[index], value, `${location}[${index}]`),
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
  const run = spawnSync(binary, [mode], {
    input: ndjson(records),
    encoding: "utf8",
    maxBuffer: 48 * 1024 * 1024,
    timeout: 120000,
  });
  assert.equal(run.status, status, run.stderr || run.error?.message);
  if (!status) assert.equal(run.stderr, "");
  if (run.stdout) assert.ok(run.stdout.endsWith("\n"), "partial native line");
  if (status && mode === "--guarded-checkpoint") assert.equal(run.stdout, "");
  return run.stdout ? run.stdout.trimEnd().split("\n").map(JSON.parse) : [];
}

const invoke = (source, observations) =>
  moonground_guarded(JSON.stringify({ source: line(source), observations }));
const browser = (source, observations = []) =>
  unpack(
    invoke(
      source,
      typeof observations === "string" ? observations : ndjson(observations),
    ),
  );

function fixture(start = 9007199254740993n) {
  const calibration = {
    matrix: [0.125, 0, 0, 0, 0.125, 0, 0, 0, 1],
    roi: [
      [-100, -100],
      [100, -100],
      [100, 100],
      [-100, 100],
    ],
  };
  const measurement = {
    session_id: "guarded-parity",
    mode: "pixel",
    diagnostics: true,
    calibration: clone(calibration),
    motion: {
      max_tracks: 8,
      min_observations: 2,
      min_span_us: "100000",
      initial_velocity_std: 10,
      gate: 1e9,
      q: 5,
    },
  };
  const counting = {
    session_id: measurement.session_id,
    gates: [
      {
        gate_id: "middle",
        start_m: [-100, 2],
        end_m: [100, 2],
        deadband_m: 0.005,
      },
    ],
    max_tracks: 8,
  };
  const health = {
    monitor_id: "guarded-parity-landmarks",
    calibration: clone(calibration),
    landmarks: [
      [8, 8],
      [24, 8],
      [8, 24],
      [24, 24],
    ].map((p, i) => ({
      landmark_id: String.fromCharCode(65 + i),
      ground_m: p.map((v) => v * 0.125),
    })),
    health: {
      min_landmarks: 3,
      rms_limit_m: 0.1,
      max_error_m: 0.2,
      min_observations: 3,
      confirmation_us: "300000",
      max_gap_us: "500000",
    },
  };
  const header = pair(
    { measurement: line(measurement), counting: line(counting) },
    health,
  );
  const times = [
    0, 100000, 300000, 400000, 500000, 600000, 700000, 900000, 1000000, 1100000,
    1200000, 1400000, 1500000, 1600000, 2100000, 2200000, 2400000, 2500000,
  ];
  const frames = times.map((offset, i) => {
    const time = start + BigInt(offset);
    const fixed =
      i === 8
        ? []
        : health.landmarks.map((landmark) => ({
            landmark_id: landmark.landmark_id,
            point: [
              landmark.ground_m[0] * 8 + (i >= 5 && i <= 7 ? 4 : 0),
              landmark.ground_m[1] * 8,
            ],
            covariance: [0.04, 0.008, 0.09],
          }));
    let detections = [2, 1].map((track_id) => ({
      track_id,
      point: [8 + track_id - 1, i % 2 ? 24 : 8],
      covariance: [0.04, 0.008, 0.09],
    }));
    if (i === 4) detections = [];
    if (i === 0) detections[0].point = [3000, 3000];
    return wrap(objects(time, detections), landmarks(time, fixed));
  });
  return { header, frames, measurement, counting, health };
}

function oldComposition(header, frames) {
  let analysis = unpack(
    moonground_analysis(
      JSON.stringify({ source: header.analysis, observations: "" }),
    ),
  ).checkpoint;
  let health = unpack(
    moonground_health(
      JSON.stringify({ source: header.health, observations: "" }),
    ),
  ).checkpoint;
  const result = [];
  for (const frame of frames) {
    const measured = JSON.parse(frame.measurement);
    const healthCandidate = unpack(
      moonground_health(
        JSON.stringify({
          source: line({ resume: health }),
          observations: frame.health,
        }),
      ),
    );
    const report = healthCandidate.frames[0];
    const allowed = report.status === "healthy";
    const effective = allowed
      ? measured
      : objects(
          measured.timestamp_us,
          [],
          [],
          analysis.measurement.motion.tracks.map((value) => value.track_id),
        );
    const analysisCandidate = unpack(
      moonground_analysis(
        JSON.stringify({
          source: line({ resume: analysis }),
          observations: line(effective),
        }),
      ),
    );
    result.push({
      schema_version: "0.1.0",
      kind: "guarded_analysis_frame",
      decision: allowed ? "allowed" : "blocked",
      suppressed_track_ids: allowed
        ? []
        : measured.observations
            .map((value) => value.track_id)
            .sort((a, b) => a - b),
      health: report,
      analysis: analysisCandidate.frames[0],
    });
    analysis = analysisCandidate.checkpoint;
    health = healthCandidate.checkpoint;
  }
  return { frames: result, checkpoint: combine(analysis, health) };
}

test("guarded reports match host composition of both existing pure APIs and native commands", () => {
  const { header, frames } = fixture();
  const actual = browser(header, frames);
  closeNumeric(actual, oldComposition(header, frames));
  closeNumeric(actual.frames, native("--guarded", [header, ...frames]));
  closeNumeric(
    actual.checkpoint,
    native("--guarded-checkpoint", [header, ...frames])[0],
  );
  assert.deepEqual(actual.frames[0].suppressed_track_ids, [1, 2]);
  assert.deepEqual(actual.frames[0].analysis.measurement.tracks, []);
  assert.equal(actual.frames[2].decision, "allowed");
  assert.equal(
    actual.frames[2].analysis.measurement.tracks[0].status,
    "initializing",
  );
  assert.deepEqual(actual.frames[4].analysis.measurement.tracks, []);
  assert.equal(
    actual.frames[5].analysis.measurement.closed_segment_ids.length,
    2,
    "filters hidden by prior empty output were not removed",
  );
  assert.equal(
    actual.frames[11].analysis.measurement.tracks[0].status,
    "initializing",
  );
  assert.notEqual(
    actual.frames[11].analysis.measurement.tracks[0].segment_id,
    actual.frames[2].analysis.measurement.tracks[0].segment_id,
  );
  assert.equal(
    actual.frames[11].analysis.counting.crossings.length,
    0,
    "recovery invented a crossing through the blocked interval",
  );
  assert.equal(
    actual.frames[14].decision,
    "blocked",
    "gap at health limit did not block immediately",
  );
});

test("all cut points resume complete guarded evidence across four runtime directions", (context) => {
  const { header, frames } = fixture();
  const expected = browser(header, frames);
  let cuts = 0,
    continuations = 0;
  for (let cut = 0; cut <= frames.length; cut++) {
    const nativeSaved = native("--guarded-checkpoint", [
      header,
      ...frames.slice(0, cut),
    ])[0];
    const webSaved = browser(header, frames.slice(0, cut)).checkpoint;
    closeNumeric(nativeSaved, webSaved);
    for (const saved of [nativeSaved, webSaved]) {
      const source = { resume: saved };
      closeNumeric(browser(source, frames.slice(cut)), {
        frames: expected.frames.slice(cut),
        checkpoint: expected.checkpoint,
      });
      closeNumeric(
        native("--guarded", [source, ...frames.slice(cut)]),
        expected.frames.slice(cut),
      );
      closeNumeric(
        native("--guarded-checkpoint", [source, ...frames.slice(cut)])[0],
        expected.checkpoint,
      );
      continuations += 2;
    }
    closeNumeric(
      browser(
        pair({ resume: nativeSaved.analysis }, { resume: nativeSaved.health }),
        frames.slice(cut),
      ),
      { frames: expected.frames.slice(cut), checkpoint: expected.checkpoint },
    );
    cuts++;
  }
  context.diagnostic(
    JSON.stringify({
      cut_points: cuts,
      continuations,
      directions: [
        "native-native",
        "native-javascript",
        "javascript-native",
        "javascript-javascript",
      ],
    }),
  );
});

test("blocked objects still validate raw integer tokens, unique identities, covariance and wrapper timestamps", () => {
  const { header, frames } = fixture();
  for (const mutate of [
    (v) => {
      v.observations.push(clone(v.observations[0]));
    },
    (v) => {
      v.lost = [1];
    },
    (v) => {
      v.removed = [2];
    },
    (v) => {
      v.observations[0].covariance = [1, 2, 1];
    },
    (v) => {
      v.extra = true;
    },
  ]) {
    const bad = clone(frames[1]);
    const measurement = JSON.parse(bad.measurement);
    mutate(measurement);
    bad.measurement = line(measurement);
    failure(invoke(header, ndjson([frames[0], bad])));
    native("--guarded-checkpoint", [header, frames[0], bad], 2);
  }
  const fractional = clone(frames[1]);
  fractional.measurement = fractional.measurement.replace(
    '"track_id":2',
    '"track_id":2.0000000000000001',
  );
  failure(invoke(header, ndjson([fractional])));
  const mismatch = clone(frames[1]);
  const health = JSON.parse(mismatch.health);
  health.timestamp_us = String(BigInt(health.timestamp_us) + 1n);
  mismatch.health = line(health);
  failure(invoke(header, ndjson([mismatch])));
  failure(invoke(header, ndjson([{ ...frames[0], extra: true }])));
  failure(invoke(header, ndjson([frames[0], ""])));
  failure(
    invoke(header, ndjson(['{"health":"bad",' + line(frames[0]).slice(1)])),
  );
  failure(invoke('{"analysis":"bad",' + line(header).slice(1), ""));
  failure(
    moonground_guarded(JSON.stringify({ source: header, observations: "" })),
  );
  const saved = browser(header, frames.slice(0, 1)).checkpoint;
  closeNumeric(browser({ resume: saved }, frames.slice(1)), {
    frames: browser(header, frames).frames.slice(1),
    checkpoint: browser(header, frames).checkpoint,
  });
  closeNumeric(
    browser(header, frames.map(line).join("\r\n")),
    browser(header, frames),
  );
  closeNumeric(
    browser(header, frames.map(line).join("\n")),
    browser(header, frames),
  );
});

test("combined checkpoints reject blocked live state, early segments and mismatched effective calibration", () => {
  const { header, frames } = fixture(0n);
  const saved = browser(header, frames.slice(0, 4)).checkpoint;
  for (const mutate of [
    (v) => {
      v.health.state.streak = null;
    },
    (v) => {
      v.health.state.streak.since_us = "100000";
    },
    (v) => {
      v.health.state.last_timestamp_us = "400001";
    },
    (v) => {
      v.health.configuration.calibration.matrix[2] += 0.1;
    },
    (v) => {
      v.health.configuration.calibration.roi.reverse();
    },
    (v) => {
      v.health.configuration.calibration.ground_noise_floor_m *= 2;
    },
    (v) => {
      v.health.configuration.calibration.max_meters_per_pixel *= 2;
    },
  ]) {
    const invalid = clone(saved);
    mutate(invalid);
    failure(invoke({ resume: invalid }, ""));
    native("--guarded-checkpoint", [{ resume: invalid }], 2);
  }
  failure(invoke({ resume: saved, health: header.health }, ""));
});

test("pure guarded calls remain available with all existing measurement handles occupied", () => {
  const handles = [];
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(
            JSON.stringify({
              session_id: `guarded-occupied-${i}`,
              mode: "ground",
            }),
          ),
        ).handle,
      );
    failure(moonground_create('{"session_id":"full","mode":"ground"}'));
    const { header, frames } = fixture();
    assert.equal(browser(header, frames).frames.length, frames.length);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
});

test("exact source, outer frame, input, count and wrapper UTF-16 limits are enforced", () => {
  const { header } = fixture();
  const saved = browser(header).checkpoint;
  const exactSource = line({ resume: saved }).padEnd(8388619, " ");
  closeNumeric(browser(exactSource).checkpoint, saved);
  failure(invoke(exactSource + " ", ""));
  const empty = (i) => wrap(objects(i), landmarks(i));
  const exactFrame = line(empty(0)).padEnd(1048576, " ");
  assert.equal(browser(header, exactFrame).frames.length, 1);
  failure(invoke(header, exactFrame + " "));
  const exactInput = Array.from(
    { length: 8 },
    (_, i) => line(empty(i)).padEnd(1048575, " ") + "\n",
  ).join("");
  assert.equal(exactInput.length, 8388608);
  assert.equal(browser(header, exactInput).frames.length, 8);
  failure(invoke(header, exactInput + " "));
  const smallHealth = JSON.parse(header.health);
  smallHealth.landmarks = smallHealth.landmarks.slice(0, 1);
  smallHealth.health.min_landmarks = 1;
  const small = pair(header.analysis, smallHealth);
  const frames = Array.from({ length: 5000 }, (_, i) => empty(i));
  assert.equal(browser(small, frames).frames.length, 5000);
  failure(invoke(small, ndjson([...frames, empty(5000)])));
  const request = JSON.stringify({
    source: line(header),
    observations: "",
  }).padEnd(16777216, " ");
  unpack(moonground_guarded(request));
  failure(moonground_guarded(request + " "));
});

test("the pure output limit includes health and analysis checkpoints after the complete frame array", () => {
  const { header } = fixture();
  const health = JSON.parse(header.health);
  const limit = 8388608;
  let selected = null,
    source;
  for (let width = 8; width <= 128 && !selected; width++) {
    health.landmarks = Array.from({ length: 64 }, (_, i) => ({
      landmark_id: String(i + 1).padEnd(width, "x"),
      ground_m: [0, 0],
    }));
    source = pair(header.analysis, health);
    const prototype = browser(source, [wrap(objects(0), landmarks(0))]);
    const frameLength = line(prototype.frames[0]).length;
    let sum = 0;
    for (let count = 1; count <= 5000; count++) {
      const timestamp = String(count - 1);
      sum += frameLength + 3 * (timestamp.length - 1);
      prototype.checkpoint.health.state.last_timestamp_us = timestamp;
      prototype.checkpoint.analysis.measurement.motion.last_timestamp_us =
        timestamp;
      prototype.checkpoint.analysis.counting.state.last_timestamp_us =
        timestamp;
      const completeLength =
        '{"frames":['.length +
        sum +
        count -
        1 +
        '],"checkpoint":'.length +
        line(prototype.checkpoint).length +
        1;
      if (completeLength > limit) {
        if (sum + count <= limit)
          selected = { count, completeLength, frameBufferLength: sum + count };
        break;
      }
    }
  }
  assert.ok(selected, "could not isolate the final checkpoint budget");
  const frames = Array.from({ length: selected.count }, (_, i) =>
    wrap(objects(i), landmarks(i)),
  );
  assert.equal(
    browser(source, frames.slice(0, -1)).frames.length,
    frames.length - 1,
  );
  assert.match(failure(invoke(source, ndjson(frames))), /output.*8388608/);
});
