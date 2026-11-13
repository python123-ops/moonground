import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_evidence_guarded_transit,
  moonground_evidence_transit_analysis,
  moonground_health,
  moonground_transit_windows,
  moonground_evidence_guarded_transit_window,
  moonground_evidence_transit_window_analysis,
  moonground_create,
  moonground_close,
} from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.env.MOONGROUND_CLI
  ? path.resolve(root, process.env.MOONGROUND_CLI)
  : ["main.exe", "main"]
      .map((v) => path.join(root, "_build/native/release/build/cmd/main", v))
      .find(existsSync);
assert.ok(binary, "Build the native CLI before evidence-guarded verification.");
const clone = (v) => JSON.parse(JSON.stringify(v)),
  line = (v) => (typeof v === "string" ? v : JSON.stringify(v));
const ndjson = (records) =>
  records.map(line).join("\n") + (records.length ? "\n" : "");
const pair = (analysis, health) => ({
  analysis: line(analysis),
  health: line(health),
});
const combine = (analysis, health) => ({
  format: "moonground.evidence-guarded-transit",
  checkpoint_version: "1",
  analysis,
  health,
});
const objectFrame = (t, observations = [], removed = []) => ({
  timestamp_us: String(t),
  observations,
  lost: [],
  removed,
});
const wrap = (measurement, health) => ({
  measurement: line(measurement),
  health: line(health),
});
const replacement = (t, calibration, camera) => ({
  replace_projection: line({ timestamp_us: String(t), calibration, camera }),
});
const unpack = (text) => {
  const v = JSON.parse(text);
  assert.equal(v.error, undefined, text.slice(0, 1500));
  return v;
};
const failure = (text) => {
  const v = JSON.parse(text);
  assert.equal(typeof v.error, "string", text.slice(0, 1500));
  assert.deepEqual(
    Object.keys(v),
    ["error"],
    "pure failure exposed partial data",
  );
  return v.error;
};
const invoke = (source, observations) =>
  moonground_evidence_guarded_transit(
    JSON.stringify({ source: line(source), observations }),
  );
const browser = (source, frames = []) =>
  unpack(invoke(source, typeof frames === "string" ? frames : ndjson(frames)));
const healthBatch = (source, frames = []) =>
  unpack(
    moonground_health(
      JSON.stringify({ source: line(source), observations: ndjson(frames) }),
    ),
  );
const analysisBatch = (source, frames = []) =>
  unpack(
    moonground_evidence_transit_analysis(
      JSON.stringify({ source: line(source), observations: ndjson(frames) }),
    ),
  );
