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
  moonground_transit,
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
assert.ok(
  binary,
  "Build the native CLI before projection replacement verification.",
);
const clone = (value) => JSON.parse(JSON.stringify(value));
const line = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
const ndjson = (records) =>
  records.map(line).join("\n") + (records.length ? "\n" : "");
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
const objects = (timestamp, observations = [], removed = []) => ({
  timestamp_us: String(timestamp),
  observations,
  lost: [],
  removed,
});
const wrap = (measurement, health) => ({
  measurement: line(measurement),
  health: line(health),
});
const replace = (timestamp, calibration, camera) => ({
  replace_projection: line({
    timestamp_us: String(timestamp),
    calibration,
    camera,
  }),
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
    "failed pure batch exposed a prefix",
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
const browser = (source, frames = []) =>
  unpack(invoke(source, typeof frames === "string" ? frames : ndjson(frames)));
const oldHealth = (source, frames) =>
  unpack(
    moonground_health(
      JSON.stringify({ source: line(source), observations: ndjson(frames) }),
    ),
  );
const oldAnalysis = (source, frames) =>
  unpack(
    moonground_analysis(
      JSON.stringify({ source: line(source), observations: ndjson(frames) }),
    ),
  );

function calibration(index = 0) {
  return {
    matrix: index
      ? [0.25, 0, -1, 0, 0.2, 0.5, 0, 0, 1]
      : [0.125, 0, 0, 0, 0.125, 0, 0, 0, 1],
    roi: [
      [-200, -200],
      [200, -200],
      [200, 200],
      [-200, 200],
    ],
    max_meters_per_pixel: 1,
    ground_noise_floor_m: 0.001,
  };
}
function camera(index = 0) {
  return {
    fx: 400 + index * 170,
    fy: 420 + index * 110,
    cx: index * 10,
    cy: index * 20,
    k1: 0.08 - index * 0.12,
    k2: -0.01,
    k3: 0.001,
    p1: 0.0002,
    p2: -0.0003,
    max_normalized_radius: 0.8,
  };
}
function pixel(config, world) {
  const h = config.calibration.matrix;
  const ideal = [(world[0] - h[2]) / h[0], (world[1] - h[5]) / h[4]];
  if (!config.camera) return ideal;
  const c = config.camera,
    x = (ideal[0] - c.cx) / c.fx,
    y = (ideal[1] - c.cy) / c.fy;
  const r2 = x * x + y * y,
    radial = 1 + c.k1 * r2 + c.k2 * r2 * r2 + c.k3 * r2 * r2 * r2;
  return [
    c.fx * (x * radial + 2 * c.p1 * x * y + c.p2 * (r2 + 2 * x * x)) + c.cx,
    c.fy * (y * radial + c.p1 * (r2 + 2 * y * y) + 2 * c.p2 * x * y) + c.cy,
  ];
}
function configure(name = "projection-browser") {
  const health = {
    monitor_id: name + "-landmarks",
    calibration: calibration(),
    landmarks: [
      [1, 1],
      [3, 1],
      [1, 3],
      [3, 3],
    ].map((ground_m, i) => ({
      landmark_id: String.fromCharCode(65 + i),
      ground_m,
    })),
    health: {
      min_landmarks: 3,
      rms_limit_m: 0.1,
      max_error_m: 0.2,
      min_observations: 3,
      confirmation_us: "200000",
      max_gap_us: "500000",
      max_position_std_m: 0.3,
    },
  };
  const measurement = {
    session_id: name,
    mode: "pixel",
    diagnostics: true,
    calibration: calibration(),
    motion: {
      max_tracks: 8,
      max_gap_us: "500000",
      min_observations: 2,
      min_span_us: "100000",
      gate: 1e9,
      initial_velocity_std: 10,
      q: 5,
    },
  };
  const counting = {
    session_id: name,
    gates: [
      {
        gate_id: "entry",
        start_m: [-100, 2],
        end_m: [100, 2],
        deadband_m: 0.005,
      },
      {
        gate_id: "exit",
        start_m: [-100, 6],
        end_m: [100, 6],
        deadband_m: 0.005,
      },
    ],
    max_tracks: 8,
    max_gap_us: "500000",
  };
  return {
    header: pair(
      { measurement: line(measurement), counting: line(counting) },
      health,
    ),
    health,
    counting,
  };
}
function observed(config, stamp, y = 1, hidden = false) {
  const fixed = config.landmarks.map((landmark) => ({
    landmark_id: landmark.landmark_id,
    point: pixel(config, landmark.ground_m),
    covariance: [0.04, 0.008, 0.09],
  }));
  const moving = hidden
    ? []
    : [2, 1].map((id) => ({
        track_id: id,
        point: pixel(config, [1 + id * 0.1, y]),
        covariance: [0.04, 0.008, 0.09],
      }));
  return wrap(objects(stamp, moving), {
    timestamp_us: String(stamp),
    observations: fixed,
  });
}
function fixture(start = 9007199254740993n) {
  const { header, health, counting } = configure();
  let current = clone(health),
    stamp = start;
  const frames = [];
  for (const [next, brown] of [
    [calibration(1), camera()],
    [calibration(), camera(1)],
    [calibration(), null],
    [calibration(), null],
  ]) {
    for (let i = 0; i < 5; i++) {
      frames.push(observed(current, stamp, i < 3 ? 1 : 3, i === 4));
      stamp += 100000n;
    }
    frames.push(replace(stamp, next, brown));
    stamp += 100000n;
    current.calibration = clone(next);
    if (brown) current.camera = clone(brown);
    else delete current.camera;
  }
  for (let i = 0; i < 5; i++) {
    frames.push(observed(current, stamp, i < 3 ? 1 : 3));
    stamp += 100000n;
  }
  return { header, frames, counting };
}
function changeProjection(target, source) {
  target.calibration = clone(source.calibration);
  if (source.camera) target.camera = clone(source.camera);
  else delete target.camera;
}
function hostReference(header, frames) {
  let a = oldAnalysis(JSON.parse(header.analysis), []).checkpoint;
  let h = oldHealth(JSON.parse(header.health), []).checkpoint;
  const results = [],
    snapshots = [combine(a, h)];
  for (const frame of frames) {
    const replacing = "replace_projection" in frame;
    let object, healthFrame, healthSource;
    if (replacing) {
      const control = JSON.parse(frame.replace_projection),
        config = clone(h.configuration);
      changeProjection(config, control);
      healthSource = config;
      healthFrame = { timestamp_us: control.timestamp_us, observations: [] };
      object = objects(control.timestamp_us);
    } else {
      object = JSON.parse(frame.measurement);
      healthFrame = JSON.parse(frame.health);
      healthSource = { resume: h };
    }
    const nextHealth = oldHealth(healthSource, [healthFrame]),
      report = nextHealth.frames[0];
    const allowed = !replacing && report.status === "healthy";
    const effective = allowed
      ? object
      : objects(
          object.timestamp_us,
          [],
          a.measurement.motion.tracks
            .map((v) => v.track_id)
            .sort((x, y) => x - y),
        );
    const nextAnalysis = oldAnalysis({ resume: a }, [effective]);
    if (replacing)
      changeProjection(
        nextAnalysis.checkpoint.measurement.configuration,
        nextHealth.checkpoint.configuration,
      );
    results.push({
      schema_version: "0.1.0",
      kind: replacing
        ? "guarded_projection_replaced"
        : "guarded_analysis_frame",
      decision: allowed ? "allowed" : "blocked",
      suppressed_track_ids:
        allowed || replacing
          ? []
          : object.observations.map((v) => v.track_id).sort((x, y) => x - y),
      health: report,
      analysis: nextAnalysis.frames[0],
    });
    a = nextAnalysis.checkpoint;
    h = nextHealth.checkpoint;
    snapshots.push(combine(a, h));
  }
  return { frames: results, snapshots, checkpoint: snapshots.at(-1) };
}

test("replacement equals composition of the old pure health and analysis APIs", () => {
  const { header, frames } = fixture();
  const expected = hostReference(header, frames),
    actual = browser(header, frames);
  closeNumeric(actual.frames, expected.frames);
  closeNumeric(actual.checkpoint, expected.checkpoint);
  closeNumeric(actual.frames, native("--guarded", [header, ...frames]));
  closeNumeric(
    actual.checkpoint,
    native("--guarded-checkpoint", [header, ...frames])[0],
  );
  const barriers = actual.frames.filter(
    (v) => v.kind === "guarded_projection_replaced",
  );
  assert.equal(barriers.length, 4);
  for (const frame of barriers) {
    assert.equal(frame.decision, "blocked");
    assert.deepEqual(frame.suppressed_track_ids, []);
    assert.equal(frame.health.status, "insufficient");
    assert.deepEqual(frame.analysis.measurement.tracks, []);
    assert.equal(
      frame.analysis.measurement.closed_segment_ids.length,
      2,
      "hidden active filters were not closed",
    );
  }
  assert.equal(actual.checkpoint.health.configuration.camera, undefined);
  assert.equal(
    actual.checkpoint.analysis.measurement.configuration.camera,
    undefined,
  );
});

test("every barrier-side cut restores in all four native/browser directions", (t) => {
  const { header, frames } = fixture(),
    expected = browser(header, frames);
  let continuations = 0;
  for (let cut = 0; cut <= frames.length; cut++) {
    const prefix = frames.slice(0, cut),
      suffix = frames.slice(cut);
    const saves = [
      native("--guarded-checkpoint", [header, ...prefix])[0],
      browser(header, prefix).checkpoint,
    ];
    closeNumeric(saves[0], saves[1]);
    for (const saved of saves) {
      const resume = { resume: saved },
        result = browser(resume, suffix);
      closeNumeric(result.frames, expected.frames.slice(cut));
      closeNumeric(result.checkpoint, expected.checkpoint);
      continuations++;
      closeNumeric(
        native("--guarded", [resume, ...suffix]),
        expected.frames.slice(cut),
      );
      closeNumeric(
        native("--guarded-checkpoint", [resume, ...suffix])[0],
        expected.checkpoint,
      );
      continuations++;
      // The old independent source pair remains a valid alternate restore form.
      closeNumeric(
        browser(
          pair({ resume: saved.analysis }, { resume: saved.health }),
          suffix,
        ),
        result,
      );
    }
  }
  t.diagnostic(
    JSON.stringify({
      cut_points: frames.length + 1,
      continuations,
      directions: [
        "native_to_native",
        "native_to_browser",
        "browser_to_native",
        "browser_to_browser",
      ],
    }),
  );
});

test("unstarted and Int64-maximum barriers consume exact strictly new times", () => {
  const { header } = configure("projection-clock");
  const first = browser(header, [replace(0n, calibration(), null)]);
  assert.equal(first.checkpoint.health.state.last_timestamp_us, "0");
  assert.equal(first.frames[0].kind, "guarded_projection_replaced");
  const last = browser({ resume: first.checkpoint }, [
    replace(9223372036854775807n, calibration(1), camera()),
  ]);
  assert.equal(
    last.checkpoint.health.state.last_timestamp_us,
    "9223372036854775807",
  );
  assert.equal(
    last.checkpoint.analysis.measurement.motion.last_timestamp_us,
    "9223372036854775807",
  );
  failure(
    invoke(
      { resume: last.checkpoint },
      ndjson([replace(9223372036854775807n, calibration(), null)]),
    ),
  );
  failure(invoke(header, ndjson([replace(-1n, calibration(), null)])));
});

test("raw controls reject duplicate, mixed, unknown and malformed fields without partial output", () => {
  const { header, frames } = fixture(),
    prefix = frames.slice(0, 5),
    control = JSON.parse(frames[5].replace_projection);
  const missing = clone(control);
  delete missing.camera;
  const bad = [
    { replace_projection: missing },
    { replace_projection: line(missing) },
    { ...frames[5], measurement: frames[0].measurement },
    { ...frames[5], health: frames[0].health },
    { ...frames[5], extra: 1 },
    '{"replace_projection":"bad",' + line(frames[5]).slice(1),
    { replace_projection: '{"camera":null,' + line(control).slice(1) },
    { replace_projection: '{"timestamp_us":"1",' + line(control).slice(1) },
    {
      replace_projection: line({
        ...control,
        timestamp_us: Number(control.timestamp_us),
      }),
    },
    {
      replace_projection: line({
        ...control,
        timestamp_us: "9007199254740993.0",
      }),
    },
    {
      replace_projection: line({
        ...control,
        timestamp_us: String(9007199254740993n + 400000n),
      }),
    },
    {
      replace_projection: line({
        ...control,
        camera: { ...control.camera, fx: 0 },
      }),
    },
    { replace_projection: line(control) + "{}" },
    { replace_projection: line(control).replace('"fx":400', '"fx":1e999') },
  ];
  const saved = browser(header, prefix).checkpoint,
    savedText = line(saved);
  for (const value of bad) {
    failure(invoke(header, ndjson([...prefix, value])));
    native("--guarded-checkpoint", [header, ...prefix, value], 2);
  }
  assert.equal(line(saved), savedText, "pure call mutated caller checkpoint");
  const correction = browser({ resume: saved }, [frames[5]]);
  const continuous = browser(header, frames.slice(0, 6));
  closeNumeric(correction.frames, continuous.frames.slice(5));
  closeNumeric(correction.checkpoint, continuous.checkpoint);
});

test("the inherited physical and raw-inner control limits apply before a pure batch returns", () => {
  const { header, frames } = fixture(),
    prefix = frames.slice(0, 5),
    base = frames[5].replace_projection;
  const exact = {
    replace_projection: base + " ".repeat(1048576 - line(frames[5]).length),
  };
  assert.equal(line(exact).length, 1048576);
  closeNumeric(
    browser(header, [...prefix, exact]),
    browser(header, frames.slice(0, 6)),
  );
  failure(
    invoke(
      header,
      ndjson([
        ...prefix,
        { replace_projection: exact.replace_projection + " " },
      ]),
    ),
  );
  failure(
    invoke(
      header,
      ndjson([...prefix, { replace_projection: base.padEnd(1048577) }]),
    ),
  );
});

test("a barrier cancels a downstream transit pending entry without crossing camera epochs", () => {
  const { header, frames, counting } = fixture(),
    result = browser(header, frames.slice(0, 6));
  const measurements = result.frames.map((v) => v.analysis.measurement);
  // Omit the intervening empty observation frame so the barrier is itself the
  // first discontinuity delivered to the transit consumer.
  measurements.splice(4, 1);
  const source = {
    counting: line(counting),
    sections: [
      {
        section_id: "corridor",
        entry_gate_id: "entry",
        entry_direction: "negative_to_positive",
        exit_gate_id: "exit",
        exit_direction: "negative_to_positive",
      },
    ],
    max_duration_us: "300000000",
  };
  const transit = unpack(
    moonground_transit(
      JSON.stringify({
        source: line(source),
        measurements: ndjson(measurements),
      }),
    ),
  );
  assert.equal(transit.frames.at(-2).pending_count, 2);
  assert.equal(transit.frames.at(-1).pending_count, 0);
  assert.equal(transit.frames.at(-1).cancellations.length, 2);
  assert.ok(
    transit.frames
      .at(-1)
      .cancellations.every((v) => v.reason === "discontinuity"),
  );
  assert.ok(transit.frames.every((v) => v.passages.length === 0));
  closeNumeric(transit.frames, native("--transit", [source, ...measurements]));
});

test("projection replacement stays pure with all 64 persistent measurement handles occupied", () => {
  const { header, frames } = fixture(),
    config = JSON.parse(JSON.parse(header.analysis).measurement),
    handles = [];
  try {
    for (let i = 0; i < 64; i++)
      handles.push(unpack(moonground_create(line(config))).handle);
    const expected = browser(header, frames);
    const actual = browser(header, frames);
    closeNumeric(actual, expected);
    assert.equal(
      actual.frames.filter((v) => v.kind === "guarded_projection_replaced")
        .length,
      4,
    );
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
});
