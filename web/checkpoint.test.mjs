import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_create,
  moonground_update,
  moonground_close,
  moonground_checkpoint,
  moonground_restore,
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
  "Build the native release command before checkpoint verification.",
);

const clone = (value) => JSON.parse(JSON.stringify(value));
const unpack = (source) => {
  const value = JSON.parse(source);
  assert.equal(value.error, undefined, source);
  return value;
};
const fail = (source) => {
  const value = JSON.parse(source);
  assert.equal(typeof value.error, "string", source);
  return value.error;
};

function closeNumeric(actual, expected, location = "$", tolerance = 2e-8) {
  if (typeof expected === "number") {
    assert.equal(typeof actual, "number", location);
    assert.ok(Number.isFinite(actual), location);
    if (
      /\.(track_id|accepted_count|min_observations|max_tracks)$/.test(location)
    ) {
      assert.equal(actual, expected, location);
      return;
    }
    assert.ok(
      Math.abs(actual - expected) <=
        tolerance * Math.max(1, Math.abs(expected)),
      `${location}: ${actual} != ${expected}`,
    );
  } else if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual), location);
    assert.equal(actual.length, expected.length, location);
    expected.forEach((value, index) =>
      closeNumeric(actual[index], value, `${location}[${index}]`, tolerance),
    );
  } else if (expected && typeof expected === "object") {
    assert.deepEqual(
      Object.keys(actual).sort(),
      Object.keys(expected).sort(),
      location,
    );
    for (const key of Object.keys(expected))
      closeNumeric(actual[key], expected[key], `${location}.${key}`, tolerance);
  } else assert.equal(actual, expected, location);
}

function native(mode, records, expectedStatus = 0, extra = []) {
  const input =
    records
      .map((item) => (typeof item === "string" ? item : JSON.stringify(item)))
      .join("\n") + "\n";
  const output = spawnSync(binary, [mode, ...extra], {
    input,
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  });
  assert.equal(
    output.status,
    expectedStatus,
    output.stderr || output.error?.message,
  );
  if (expectedStatus === 0) assert.equal(output.stderr, "");
  else if (mode === "--checkpoint")
    assert.equal(
      output.stdout,
      "",
      "invalid checkpoint emitted partial stdout",
    );
  if (output.stdout)
    assert.ok(output.stdout.endsWith("\n"), "incomplete native output line");
  return output.stdout.trim()
    ? output.stdout.trim().split("\n").map(JSON.parse)
    : [];
}

function nativeCheckpoint(records) {
  const values = native("--checkpoint", records);
  assert.equal(values.length, 1);
  return values[0];
}

function browserReplay(configuration, frames, saved = null) {
  const { handle } = saved
    ? unpack(moonground_restore(JSON.stringify(saved)))
    : unpack(moonground_create(JSON.stringify(configuration)));
  try {
    const outputs = frames.map((frame) =>
      unpack(moonground_update(handle, JSON.stringify(frame))),
    );
    const checkpoint = unpack(moonground_checkpoint(handle));
    assert.deepEqual(
      unpack(moonground_checkpoint(handle)),
      checkpoint,
      "checkpoint export mutated the session",
    );
    return { outputs, checkpoint };
  } finally {
    assert.equal(moonground_close(handle), true);
  }
}

const obs = (track_id, point, covariance = [0.01, 0.002, 0.02]) => ({
  track_id,
  point,
  covariance,
});
const frame = (timestamp, observations = [], lost = [], removed = []) => ({
  timestamp_us: String(timestamp),
  observations,
  lost,
  removed,
});
function groundFixture() {
  return {
    configuration: {
      session_id: "checkpoint-cross-runtime",
      mode: "ground",
      diagnostics: true,
      motion: {
        q: 0.15,
        max_velocity_std_mps: 0.4,
        max_position_std_m: 0.15,
        max_tracks: 4,
      },
    },
    frames: [
      frame(0, [obs(1, [0, 0]), obs(2, [2, 1])]),
      frame(100000, [obs(1, [0.1, 0])]),
      frame(300000, [obs(1, [0.3, 0]), obs(2, [2, 1.1])]),
      frame(400000, [obs(1, [100, 100])]),
      frame(499999),
      frame(500000, [obs(1, [0.5, 0])], [2]),
      frame(600000, [], [], [1]),
      frame(700000, [obs(1, [0.7, 0])]),
      frame(1199999),
      frame(1200000, [obs(1, [1.2, 0])]),
    ],
  };
}