function native(mode, records, status = 0) {
  const run = spawnSync(binary, [mode], {
    input: ndjson(records),
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    timeout: 120000,
  });
  assert.equal(run.status, status, run.stderr || run.error?.message);
  if (!status) assert.equal(run.stderr, "");
  if (run.stdout)
    assert.ok(run.stdout.endsWith("\n"), "partial native output line");
  if (status && mode.endsWith("checkpoint")) assert.equal(run.stdout, "");
  return run.stdout ? run.stdout.trimEnd().split("\n").map(JSON.parse) : [];
}
function close(actual, expected, where = "$") {
  if (typeof expected === "number") {
    assert.equal(typeof actual, "number", where);
    assert.ok(Number.isFinite(actual), where);
    if (
      /\.(track_id|accepted_count|streak_observations|usable_count|max_tracks|min_observations)$/.test(
        where,
      )
    )
      assert.equal(actual, expected, where);
    else
      assert.ok(
        Math.abs(actual - expected) <= 2e-8 * Math.max(1, Math.abs(expected)),
        `${where}: ${actual} != ${expected}`,
      );
  } else if (Array.isArray(expected)) {
    assert.equal(actual.length, expected.length, where);
    expected.forEach((v, i) => close(actual[i], v, `${where}[${i}]`));
  } else if (expected && typeof expected === "object") {
    assert.deepEqual(
      Object.keys(actual).sort(),
      Object.keys(expected).sort(),
      where,
    );
    for (const key of Object.keys(expected))
      close(actual[key], expected[key], `${where}.${key}`);
  } else assert.equal(actual, expected, where);
}
function calibration(i = 0) {
  return {
    matrix: i
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
function camera(i = 0) {
  return {
    fx: 400 + i * 170,
    fy: 420 + i * 110,
    cx: i * 10,
    cy: i * 20,
    k1: 0.08 - i * 0.12,
    k2: -0.01,
    k3: 0.001,
    p1: 0.0002,
    p2: -0.0003,
    max_normalized_radius: 0.8,
  };
}
function pixel(config, world) {
  const h = config.calibration.matrix,
    p = [(world[0] - h[2]) / h[0], (world[1] - h[5]) / h[4]];
  if (!config.camera) return p;
  const c = config.camera,
    x = (p[0] - c.cx) / c.fx,
    y = (p[1] - c.cy) / c.fy,
    r2 = x * x + y * y,
    r = 1 + c.k1 * r2 + c.k2 * r2 * r2 + c.k3 * r2 * r2 * r2;
  return [
    c.fx * (x * r + 2 * c.p1 * x * y + c.p2 * (r2 + 2 * x * x)) + c.cx,
    c.fy * (y * r + c.p1 * (r2 + 2 * y * y) + 2 * c.p2 * x * y) + c.cy,
  ];
}
function fixture(start = 9007199254740993n) {
  const measurement = {
    session_id: "evidence-guarded-browser",
    mode: "pixel",
    diagnostics: true,
    calibration: calibration(),
    motion: {
      max_tracks: 8,
      max_gap_us: "500000",
      min_observations: 2,
      min_span_us: "100000",
      initial_velocity_std: 10,
      gate: 1e9,
      q: 5,
    },
  };
  const health = {
    monitor_id: "evidence-guarded-landmarks",
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
      confirmation_us: "200000",
      min_observations: 3,
      max_gap_us: "500000",
      max_position_std_m: 0.3,
    },
  };
  const gateConfig = {
    session_id: measurement.session_id,
    gates: [
      {
        gate_id: "interval-exit",
        start_m: [-100, 2.5],
        end_m: [100, 2.5],
        deadband_m: 0.005,
      },
      {
        gate_id: "horizontal",
        start_m: [-100, 2],
        end_m: [100, 2],
        deadband_m: 0.005,
      },
    ],
    max_tracks: 8,
    max_gap_us: "500000",
  };
  const analysis = {
      measurement: line(measurement),
      transit: line({
        counting: line({ counting: line(gateConfig), sigma_multiplier: 3.5 }),
        sections: [
          {
            section_id: "aisle",
            entry_gate_id: "horizontal",
            entry_direction: "negative_to_positive",
            exit_gate_id: "interval-exit",
            exit_direction: "negative_to_positive",
          },
        ],
        max_duration_us: "300000000",
      }),
    },
    header = pair(analysis, health);
  let current = clone(health),
    stamp = start;
  const frames = [];
  function observed(i) {
    const fixed = current.landmarks.map((v) => ({
      landmark_id: v.landmark_id,
      point: pixel(current, v.ground_m),
      covariance: [0.04, 0.008, 0.09],
    }));
    const objects =
      i === 4
        ? []
        : [2, 1].map((track_id) => ({
            track_id,
            point: pixel(current, [1 + track_id * 0.1, i < 3 ? 1 : 3]),
            covariance: [0.04, 0.008, 0.09],
          }));
    frames.push(
      wrap(objectFrame(stamp, objects), {
        timestamp_us: String(stamp),
        observations: fixed,
      }),
    );
    stamp += 100000n;
  }
  for (const [next, brown] of [
    [calibration(1), camera()],
    [calibration(), camera(1)],
    [calibration(), null],
    [calibration(), null],
  ]) {
    for (let i = 0; i < 5; i++) observed(i);
    frames.push(replacement(stamp, next, brown));
    stamp += 100000n;
    current.calibration = clone(next);
    if (brown) current.camera = clone(brown);
    else delete current.camera;
  }
  for (let i = 0; i < 5; i++) observed(i);
  return { header, frames };
}
function changeProjection(target, source) {
  target.calibration = clone(source.calibration);
  if (source.camera) target.camera = clone(source.camera);
  else delete target.camera;
}
function independent(header, frames) {
  let a = analysisBatch(JSON.parse(header.analysis)).checkpoint;
  let h = healthBatch(JSON.parse(header.health)).checkpoint;
  const outputs = [];
  for (const value of frames) {
    const replacing = "replace_projection" in value;
    let objects, landmarks, healthSource;
    if (replacing) {
      const control = JSON.parse(value.replace_projection),
        config = clone(h.configuration);
      changeProjection(config, control);
      healthSource = config;
      objects = objectFrame(control.timestamp_us);
      landmarks = { timestamp_us: control.timestamp_us, observations: [] };
    } else {
      objects = JSON.parse(value.measurement);
      landmarks = JSON.parse(value.health);
      healthSource = { resume: h };
    }
    const nh = healthBatch(healthSource, [landmarks]),
      report = nh.frames[0];
    const allowed = !replacing && report.status === "healthy";
    const effective = allowed
      ? objects
      : objectFrame(
          objects.timestamp_us,
          [],
          a.measurement.motion.tracks
            .map((v) => v.track_id)
            .sort((x, y) => x - y),
        );
    const next = analysisBatch({ resume: a }, [effective]);
    if (replacing)
      changeProjection(
        next.checkpoint.measurement.configuration,
        nh.checkpoint.configuration,
      );
    outputs.push({
      schema_version: "0.1.0",
      kind: replacing
        ? "evidence_guarded_transit_projection_replaced"
        : "evidence_guarded_transit_frame",
      decision: allowed ? "allowed" : "blocked",
      suppressed_track_ids:
        allowed || replacing
          ? []
          : objects.observations.map((v) => v.track_id).sort((x, y) => x - y),
      health: report,
      analysis: next.frames[0],
    });
    a = next.checkpoint;
    h = nh.checkpoint;
  }
  return { frames: outputs, checkpoint: combine(a, h) };
}

const MAX = 9223372036854775807n;
const reasons = [
  "discontinuity",
  "expired",
  "reentered",
  "reversed",
  "ambiguous_order",
];
const windowSource = (
  transit,
  width = 250000n,
  limits = [0n, 1n, 100000n, 200000n, 300000n, MAX],
  origin = 0n,
) => ({
  transit: line(transit),
  window_us: String(width),
  duration_limits_us: limits.map(String),
  origin_us: String(origin),
});
const invokeWindows = (source, transits) =>
  moonground_transit_windows(
    JSON.stringify({ source: line(source), transits }),
  );
const windows = (source, frames = []) =>
  unpack(
    invokeWindows(source, typeof frames === "string" ? frames : ndjson(frames)),
  );
const timestamp = (value) => BigInt(value.counting.counting.timestamp_us);

function recount(frames, source, sections) {
  const width = BigInt(source.window_us),
    origin = BigInt(source.origin_us ?? "0");
  const first = timestamp(frames[0]),
    last = timestamp(frames.at(-1));
  const start = origin + ((first - origin) / width) * width;
  return {
    start_us: String(start),
    end_exclusive_us: start + width <= MAX ? String(start + width) : null,
    first_timestamp_us: String(first),
    last_timestamp_us: String(last),
    input_frames: String(frames.length),
    sections: sections.map((section) => {
      const passages = frames
        .flatMap((frame) => frame.passages)
        .filter((item) => item.section_id === section.section_id);
      const cancellations = frames
        .flatMap((frame) => frame.cancellations)
        .filter((item) => item.section_id === section.section_id);
      return {
        section_id: section.section_id,
        completed: String(passages.length),
        duration_limits: source.duration_limits_us.map((limit) => {
          const within = passages.filter(
            (item) => BigInt(item.elapsed_upper_us) <= BigInt(limit),
          ).length;
          const exceeded = passages.filter(
            (item) => BigInt(item.elapsed_lower_us) > BigInt(limit),
          ).length;
          return {
            limit_us: limit,
            within: String(within),
            exceeded: String(exceeded),
            indeterminate: String(passages.length - within - exceeded),
          };
        }),
        cancellations: reasons.map((reason) => ({
          reason,
          count: String(
            cancellations.filter((item) => item.reason === reason).length,
          ),
        })),
      };
    }),
  };
}

function offline(frames, source, sections, session_id) {
  const groups = new Map(),
    output = [];
  const width = BigInt(source.window_us),
    origin = BigInt(source.origin_us ?? "0");
  let previous;
  for (const frame of frames) {
    const time = timestamp(frame),
      index = (time - origin) / width;
    let closed_window = null,
      unobserved_windows = 0n;
    if (!groups.has(index)) {
      if (previous !== undefined) {
        closed_window = recount(groups.get(previous), source, sections);
        unobserved_windows = index - previous - 1n;
      }
      groups.set(index, []);
      previous = index;
    }
    groups.get(index).push(frame);
    output.push({
      schema_version: "0.1.0",
      kind: "evidence_transit_window_frame",
      session_id,
      timestamp_us: String(time),
      closed_window,
      current_window: recount(groups.get(index), source, sections),
      unobserved_windows: String(unobserved_windows),
      classification_scope: "observed_chord_elapsed_bounds",
    });
  }
  return output;
}

const strategy = (width = 250000n, origin = 0n) => ({
  window_us: String(width),
  origin_us: String(origin),
  duration_limits_us: [0n, 1n, 100000n, 200000n, 300000n, MAX].map(String),
});
const joined = (guarded, windows = strategy()) => ({
  guarded: line(guarded),
  windows: line(windows),
});
const jointCP = (guarded, windows) => ({
  format: "moonground.evidence-guarded-transit-windows",
  checkpoint_version: "1",
  guarded,
  windows,
});
const invokeJoint = (source, observations) =>
  moonground_evidence_guarded_transit_window(
    JSON.stringify({ source: line(source), observations }),
  );
const joint = (source, observations = []) =>
  unpack(
    invokeJoint(
      source,
      typeof observations === "string" ? observations : ndjson(observations),
    ),
  );
const rawRestore = (checkpoint) =>
  unpack(
    moonground_evidence_transit_window_analysis(
      JSON.stringify({
        source: line({
          resume: {
            format: "moonground.evidence-transit-window-analysis",
            checkpoint_version: "1",
            analysis: checkpoint.guarded.analysis,
            windows: checkpoint.windows,
          },
        }),
        observations: "",
      }),
    ),
  );
function host(guarded, config, frames) {
  const initial = browser(guarded).checkpoint,
    output = browser(guarded, frames);
  const transits = output.frames.map((value) => value.analysis.transit);
  const header =
    "resume" in config
      ? config
      : { ...config, transit: line({ resume: initial.analysis.transit }) };
  const grouped = windows(header, transits);
  if (!("resume" in config))
    assert.deepEqual(
      grouped.frames,
      offline(
        transits,
        config,
        initial.analysis.transit.sections,
        initial.analysis.transit.counting.configuration.counting.session_id,
      ),
    );
  return {
    frames: output.frames.map((guarded, index) => ({
      schema_version: "0.1.0",
      kind: "evidence_guarded_transit_window_frame",
      guarded,
      windows: grouped.frames[index],
    })),
    checkpoint: jointCP(output.checkpoint, grouped.checkpoint),
  };
}
function healthFixture(times, minimum = 1, gap = 10, insufficient = []) {
  const sample = fixture(0n),
    config = JSON.parse(sample.header.health),
    analysis = JSON.parse(sample.header.analysis);
  Object.assign(config.health, {
    min_observations: minimum,
    confirmation_us: "0",
    max_gap_us: String(gap),
  });
  const frames = times.map((t) =>
    wrap(objectFrame(BigInt(t)), {
      timestamp_us: String(t),
      observations: insufficient.includes(t)
        ? []
        : config.landmarks.map((value) => ({
            landmark_id: value.landmark_id,
            point: pixel(config, value.ground_m),
          })),
    }),
  );
  return { header: pair(analysis, config), frames, config };
}

test("health-controlled windows equal old guarded then old windows and integer grouping", () => {
  const sample = fixture();
  const actual = joint(joined(sample.header), sample.frames),
    expected = host(sample.header, strategy(), sample.frames);
  assert.deepEqual(actual, expected);
  const nativeFrames = native("--guarded-transit-windows", [
    joined(sample.header),
    ...sample.frames,
  ]);
  close(nativeFrames, actual.frames);
  assert.deepEqual(
    nativeFrames.map((v) => v.windows),
    actual.frames.map((v) => v.windows),
  );
  close(
    native("--guarded-transit-windows-checkpoint", [
      joined(sample.header),
      ...sample.frames,
    ])[0],
    actual.checkpoint,
  );
  const barriers = actual.frames.filter(
    (v) => v.guarded.kind === "evidence_guarded_transit_projection_replaced",
  );
  assert.equal(barriers.length, 4);
  for (const value of barriers) {
    assert.equal(value.guarded.health.status, "insufficient");
    assert.equal(value.guarded.analysis.transit.pending_count, 0);
  }
});

test("all cut points include health confirmations and projection barriers in four runtime directions", (context) => {
  const sample = fixture(),
    header = joined(sample.header),
    complete = joint(header, sample.frames);
  let cuts = 0,
    continuations = 0;
  for (let cut = 0; cut <= sample.frames.length; cut++) {
    const n = native("--guarded-transit-windows-checkpoint", [
        header,
        ...sample.frames.slice(0, cut),
      ])[0],
      w = joint(header, sample.frames.slice(0, cut)).checkpoint;
    close(n, w);
    for (const saved of [n, w]) {
      close(joint({ resume: saved }, sample.frames.slice(cut)), {
        frames: complete.frames.slice(cut),
        checkpoint: complete.checkpoint,
      });
      close(
        joint(
          joined({ resume: saved.guarded }, { resume: saved.windows }),
          sample.frames.slice(cut),
        ),
        { frames: complete.frames.slice(cut), checkpoint: complete.checkpoint },
      );
      close(
        native("--guarded-transit-windows", [
          { resume: saved },
          ...sample.frames.slice(cut),
        ]),
        complete.frames.slice(cut),
      );
      close(
        native("--guarded-transit-windows-checkpoint", [
          { resume: saved },
          ...sample.frames.slice(cut),
        ])[0],
        complete.checkpoint,
      );
      continuations += 2;
    }
    cuts++;
  }
  context.diagnostic(
    JSON.stringify({
      cut_points: cuts,
      continuations,
      directions: [
        "native_to_native",
        "native_to_javascript",
        "javascript_to_native",
        "javascript_to_javascript",
      ],
    }),
  );
});

test("independent components cannot hide health samples or restart gaps in window state", () => {
  const incompatible = (value) => {
    browser({ resume: value.guarded });
    rawRestore(value);
    failure(invokeJoint({ resume: value }, ""));
    native("--guarded-transit-windows-checkpoint", [{ resume: value }], 2);
  };
  let sample = healthFixture([0, 8, 16, 20]),
    value = joint(
      joined(sample.header, strategy(100n)),
      sample.frames,
    ).checkpoint;
  Object.assign(value.windows.current_window, {
    first_timestamp_us: "8",
    input_frames: "3",
  });
  incompatible(value);
  Object.assign(value.windows, { origin_us: "1" });
  Object.assign(value.windows.current_window, {
    start_us: "1",
    end_exclusive_us: "101",
  });
  incompatible(value);
  sample = healthFixture([0, 9, 18]);
  value = joint(
    joined(sample.header, strategy(100n)),
    sample.frames,
  ).checkpoint;
  value.windows.current_window.input_frames = "2";
  incompatible(value);
  sample = healthFixture([...Array.from({ length: 14 }, (_, i) => i * 9), 118]);
  value = joint(
    joined(sample.header, strategy(100n)),
    sample.frames,
  ).checkpoint;
  value.windows.current_window.first_timestamp_us = "109";
  incompatible(value);
  sample = healthFixture([0, 2, 6, 10], 3, 100, [0]);
  value = joint(
    joined(sample.header, strategy(100n)),
    sample.frames,
  ).checkpoint;
  value.windows.current_window.input_frames = "3";
  incompatible(value);
  sample = healthFixture([0, 2], 4);
  value = joint(
    joined(sample.header, strategy(100n)),
    sample.frames,
  ).checkpoint;
  value.windows.current_window.input_frames = "3";
  incompatible(value);
  sample = healthFixture([0, 9, 18], 5);
  value = joint(joined(sample.header, strategy(10n)), sample.frames).checkpoint;
  Object.assign(value.windows.current_window, {
    first_timestamp_us: "17",
    input_frames: "2",
  });
  incompatible(value);
  sample = healthFixture([0, 2, 6], 4, 10, [0]);
  value = joint(
    joined(sample.header, strategy(100n)),
    sample.frames,
  ).checkpoint;
  value.windows.current_window.input_frames = "5";
  incompatible(value);
});

test("preexisting health before origin and exact Int64 clock gaps remain resumable", () => {
  const sample = healthFixture([0, 8, 16, 20]);
  const initial = browser(sample.header, sample.frames.slice(0, 2)).checkpoint;
  assert.equal(initial.health.state.streak.since_us, "0");
  const header = joined({ resume: initial }, strategy(100n, 1n));
  assert.equal(joint(header).checkpoint.windows.current_window, null);
  assert.deepEqual(
    joint(header, sample.frames.slice(2)),
    host({ resume: initial }, strategy(100n, 1n), sample.frames.slice(2)),
  );
  for (const start of [9007199254740993n, MAX - 2n]) {
    const tiny = healthFixture([0, 1, 2], 1, 1);
    for (let i = 0; i < tiny.frames.length; i++) {
      for (const key of ["measurement", "health"]) {
        const value = JSON.parse(tiny.frames[i][key]);
        value.timestamp_us = String(start + BigInt(i));
        tiny.frames[i][key] = line(value);
      }
    }
    const actual = joint(joined(tiny.header, strategy(1n)), tiny.frames);
    assert.equal(actual.frames.at(-1).windows.timestamp_us, String(start + 2n));
    if (start === MAX - 2n)
      assert.equal(
        actual.frames.at(-1).windows.current_window.end_exclusive_us,
        null,
      );
    assert.deepEqual(actual, host(tiny.header, strategy(1n), tiny.frames));
  }
});

test("blocked origin failure and first Healthy arithmetic failure discard health and window candidates", () => {
  const sample = fixture(0n),
    header = joined(sample.header, strategy(250000n, 100n)),
    initial = joint(header).checkpoint;
  const early = clone(sample.frames[0]);
  for (const key of ["measurement", "health"]) {
    const v = JSON.parse(early[key]);
    v.timestamp_us = "99";
    early[key] = line(v);
  }
  failure(invokeJoint(header, ndjson([early])));
  for (const key of ["measurement", "health"]) {
    const v = JSON.parse(early[key]);
    v.timestamp_us = "100";
    early[key] = line(v);
  }
  const after = joint({ resume: initial }, [early]);
  assert.equal(after.checkpoint.guarded.health.state.streak.observations, 1);
  assert.equal(after.checkpoint.windows.current_window.input_frames, "1");
  const old = JSON.parse(sample.header.analysis),
    transit = JSON.parse(old.transit),
    evidence = JSON.parse(transit.counting);
  evidence.sigma_multiplier = 1e308;
  transit.counting = line(evidence);
  old.transit = line(transit);
  const huge = joined(pair(old, JSON.parse(sample.header.health)));
  const pending = joint(huge, sample.frames.slice(0, 2)).checkpoint;
  const invalid = clone(sample.frames[2]),
    obj = JSON.parse(invalid.measurement);
  for (const observation of obj.observations)
    observation.covariance = [1e6, 0, 1e6];
  invalid.measurement = line(obj);
  failure(invokeJoint({ resume: pending }, ndjson([invalid])));
  const fixed = joint({ resume: pending }, sample.frames.slice(2, 3));
  assert.equal(fixed.checkpoint.guarded.health.state.streak.observations, 3);
  assert.equal(
    fixed.checkpoint.guarded.analysis.measurement.motion.tracks[0].segment_id,
    "1",
  );
  assert.equal(fixed.checkpoint.windows.current_window.input_frames, "3");
  const invalidBody = clone(sample.frames[0]);
  const raw = JSON.parse(invalidBody.measurement);
  raw.observations[0].covariance = [1, 2, 1];
  invalidBody.measurement = line(raw);
  failure(invokeJoint(joined(sample.header), ndjson([invalidBody])));
});

test("warm Brown reframe preserves health, pending entries and the entire window aggregate", () => {
  const sample = fixture(0n),
    cut = 10;
  const old = JSON.parse(sample.header.analysis),
    transit = JSON.parse(old.transit),
    policy = JSON.parse(transit.counting),
    gateConfig = JSON.parse(policy.counting);
  gateConfig.gates[0].start_m[1] = 6;
  gateConfig.gates[0].end_m[1] = 6;
  policy.counting = line(gateConfig);
  transit.counting = line(policy);
  old.transit = line(transit);
  sample.header = pair(old, JSON.parse(sample.header.health));
  const saved = joint(
    joined(sample.header),
    sample.frames.slice(0, cut),
  ).checkpoint;
  assert.equal(saved.guarded.analysis.transit.pending.length, 2);
  const future = clone(sample.frames.slice(cut));
  const first = JSON.parse(future[0].measurement),
    config = clone(saved.guarded.health.configuration);
  first.observations = [1, 2].map((track_id) => ({
    track_id,
    point: pixel(config, [track_id === 1 ? 1 : 3, 7]),
    covariance: [0.01, 0, 0.01],
  }));
  future[0].measurement = line(first);
  const baseline = joint({ resume: saved }, future),
    transform = { scale_x: 0.5, scale_y: 1.25, offset_x: -15, offset_y: 8 };
  const converted = native("--reframe", [
    { source: { resume: saved.guarded.analysis.measurement }, transform },
    ...future
      .filter((v) => !("replace_projection" in v))
      .slice(0, 1)
      .map((v) => JSON.parse(v.measurement)),
  ]);
  const changed = clone(saved);
  changed.guarded.analysis.measurement = converted[0].resume;
  changed.guarded.health.configuration.calibration = clone(
    converted[0].resume.configuration.calibration,
  );
  if (converted[0].resume.configuration.camera)
    changed.guarded.health.configuration.camera = clone(
      converted[0].resume.configuration.camera,
    );
  else delete changed.guarded.health.configuration.camera;
  const h = JSON.parse(future[0].health);
  for (const row of h.observations) {
    row.point = [row.point[0] * 0.5 - 15, row.point[1] * 1.25 + 8];
    const [xx, xy, yy] = row.covariance ?? [4, 0, 4];
    row.covariance = [xx * 0.25, xy * 0.5 * 1.25, yy * 1.25 ** 2];
  }
  const actual = joint({ resume: changed }, [wrap(converted[1], h)]);
  close(actual.frames[0], baseline.frames[0]);
  assert.deepEqual(actual.frames[0].windows, baseline.frames[0].windows);
  assert.deepEqual(changed.windows, saved.windows);
  assert.deepEqual(changed.guarded.health.state, saved.guarded.health.state);
  assert.deepEqual(
    changed.guarded.analysis.transit,
    saved.guarded.analysis.transit,
  );
});

test("bounded batches preserve frame limits and whole-result limits without handles", (context) => {
  const sample = healthFixture([0]),
    config = JSON.parse(sample.header.health);
  config.landmarks = config.landmarks.slice(0, 1);
  config.health.min_landmarks = 1;
  const old = pair(JSON.parse(sample.header.analysis), config),
    strategyOne = strategy(MAX);
  strategyOne.duration_limits_us = [String(MAX)];
  const header = joined(old, strategyOne),
    initial = joint(header);
  const exact = line({ resume: initial.checkpoint }).padEnd(8388619, " ");
  assert.deepEqual(joint(exact).checkpoint, initial.checkpoint);
  failure(invokeJoint(exact + " ", ""));
  const exactConfig = line(strategyOne).padEnd(1048576, " ");
  assert.equal(joint(joined(old, exactConfig)).frames.length, 0);
  failure(invokeJoint(joined(old, exactConfig + " "), ""));
  const empty = (t) =>
    wrap(objectFrame(BigInt(t)), { timestamp_us: String(t), observations: [] });
  const frameLine = line(empty(0)).padEnd(1048576, " ");
  assert.equal(joint(header, frameLine).frames.length, 1);
  failure(invokeJoint(header, frameLine + " "));
  const batch = Array.from(
    { length: 8 },
    (_, i) => line(empty(i)).padEnd(1048575, " ") + "\n",
  ).join("");
  assert.equal(batch.length, 8388608);
  assert.equal(joint(header, batch).frames.length, 8);
  failure(invokeJoint(header, batch + " "));
  const frames = Array.from({ length: 5000 }, (_, i) => empty(i)),
    measured = invokeJoint(header, ndjson(frames.slice(0, 2000)));
  assert.equal(unpack(measured).frames.length, 2000);
  assert.match(failure(invokeJoint(header, ndjson(frames))), /output.*8388608/);
  assert.match(
    failure(invokeJoint(header, ndjson([...frames, empty(5000)]))),
    /batch exceeds 5000 frames/,
  );
  context.diagnostic(
    JSON.stringify({
      successful_empty_frames: 2000,
      complete_return_utf16_units: measured.length,
      five_thousand_input_rejection: "output_budget",
      five_thousand_one_rejection: "frame_count_budget",
    }),
  );
  const request = JSON.stringify({
    source: line(header),
    observations: "",
  }).padEnd(16777216, " ");
  unpack(moonground_evidence_guarded_transit_window(request));
  failure(moonground_evidence_guarded_transit_window(request + " "));
  failure(
    moonground_evidence_guarded_transit_window(
      JSON.stringify({ source: line(header), observations: "", extra: true }),
    ),
  );
  failure(invokeJoint('{"guarded":"bad",' + line(header).slice(1), ""));
  const handles = [];
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(
            JSON.stringify({
              session_id: `health-window-${i}`,
              mode: "ground",
            }),
          ),
        ).handle,
      );
    failure(moonground_create('{"session_id":"full","mode":"ground"}'));
    assert.equal(joint(header).frames.length, 0);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
});
