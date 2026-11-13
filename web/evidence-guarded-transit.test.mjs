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
  if (status && mode === "--guarded-transit-evidence-checkpoint")
    assert.equal(run.stdout, "");
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

test("health and atomic transit match the two independently staged existing owners", () => {
  const { header, frames } = fixture(),
    actual = browser(header, frames);
  close(actual, independent(header, frames));
  close(
    actual.frames,
    native("--guarded-transit-evidence", [header, ...frames]),
  );
  close(
    actual.checkpoint,
    native("--guarded-transit-evidence-checkpoint", [header, ...frames])[0],
  );
  assert.equal(
    actual.frames.filter(
      (v) => v.kind === "evidence_guarded_transit_projection_replaced",
    ).length,
    4,
  );
  for (let i = 0; i < actual.frames.length; i++)
    if (
      actual.frames[i].kind === "evidence_guarded_transit_projection_replaced"
    ) {
      const barrier = actual.frames[i];
      assert.equal(barrier.decision, "blocked");
      assert.deepEqual(barrier.suppressed_track_ids, []);
      assert.deepEqual(barrier.analysis.transit.counting.evidence, []);
      assert.equal(barrier.analysis.measurement.closed_segment_ids.length, 2);
      assert.equal(barrier.health.status, "insufficient");
      assert.equal(actual.frames[i + 1].decision, "blocked");
      assert.equal(actual.frames[i + 2].decision, "blocked");
      assert.equal(actual.frames[i + 3].decision, "allowed");
      assert.ok(
        actual.frames[i + 3].analysis.measurement.tracks.every(
          (v) => v.status === "initializing" && v.speed_mps === null,
        ),
      );
    }
  assert.equal(
    actual.checkpoint.analysis.transit.counting.configuration.sigma_multiplier,
    3.5,
  );
  assert.equal(actual.checkpoint.health.configuration.camera, undefined);
});