function cameraFixture() {
  const lines = readFileSync(
    path.join(root, "examples", "distorted-camera.ndjson"),
    "utf8",
  )
    .trim()
    .split("\n")
    .map(JSON.parse);
  const [configuration, ...frames] = lines;
  configuration.diagnostics = true;
  const copied = clone(frames);
  const middle = Math.floor(copied.length / 2);
  copied[middle].observations[0].point = [3000, 3000];
  return { configuration, frames: copied };
}

function extremeScaleFixture() {
  return {
    configuration: {
      session_id: "checkpoint-extreme-scale",
      mode: "ground",
      diagnostics: true,
      motion: { q: 0, initial_velocity_std: 1e106, max_gap_us: "2000000" },
    },
    frames: [
      frame(500000, [obs(1, [0, 0], [1e-32, -9.999999999990001e-33, 1e-32])]),
      frame(500001, [obs(1, [0, 0], [1e186, 0, 1e186])]),
    ],
  };
}

test("complete checkpoints continue through all four native/JavaScript directions", (context) => {
  let directions = 0;
  let cuts = 0;
  for (const fixture of [
    groundFixture(),
    cameraFixture(),
    extremeScaleFixture(),
  ]) {
    const { configuration, frames } = fixture;
    const nativeBaseline = native("--stream", [configuration, ...frames]);
    if (configuration.session_id === "checkpoint-extreme-scale") {
      assert.equal(nativeBaseline.at(-1).tracks[0].status, "numerical_failure");
      assert.equal(nativeBaseline.at(-1).tracks[0].accepted_count, 1);
      assert.equal(
        nativeBaseline.at(-1).tracks[0].last_accepted_timestamp_us,
        "500000",
      );
    }
    const nativeFinal = nativeCheckpoint([configuration, ...frames]);
    const browserBaseline = browserReplay(configuration, frames);
    closeNumeric(browserBaseline.outputs, nativeBaseline);
    closeNumeric(browserBaseline.checkpoint, nativeFinal);
    for (let cut = 0; cut <= frames.length; cut++) {
      const nativeSaved = nativeCheckpoint([
        configuration,
        ...frames.slice(0, cut),
      ]);
      const browserSaved = browserReplay(
        configuration,
        frames.slice(0, cut),
      ).checkpoint;
      closeNumeric(browserSaved, nativeSaved);
      assert.equal(nativeSaved.format, "moonground.session");
      assert.equal(nativeSaved.checkpoint_version, "1");
      assert.equal(typeof nativeSaved.motion.next_segment_id, "string");
      for (const [source, saved] of [
        ["native", nativeSaved],
        ["javascript", browserSaved],
      ]) {
        const actualNative = native("--stream", [
          { resume: saved },
          ...frames.slice(cut),
        ]);
        const actualBrowser = browserReplay(null, frames.slice(cut), saved);
        closeNumeric(actualNative, nativeBaseline.slice(cut));
        closeNumeric(actualBrowser.outputs, nativeBaseline.slice(cut));
        closeNumeric(actualBrowser.checkpoint, nativeFinal);
        closeNumeric(
          nativeCheckpoint([{ resume: saved }, ...frames.slice(cut)]),
          nativeFinal,
        );
        if (source === "native")
          assert.deepEqual(actualNative, nativeBaseline.slice(cut));
        else
          assert.deepEqual(
            actualBrowser.outputs,
            browserBaseline.outputs.slice(cut),
          );
        directions += 2;
      }
      cuts++;
    }
  }
  context.diagnostic(
    JSON.stringify({
      cut_points: cuts,
      directional_restarts: directions,
      directions: [
        "native-native",
        "native-javascript",
        "javascript-native",
        "javascript-javascript",
      ],
      cross_runtime_tolerance: 2e-8,
      same_runtime_exact: true,
    }),
  );
});

test("closed identities, exact Int64 timestamps and large segment counters survive restoration", () => {
  const fixture = groundFixture();
  const saved = nativeCheckpoint([
    fixture.configuration,
    ...fixture.frames.slice(0, 7),
  ]);
  assert.deepEqual(
    saved.motion.tracks,
    [],
    "fixture must have released all old identities",
  );
  assert.ok(BigInt(saved.motion.next_segment_id) > 1n);
  saved.motion.next_segment_id = "9223372036854775806";
  saved.motion.last_timestamp_us = "9007199254740993";
  const follow = frame("9007199254840993", [obs(3, [1, 2])]);
  for (const source of [saved, browserReplay(null, [], saved).checkpoint]) {
    const actual = browserReplay(null, [follow], source);
    const nativeActual = native("--stream", [{ resume: source }, follow]);
    closeNumeric(actual.outputs, nativeActual);
    assert.equal(actual.outputs[0].timestamp_us, follow.timestamp_us);
    assert.equal(actual.outputs[0].tracks[0].segment_id, "9223372036854775806");
    assert.equal(
      actual.checkpoint.motion.next_segment_id,
      "9223372036854775807",
    );
    assert.equal(actual.outputs[0].tracks[0].observed_path_length_m, 0);
  }
});

