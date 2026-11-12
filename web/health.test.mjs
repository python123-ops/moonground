import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
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
assert.ok(binary, "Build the native release CLI before health verification.");
const clone = (value) => JSON.parse(JSON.stringify(value));
const line = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
const ndjson = (records) =>
  records.map(line).join("\n") + (records.length ? "\n" : "");
const frame = (timestamp, observations = []) => ({
  timestamp_us: String(timestamp),
  observations,
});
const observation = (landmark_id, point, covariance) => ({
  landmark_id,
  point,
  ...(covariance ? { covariance } : {}),
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
    "failed pure call exposed partial frames/checkpoint",
  );
  return value.error;
}

function closeNumeric(actual, expected, location = "$") {
  if (typeof expected === "number") {
    assert.equal(typeof actual, "number", location);
    assert.ok(Number.isFinite(actual), location);
    if (
      /\.(usable_count|streak_observations|min_landmarks|min_observations)$/.test(
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
    maxBuffer: 40 * 1024 * 1024,
    timeout: 120000,
  });
  assert.equal(run.status, status, run.stderr || run.error?.message);
  if (!status) assert.equal(run.stderr, "");
  if (run.stdout) assert.ok(run.stdout.endsWith("\n"), "partial native line");
  if (status && mode === "--health-checkpoint") assert.equal(run.stdout, "");
  return run.stdout ? run.stdout.trimEnd().split("\n").map(JSON.parse) : [];
}

const invoke = (source, observations) =>
  moonground_health(JSON.stringify({ source: line(source), observations }));
const browser = (source, observations = []) =>
  unpack(
    invoke(
      source,
      typeof observations === "string" ? observations : ndjson(observations),
    ),
  );

function distort(point, camera) {
  const x = (point[0] - camera.cx) / camera.fx,
    y = (point[1] - camera.cy) / camera.fy;
  const r2 = x * x + y * y;
  const radial = 1 + camera.k1 * r2 + camera.k2 * r2 * r2;
  return [
    (x * radial + 2 * camera.p1 * x * y + camera.p2 * (r2 + 2 * x * x)) *
      camera.fx +
      camera.cx,
    (y * radial + camera.p1 * (r2 + 2 * y * y) + 2 * camera.p2 * x * y) *
      camera.fy +
      camera.cy,
  ];
}

function fixture(withCamera = false) {
  const ideals = [
    [280, 220],
    [350, 200],
    [300, 290],
    [360, 280],
  ];
  const config = {
    monitor_id: withCamera ? "health-brown-parity" : "health-parity",
    calibration: {
      matrix: [0.02, 0, 0, 0, 0.02, 0, 0, 0, 1],
      roi: [
        [100, 100],
        [600, 100],
        [600, 400],
        [100, 400],
      ],
    },
    landmarks: ideals.map((point, i) => ({
      landmark_id: String.fromCharCode(65 + i),
      ground_m: point.map((v) => v * 0.02),
    })),
    health: {
      min_landmarks: 3,
      rms_limit_m: 0.1,
      max_error_m: 0.2,
      confirmation_us: "300000",
      min_observations: 3,
      max_gap_us: "500000",
      max_position_std_m: 0.2,
    },
  };
  if (withCamera)
    config.camera = {
      fx: 400,
      fy: 500,
      cx: 320,
      cy: 240,
      k1: 0.02,
      k2: -0.003,
      p1: 0.001,
      p2: -0.001,
      max_normalized_radius: 0.8,
    };
  const points = (offset = 0) =>
    ideals.map((point, i) => {
      const shifted = [point[0] + offset, point[1]];
      return observation(
        String.fromCharCode(65 + i),
        withCamera ? distort(shifted, config.camera) : shifted,
        [4, 0.5, 6],
      );
    });
  const start = 9007199254740993n;
  const relative = [
    0, 100000, 300000, 400000, 500000, 700000, 800000, 900000, 1000000, 1100000,
    1200000, 1400000, 1900000, 2000000, 2200000,
  ];
  const frames = relative.map((time, i) =>
    frame(
      start + BigInt(time),
      i === 6 ? [] : points(i >= 3 && i <= 5 ? 20 : 0),
    ),
  );
  frames[8].observations[2].point = [3000, 3000];
  frames[8].observations[3].point = [-3000, -3000];
  frames[10].observations[0].covariance = [10000, 0, 10000];
  return { config, frames };
}

test("health numerical reports and sampled confirmations agree in native and JavaScript", (context) => {
  let total = 0;
  for (const camera of [false, true]) {
    const { config, frames } = fixture(camera);
    const actual = browser(config, frames);
    closeNumeric(actual.frames, native("--health", [config, ...frames]));
    closeNumeric(
      actual.checkpoint,
      native("--health-checkpoint", [config, ...frames])[0],
    );
    assert.equal(actual.frames[0].timestamp_us, "9007199254740993");
    assert.deepEqual([...new Set(actual.frames.map((v) => v.status))].sort(), [
      "drift",
      "healthy",
      "insufficient",
      "pending",
    ]);
    assert.equal(
      actual.frames[6].status,
      "insufficient",
      "missing frame retained stale healthy/drift",
    );
    assert.equal(actual.frames[8].usable_count, 2);
    assert.ok(
      actual.frames[8].rms_error_m !== null,
      "partial usable points lost their RMS",
    );
    assert.equal(
      actual.frames[12].status,
      "pending",
      "gap exactly at limit did not reset confirmation",
    );
    assert.equal(
      actual.frames[10].landmarks[0].rejection_reason,
      "position_uncertainty",
    );
    assert.ok(actual.frames[10].landmarks[0].projected_covariance);
    assert.equal(actual.frames[10].landmarks[0].residual_m, null);
    total += frames.length;
  }
  context.diagnostic(
    `${total} camera/uncorrected frames; exact timestamps above 2^53`,
  );
});

test("every checkpoint cut preserves complete evidence across four runtime directions", (context) => {
  let cutPoints = 0,
    continuations = 0;
  for (const camera of [false, true]) {
    const { config, frames } = fixture(camera);
    const complete = browser(config, frames);
    for (let cut = 0; cut <= frames.length; cut++) {
      const savedNative = native("--health-checkpoint", [
        config,
        ...frames.slice(0, cut),
      ])[0];
      const savedWeb = browser(config, frames.slice(0, cut)).checkpoint;
      closeNumeric(savedWeb, savedNative);
      for (const saved of [savedNative, savedWeb]) {
        const source = { resume: saved };
        closeNumeric(browser(source, frames.slice(cut)), {
          frames: complete.frames.slice(cut),
          checkpoint: complete.checkpoint,
        });
        closeNumeric(
          native("--health", [source, ...frames.slice(cut)]),
          complete.frames.slice(cut),
        );
        closeNumeric(
          native("--health-checkpoint", [source, ...frames.slice(cut)])[0],
          complete.checkpoint,
        );
        continuations += 2;
      }
      cutPoints++;
    }
  }
  context.diagnostic(
    JSON.stringify({
      cut_points: cutPoints,
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

test("invalid raw tokens and late structural failures expose only errors and saved checkpoints remain reusable", () => {
  const { config, frames } = fixture();
  const saved = browser(config, frames.slice(0, 1)).checkpoint;
  for (const source of [
    line(config).replace(
      '"min_observations":3',
      '"min_observations":3.0000000000000001',
    ),
    '{"monitor_id":"duplicate",' + line(config).slice(1),
    { ...config, extra: true },
    { resume: saved, monitor_id: "override" },
  ])
    failure(invoke(source, ""));
  const invalid = clone(frames[1]);
  invalid.observations[0].landmark_id = "unknown";
  failure(invoke({ resume: saved }, ndjson([invalid])));
  failure(invoke(config, ndjson([frames[0], invalid])));
  native("--health-checkpoint", [config, frames[0], invalid], 2);
  failure(invoke(config, ndjson([frames[0], { ...frames[1], extra: true }])));
  failure(invoke(config, ndjson([frames[0], ""])));
  failure(
    invoke(
      config,
      ndjson([frames[0], '{"timestamp_us":"1",' + line(frames[1]).slice(1)]),
    ),
  );
  const duplicate = clone(frames[1]);
  duplicate.observations.push(clone(duplicate.observations[0]));
  failure(invoke(config, ndjson([duplicate])));
  const covariance = clone(frames[1]);
  covariance.observations[0].covariance = [1, 2, 1];
  failure(invoke(config, ndjson([covariance])));
  failure(
    moonground_health(JSON.stringify({ source: config, observations: "" })),
  );
  failure(
    moonground_health(
      JSON.stringify({ source: line(config), observations: "", extra: true }),
    ),
  );
  closeNumeric(browser({ resume: saved }, frames.slice(1)), {
    frames: browser(config, frames).frames.slice(1),
    checkpoint: browser(config, frames).checkpoint,
  });
  closeNumeric(
    browser(
      line(config).replace('"min_observations":3', '"min_observations":30e-1'),
      frames,
    ),
    browser(config, frames),
  );
  closeNumeric(
    browser(config, frames.map(line).join("\r\n")),
    browser(config, frames),
  );
  closeNumeric(
    browser(config, frames.map(line).join("\n")),
    browser(config, frames),
  );
});

test("checkpoint restore rejects unreachable unsaturated evidence spans and impossible unit-gap histories", () => {
  const { config, frames } = fixture();
  const saved = browser(config, frames.slice(0, 1)).checkpoint;
  for (const mutate of [
    (v) => {
      v.state.streak.evidence = "insufficient";
    },
    (v) => {
      v.state.streak.observations = 0;
    },
    (v) => {
      v.state.streak.observations = 4;
    },
    (v) => {
      v.state.streak.since_us = String(BigInt(v.state.last_timestamp_us) - 1n);
    },
    (v) => {
      v.state.streak.since_us = String(BigInt(v.state.last_timestamp_us) + 1n);
    },
    (v) => {
      v.state.last_timestamp_us = null;
    },
    (v) => {
      v.state.streak.observations = 2;
      v.state.streak.since_us = String(
        BigInt(v.state.last_timestamp_us) - 1000000n,
      );
    },
    (v) => {
      v.configuration.health.min_observations = 1;
      v.configuration.health.max_gap_us = "1";
      v.state.streak.since_us = String(BigInt(v.state.last_timestamp_us) - 1n);
    },
  ]) {
    const invalid = clone(saved);
    mutate(invalid);
    failure(invoke({ resume: invalid }, ""));
    native("--health-checkpoint", [{ resume: invalid }], 2);
  }
  failure(
    invoke(
      '{"resume":' +
        line(saved).replace(
          '"observations":1',
          '"observations":1.0000000000000001',
        ) +
        "}",
      "",
    ),
  );
  for (const path of [
    ["configuration", "health"],
    ["configuration", "health", "rms_limit_m"],
    ["configuration", "health", "min_observations"],
    ["configuration", "calibration", "ground_noise_floor_m"],
  ]) {
    const invalid = clone(saved);
    let parent = invalid;
    for (const key of path.slice(0, -1)) parent = parent[key];
    delete parent[path.at(-1)];
    failure(invoke({ resume: invalid }, ""));
  }
  const brown = fixture(true);
  const brownSaved = browser(brown.config, brown.frames.slice(0, 1)).checkpoint;
  delete brownSaved.configuration.camera.k1;
  failure(invoke({ resume: brownSaved }, ""));
});

test("pure health calls do not consume any of the 64 existing measurement handles", () => {
  const handles = [];
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(
            JSON.stringify({
              session_id: `occupied-health-${i}`,
              mode: "ground",
            }),
          ),
        ).handle,
      );
    failure(moonground_create('{"session_id":"full","mode":"ground"}'));
    const { config, frames } = fixture(true);
    assert.equal(browser(config, frames).frames.length, frames.length);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
});

test("exact UTF-16 configuration, resume, frame, input, count and wrapper limits are enforced", () => {
  const { config } = fixture();
  const exactConfig = line(config).padEnd(1048576, " ");
  browser(exactConfig);
  failure(invoke(exactConfig + " ", ""));
  const saved = browser(config).checkpoint;
  const exactResume = line({ resume: saved }).padEnd(8388619, " ");
  closeNumeric(browser(exactResume).checkpoint, saved);
  failure(invoke(exactResume + " ", ""));
  const exactLine = line(frame(0)).padEnd(1048576, " ");
  assert.equal(browser(config, exactLine).frames.length, 1);
  failure(invoke(config, exactLine + " "));
  const exactInput = Array.from(
    { length: 8 },
    (_, i) => line(frame(i)).padEnd(1048575, " ") + "\n",
  ).join("");
  assert.equal(exactInput.length, 8388608);
  assert.equal(browser(config, exactInput).frames.length, 8);
  failure(invoke(config, exactInput + " "));
  // Use one landmark to keep a legal 5000-frame bundle below its output budget.
  const small = clone(config);
  small.landmarks = small.landmarks.slice(0, 1);
  small.health.min_landmarks = 1;
  const frames = Array.from({ length: 5000 }, (_, i) => frame(i));
  assert.equal(browser(small, frames).frames.length, 5000);
  failure(invoke(small, ndjson([...frames, frame(5000)])));
  const wrapper = JSON.stringify({
    source: line(config),
    observations: "",
  }).padEnd(16777216, " ");
  unpack(moonground_health(wrapper));
  failure(moonground_health(wrapper + " "));
});

test("the total pure output budget includes the final durable checkpoint", () => {
  const { config } = fixture();
  const limit = 8388608;
  let selected = null;
  for (let width = 8; width <= 128 && !selected; width++) {
    config.landmarks = Array.from({ length: 64 }, (_, i) => ({
      landmark_id: String(i + 1).padEnd(width, "x"),
      ground_m: [0, 0],
    }));
    const prototype = browser(config, [frame(0)]);
    const frameLength = line(prototype.frames[0]).length;
    let sum = 0;
    for (let count = 1; count <= 5000; count++) {
      sum += frameLength + String(count - 1).length - 1;
      prototype.checkpoint.state.last_timestamp_us = String(count - 1);
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
  assert.ok(selected, "could not isolate the final checkpoint's output budget");
  assert.ok(selected.frameBufferLength <= limit);
  assert.ok(selected.completeLength > limit);
  const frames = Array.from({ length: selected.count }, (_, i) => frame(i));
  assert.equal(
    browser(config, frames.slice(0, -1)).frames.length,
    frames.length - 1,
  );
  assert.match(failure(invoke(config, ndjson(frames))), /output.*8388608/);
});