test("all cuts across camera additions, removal and equal replacement restore in four runtime directions", (t) => {
  const { header, frames } = fixture(),
    expected = browser(header, frames);
  let continuations = 0;
  for (let cut = 0; cut <= frames.length; cut++) {
    const before = frames.slice(0, cut),
      after = frames.slice(cut),
      saves = [
        native("--guarded-transit-evidence-checkpoint", [header, ...before])[0],
        browser(header, before).checkpoint,
      ];
    close(saves[0], saves[1]);
    for (const saved of saves) {
      const resume = { resume: saved },
        actual = browser(resume, after);
      close(actual.frames, expected.frames.slice(cut));
      close(actual.checkpoint, expected.checkpoint);
      continuations++;
      close(
        native("--guarded-transit-evidence", [resume, ...after]),
        expected.frames.slice(cut),
      );
      close(
        native("--guarded-transit-evidence-checkpoint", [resume, ...after])[0],
        expected.checkpoint,
      );
      continuations++;
      close(
        browser(
          pair({ resume: saved.analysis }, { resume: saved.health }),
          after,
        ),
        actual,
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

test("the first Healthy candidate is discarded when late normal arithmetic fails", () => {
  const { header, frames } = fixture(0n),
    changed = clone(header),
    definition = JSON.parse(changed.analysis),
    transit = JSON.parse(definition.transit),
    policy = JSON.parse(transit.counting);
  policy.sigma_multiplier = 1e308;
  transit.counting = line(policy);
  definition.transit = line(transit);
  changed.analysis = line(definition);
  const pending = browser(changed, frames.slice(0, 2)).checkpoint,
    bad = clone(frames[2]),
    obj = JSON.parse(bad.measurement);
  for (const v of obj.observations) v.covariance = [1e6, 0, 1e6];
  bad.measurement = line(obj);
  const candidate = healthBatch({ resume: pending.health }, [
    JSON.parse(bad.health),
  ]);
  assert.equal(candidate.frames[0].status, "healthy");
  assert.equal(pending.health.state.streak.observations, 2);
  failure(invoke({ resume: pending }, ndjson([bad])));
  native(
    "--guarded-transit-evidence-checkpoint",
    [{ resume: pending }, bad],
    2,
  );
  const corrected = browser({ resume: pending }, [frames[2]]);
  assert.equal(corrected.frames[0].decision, "allowed");
  assert.equal(corrected.checkpoint.health.state.streak.observations, 3);
  assert.equal(
    corrected.checkpoint.analysis.measurement.motion.next_segment_id,
    "3",
  );
  assert.equal(pending.analysis.measurement.motion.next_segment_id, "1");
});

test("blocked payloads validate raw identities and SPD while skipping projection and evidence", () => {
  const { header, frames } = fixture(0n),
    ignored = clone(frames[1]),
    obj = JSON.parse(ignored.measurement);
  for (const v of obj.observations) {
    v.point = [1e308, -1e308];
    v.covariance = [1e300, 0, 1e300];
  }
  ignored.measurement = line(obj);
  const actual = browser(header, [frames[0], ignored]).frames[1];
  assert.deepEqual(actual.suppressed_track_ids, [1, 2]);
  assert.deepEqual(actual.analysis.measurement.tracks, []);
  assert.deepEqual(actual.analysis.transit.counting.evidence, []);
  for (const mutate of [
    (v) => v.observations.push(clone(v.observations[0])),
    (v) => (v.lost = [1]),
    (v) => (v.observations[0].covariance = [1, 2, 1]),
  ]) {
    const bad = clone(obj);
    mutate(bad);
    failure(
      invoke(
        header,
        ndjson([frames[0], wrap(bad, JSON.parse(frames[1].health))]),
      ),
    );
  }
  const raw = line(obj).replace(
    '"track_id":2',
    '"track_id":2.0000000000000001',
  );
  failure(
    invoke(
      header,
      ndjson([frames[0], { measurement: raw, health: frames[1].health }]),
    ),
  );
});

test("projection identity, health binding, canonical fields and raw control errors return no partial result", () => {
  const { header, frames } = fixture(0n),
    saved = browser(header, frames.slice(0, 4)).checkpoint;
  for (const mutate of [
    (v) => (v.health.state.last_timestamp_us = "300001"),
    (v) => (v.health.configuration.calibration.matrix[2] = 0.1),
    (v) => v.health.configuration.calibration.roi.reverse(),
    (v) => (v.health.state.streak = null),
    (v) => (v.health.state.streak.since_us = "100000"),
    (v) => delete v.analysis.transit.counting.configuration.sigma_multiplier,
    (v) =>
      delete v.analysis.transit.counting.configuration.counting.gates[0]
        .deadband_m,
  ]) {
    const bad = clone(saved);
    mutate(bad);
    failure(invoke({ resume: bad }, ""));
  }
  const control = JSON.parse(frames[5].replace_projection),
    missing = clone(control);
  delete missing.camera;
  for (const bad of [
    { replace_projection: line(missing) },
    { ...frames[5], measurement: frames[0].measurement },
    '{"replace_projection":"bad",' + line(frames[5]).slice(1),
    { replace_projection: '{"camera":null,' + line(control).slice(1) },
  ]) {
    failure(invoke(header, ndjson([...frames.slice(0, 5), bad])));
    native(
      "--guarded-transit-evidence-checkpoint",
      [header, ...frames.slice(0, 5), bad],
      2,
    );
  }
  const correction = browser({ resume: saved }, frames.slice(4, 6));
  close(correction.checkpoint, browser(header, frames.slice(0, 6)).checkpoint);
});

test("source, raw frame, total input, frame count, wrapper and final checkpoint output budgets remain independent", () => {
  const { header } = fixture(0n),
    small = clone(header),
    health = JSON.parse(small.health);
  health.landmarks = health.landmarks.slice(0, 1);
  health.health.min_landmarks = 1;
  small.health = line(health);
  const empty = (i) =>
      wrap(objectFrame(i), { timestamp_us: String(i), observations: [] }),
    saved = browser(small).checkpoint;
  const resume = line({ resume: saved }).padEnd(8388619, " ");
  close(browser(resume).checkpoint, saved);
  failure(invoke(resume + " ", ""));
  const exact = line(empty(0)).padEnd(1048576, " ");
  assert.equal(browser(small, exact + "\n").frames.length, 1);
  failure(invoke(small, exact + " \n"));
  const input = Array.from(
    { length: 8 },
    (_, i) => line(empty(i)).padEnd(1048575, " ") + "\n",
  ).join("");
  assert.equal(input.length, 8388608);
  assert.equal(browser(small, input).frames.length, 8);
  failure(invoke(small, input + " "));
  const frames = Array.from({ length: 5000 }, (_, i) => empty(i));
  assert.equal(browser(small, frames).frames.length, 5000);
  failure(invoke(small, ndjson([...frames, empty(5000)])));
  const request = JSON.stringify({
    source: line(small),
    observations: "",
  }).padEnd(16777216, " ");
  unpack(moonground_evidence_guarded_transit(request));
  failure(moonground_evidence_guarded_transit(request + " "));
  let selected, source;
  for (let width = 1; width <= 128 && !selected; width++) {
    source = clone(small);
    const analysis = JSON.parse(source.analysis),
      transit = JSON.parse(analysis.transit),
      counter = JSON.parse(transit.counting),
      gateConfig = JSON.parse(counter.counting),
      original = gateConfig.gates[0];
    gateConfig.gates = Array.from({ length: 16 }, (_, i) => ({
      ...original,
      gate_id: String(i).padEnd(width, "x"),
    }));
    counter.counting = line(gateConfig);
    transit.counting = line(counter);
    transit.sections[0].entry_gate_id = gateConfig.gates[0].gate_id;
    transit.sections[0].exit_gate_id = gateConfig.gates[1].gate_id;
    analysis.transit = line(transit);
    source.analysis = line(analysis);
    const prototype = browser(source, [empty(0)]),
      frameLength = line(prototype.frames[0]).length;
    let sum = 0;
    for (let count = 1; count <= 5000; count++) {
      const time = String(count - 1);
      sum += frameLength + 3 * (time.length - 1);
      prototype.checkpoint.health.state.last_timestamp_us = time;
      prototype.checkpoint.analysis.measurement.motion.last_timestamp_us = time;
      prototype.checkpoint.analysis.transit.counting.state.last_timestamp_us =
        time;
      const total =
        '{"frames":['.length +
        sum +
        count -
        1 +
        '],"checkpoint":'.length +
        line(prototype.checkpoint).length +
        1;
      if (total > 8388608) {
        if (sum + count <= 8388608) selected = { count, total };
        break;
      }
    }
  }
  assert.ok(selected);
  const bundle = Array.from({ length: selected.count }, (_, i) => empty(i));
  assert.equal(
    browser(source, bundle.slice(0, -1)).frames.length,
    bundle.length - 1,
  );
  assert.match(failure(invoke(source, ndjson(bundle))), /output.*8388608/);
});

test("all 64 legacy handles can be occupied while the pure owner reaches Int64 MAX", () => {
  const { header, frames } = fixture(9223372036854775807n - 2800000n),
    expected = browser(header, frames),
    handles = [];
  assert.equal(
    expected.checkpoint.health.state.last_timestamp_us,
    "9223372036854775807",
  );
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(line({ session_id: "held-" + i, mode: "ground" })),
        ).handle,
      );
    close(browser(header, frames), expected);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
});

test("instant Healthy gap reconfirmation preserves reachable segments and rejects incompatible known times", () => {
  const { header, frames } = fixture(0n),
    changed = clone(header);
  const config = JSON.parse(changed.health);
  Object.assign(config.health, {
    min_observations: 1,
    confirmation_us: "0",
    max_gap_us: "100000",
  });
  changed.health = line(config);
  const actual = browser(changed, frames.slice(0, 3));
  assert.ok(
    actual.frames.every(
      (v) => v.decision === "allowed" && v.health.status === "healthy",
    ),
  );
  assert.equal(
    actual.checkpoint.analysis.measurement.motion.tracks[0].first_timestamp_us,
    "0",
  );
  assert.equal(actual.checkpoint.health.state.streak.since_us, "200000");
  close(actual, independent(changed, frames.slice(0, 3)));
  const saved = browser(changed, frames.slice(0, 2)).checkpoint;
  const bad = clone(saved);
  bad.analysis.measurement.motion.tracks[0].first_timestamp_us = "99999";
  analysisBatch({ resume: bad.analysis });
  healthBatch({ resume: bad.health });
  failure(invoke({ resume: bad }, ""));
  native("--guarded-transit-evidence-checkpoint", [{ resume: bad }], 2);
  const strict = clone(saved);
  strict.health.configuration.health.max_gap_us = "500000";
  failure(invoke({ resume: strict }, ""));
});

test("warm Brown reframing preserves a pending passage and the complete health streak", () => {
  const { header, frames } = fixture(0n),
    changed = clone(header);
  const definition = JSON.parse(changed.analysis),
    transit = JSON.parse(definition.transit);
  const evidence = JSON.parse(transit.counting),
    config = JSON.parse(evidence.counting);
  const exit = config.gates.find((v) => v.gate_id === "interval-exit");
  exit.start_m[1] = 6;
  exit.end_m[1] = 6;
  evidence.counting = line(config);
  transit.counting = line(evidence);
  definition.transit = line(transit);
  changed.analysis = line(definition);
  const saved = browser(changed, frames.slice(0, 10)).checkpoint;
  assert.equal(saved.analysis.transit.pending.length, 2);
  assert.ok(saved.health.configuration.camera);
  const future = clone(frames[10]);
  const objects = JSON.parse(future.measurement);
  objects.observations = [2, 1].map((track_id) => ({
    track_id,
    point: pixel(saved.health.configuration, [1 + track_id * 0.1, 7]),
    covariance: [0.04, 0.008, 0.09],
  }));
  future.measurement = line(objects);
  const expected = browser({ resume: saved }, [future]);
  assert.equal(expected.frames[0].analysis.transit.passages.length, 2);
  const transform = { scale_x: 0.6, scale_y: 1.3, offset_x: -40, offset_y: 16 };
  const converted = native("--reframe", [
    { source: { resume: saved.analysis.measurement }, transform },
    future.measurement,
  ]);
  const reframed = clone(saved);
  reframed.analysis.measurement = converted[0].resume;
  changeProjection(
    reframed.health.configuration,
    reframed.analysis.measurement.configuration,
  );
  assert.deepEqual(reframed.analysis.transit, saved.analysis.transit);
  assert.deepEqual(reframed.health.state, saved.health.state);
  const fixed = JSON.parse(future.health);
  for (const value of fixed.observations) {
    value.point = [
      transform.scale_x * value.point[0] + transform.offset_x,
      transform.scale_y * value.point[1] + transform.offset_y,
    ];
    const [xx, xy, yy] = value.covariance ?? [4, 0, 4];
    value.covariance = [
      transform.scale_x ** 2 * xx,
      transform.scale_x * transform.scale_y * xy,
      transform.scale_y ** 2 * yy,
    ];
  }
  const actual = browser({ resume: reframed }, [wrap(converted[1], fixed)]);
  close(actual.frames, expected.frames);
  assert.equal(actual.frames[0].analysis.transit.passages.length, 2);
});