test("damaged restore requests consume no handles and leave live measurement streams intact", () => {
  const fixture = groundFixture();
  const saved = nativeCheckpoint([
    fixture.configuration,
    ...fixture.frames.slice(0, 3),
  ]);
  const control = unpack(moonground_restore(JSON.stringify(saved))).handle;
  const live = unpack(moonground_restore(JSON.stringify(saved))).handle;
  let next = null;
  try {
    const bad = [];
    const mutate = (name, action) => {
      const item = clone(saved);
      action(item);
      bad.push([name, JSON.stringify(item)]);
    };
    mutate("unknown version", (item) => {
      item.checkpoint_version = "2";
    });
    mutate("duplicate track", (item) => {
      item.motion.tracks.push(clone(item.motion.tracks[0]));
    });
    mutate("asymmetric covariance", (item) => {
      item.motion.tracks[0].covariance[1] = 100;
    });
    mutate("indefinite covariance", (item) => {
      item.motion.tracks[0].covariance[0] = -1;
    });
    mutate("broken path anchor", (item) => {
      item.motion.tracks[0].last_filtered[0] += 1;
    });
    mutate("bad motion config", (item) => {
      item.configuration.motion.q = -1;
    });
    mutate("counter rollback", (item) => {
      item.motion.next_segment_id = "1";
    });
    bad.push([
      "duplicate JSON key",
      JSON.stringify(saved).replace('{"', '{"format":"moonground.session","'),
    ]);
    bad.push(["truncated", JSON.stringify(saved).slice(0, -2)]);
    for (const [name, source] of bad)
      assert.ok(fail(moonground_restore(source)).length, name);
    next = unpack(moonground_restore(JSON.stringify(saved))).handle;
    assert.equal(next, live + 1, "failed restore consumed handle identities");
    const continuation = JSON.stringify(fixture.frames[3]);
    assert.deepEqual(
      unpack(moonground_update(live, continuation)),
      unpack(moonground_update(control, continuation)),
    );
    assert.deepEqual(
      unpack(moonground_checkpoint(live)),
      unpack(moonground_checkpoint(control)),
    );
    // A rejected old-time frame after restoration must not consume a new time.
    fail(moonground_update(live, continuation));
    const nextFrame = JSON.stringify(fixture.frames[4]);
    assert.deepEqual(
      unpack(moonground_update(live, nextFrame)),
      unpack(moonground_update(control, nextFrame)),
    );
  } finally {
    moonground_close(control);
    moonground_close(live);
    if (next !== null) moonground_close(next);
  }
});

test("camera and rectified calibration are validated before allocating a restored handle", () => {
  const fixture = cameraFixture();
  const saved = nativeCheckpoint([
    fixture.configuration,
    ...fixture.frames.slice(0, 2),
  ]);
  for (const damage of [
    (item) => {
      item.configuration.camera.fx = 0;
    },
    (item) => {
      item.configuration.camera.k1 = -10;
    },
    (item) => {
      delete item.configuration.camera.k3;
    },
    (item) => {
      item.configuration.calibration.matrix = Array(9).fill(0);
    },
    (item) => {
      item.configuration.calibration.roi = [
        [0, 0],
        [1, 0],
        [0, 0],
      ];
    },
  ]) {
    const altered = clone(saved);
    damage(altered);
    fail(moonground_restore(JSON.stringify(altered)));
    native("--checkpoint", [{ resume: altered }], 2);
  }
  const good = browserReplay(null, fixture.frames.slice(2), saved);
  closeNumeric(
    good.outputs,
    native("--stream", [{ resume: saved }, ...fixture.frames.slice(2)]),
  );
});

test("browser create accepts resume bootstrap text and rejects duplicate keys before parsing loses them", () => {
  const fixture = groundFixture();
  const saved = nativeCheckpoint([
    fixture.configuration,
    ...fixture.frames.slice(0, 3),
  ]);
  const raw = JSON.stringify(saved);
  const before = unpack(
    moonground_create(JSON.stringify({ resume: saved })),
  ).handle;
  let after = null;
  try {
    for (const source of [
      `{"resume":${raw},"resume":${raw}}`,
      `{"resume":${raw},"diagnostics":false}`,
      `{"resume":${raw},"motion":{"q":10}}`,
      `{"resume":${raw.slice(0, -1)},"checkpoint_version":"1"}}`,
    ]) {
      fail(moonground_create(source));
      native("--checkpoint", [source], 2);
    }
    after = unpack(moonground_create(JSON.stringify({ resume: saved }))).handle;
    assert.equal(
      after,
      before + 1,
      "rejected raw bootstrap allocated a handle",
    );
    const actual = unpack(
      moonground_update(before, JSON.stringify(fixture.frames[3])),
    );
    closeNumeric(
      actual,
      native("--stream", [{ resume: saved }, fixture.frames[3]])[0],
    );
  } finally {
    moonground_close(before);
    if (after !== null) moonground_close(after);
  }
});

test("integer fields reject raw fractions hidden by floating-point rounding and retain mathematical integers", () => {
  const fixture = groundFixture();
  const saved = nativeCheckpoint([
    fixture.configuration,
    ...fixture.frames.slice(0, 3),
  ]);
  const raw = JSON.stringify(saved);
  const replace = (source, name, value) => {
    const pattern = new RegExp(
      `("${name}":)(-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)`,
    );
    assert.match(source, pattern);
    return source.replace(pattern, (_, key) => key + value);
  };
  for (const [field, integer] of [
    ["accepted_count", "3"],
    ["track_id", "1"],
    ["max_tracks", "4"],
  ]) {
    const source = replace(raw, field, integer + ".0000000000000000001");
    fail(moonground_restore(source));
    fail(moonground_create(`{"resume":${source}}`));
    native("--checkpoint", [`{"resume":${source}}`], 2);
  }
  const rawConfig = replace(
    JSON.stringify(fixture.configuration),
    "max_tracks",
    "4.0000000000000000001",
  );
  fail(moonground_create(rawConfig));
  native("--checkpoint", [rawConfig], 2);
  const { handle } = unpack(
    moonground_create(JSON.stringify(fixture.configuration)),
  );
  try {
    const first = frame(0, [obs(1, [0, 0])]);
    const invalidFrame = replace(
      JSON.stringify(first),
      "track_id",
      "1.0000000000000000001",
    );
    fail(moonground_update(handle, invalidFrame));
    native("--checkpoint", [fixture.configuration, invalidFrame], 2);
    closeNumeric(
      unpack(moonground_update(handle, JSON.stringify(first))),
      native("--stream", [fixture.configuration, first])[0],
    );
  } finally {
    moonground_close(handle);
  }
  for (const integer of ["3.0", "3e0", "30e-1"]) {
    const created = unpack(
      moonground_restore(replace(raw, "accepted_count", integer)),
    ).handle;
    try {
      assert.equal(
        unpack(moonground_checkpoint(created)).motion.tracks[0].accepted_count,
        3,
      );
    } finally {
      moonground_close(created);
    }
  }
  for (const integer of ["4.0", "4e0", "40e-1"]) {
    const created = unpack(
      moonground_create(
        replace(JSON.stringify(fixture.configuration), "max_tracks", integer),
      ),
    ).handle;
    try {
      assert.equal(
        unpack(moonground_checkpoint(created)).configuration.motion.max_tracks,
        4,
      );
    } finally {
      moonground_close(created);
    }
  }
});

test("restoration respects browser capacity and checkpoint handles remain stale after close", () => {
  const saved = nativeCheckpoint([
    { session_id: "checkpoint-capacity", mode: "ground" },
  ]);
  const handles = [];
  try {
    for (let index = 0; index < 64; index++)
      handles.push(unpack(moonground_restore(JSON.stringify(saved))).handle);
    fail(moonground_restore(JSON.stringify(saved)));
    assert.deepEqual(unpack(moonground_checkpoint(handles[0])), saved);
    const closed = handles.pop();
    assert.equal(moonground_close(closed), true);
    fail(moonground_checkpoint(closed));
    fail(moonground_update(closed, JSON.stringify(frame(0))));
    const replacement = unpack(
      moonground_restore(JSON.stringify(saved)),
    ).handle;
    assert.notEqual(replacement, closed);
    handles.push(replacement);
    fail(moonground_checkpoint(closed));
    assert.equal(moonground_close(closed), false);
  } finally {
    handles.forEach(moonground_close);
  }
  fail(moonground_checkpoint(0));
  fail(moonground_checkpoint(2147483647));
});
