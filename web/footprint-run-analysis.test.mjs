import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_zone_evidence,
  moonground_disk_zone_evidence,
  moonground_footprint_zone_evidence,
  moonground_assigned_zone_evidence,
  moonground_footprint_runs,
  moonground_footprint_run_analysis,
  moonground_footprint_run_preview,
  moonground_create,
  moonground_update,
  moonground_checkpoint,
  moonground_restore,
  moonground_close,
} from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.env.MOONGROUND_CLI
  ? path.resolve(root, process.env.MOONGROUND_CLI)
  : ["main.exe", "main"]
      .map((value) =>
        path.join(root, "_build/native/release/build/cmd/main", value),
      )
      .find(existsSync);
assert.ok(binary, "Build the native release before zone verification.");
const clone = (value) => JSON.parse(JSON.stringify(value));
const line = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
const ndjson = (records) =>
  records.map(line).join("\n") + (records.length ? "\n" : "");
const unpack = (text) => {
  const result = JSON.parse(text);
  assert.equal(result.error, undefined, text.slice(0, 1500));
  return result;
};
const failure = (text) => {
  const result = JSON.parse(text);
  assert.deepEqual(
    Object.keys(result),
    ["error"],
    "failed batch exposed partial data",
  );
  assert.equal(typeof result.error, "string");
  return result.error;
};
const invoke = (source, measurements) =>
  moonground_zone_evidence(line({ source: line(source), measurements }));
const browser = (source, frames = []) =>
  unpack(invoke(source, typeof frames === "string" ? frames : ndjson(frames)));

function close(actual, expected, where = "$") {
  if (typeof expected === "number") {
    assert.equal(typeof actual, "number", where);
    assert.ok(Number.isFinite(actual), where);
    if (where.endsWith("track_id") || where.endsWith("accepted_count"))
      assert.equal(actual, expected, where);
    else
      assert.ok(
        Math.abs(actual - expected) <=
          5e-10 * Math.max(Math.abs(expected), 1e-300),
        `${where}: ${actual} != ${expected}`,
      );
  } else if (Array.isArray(expected)) {
    assert.equal(actual.length, expected.length, where);
    expected.forEach((value, index) =>
      close(actual[index], value, `${where}[${index}]`),
    );
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

function native(mode, records, status = 0, extra = []) {
  const result = spawnSync(binary, [mode, ...extra], {
    input: ndjson(records),
    encoding: "utf8",
    maxBuffer: 128 * 1024 * 1024,
    timeout: 120000,
  });
  assert.equal(result.status, status, result.stderr || result.error?.message);
  if (!status) assert.equal(result.stderr, "");
  if (result.stdout)
    assert.ok(result.stdout.endsWith("\n"), "partial native JSON line");
  return result.stdout
    ? result.stdout.trimEnd().split("\n").map(JSON.parse)
    : [];
}

function oldReplay(configuration, frames, saved = null) {
  const { handle } = saved
    ? unpack(moonground_restore(line(saved)))
    : unpack(moonground_create(line(configuration)));
  try {
    return {
      frames: frames.map((value) =>
        unpack(moonground_update(handle, line(value))),
      ),
      checkpoint: unpack(moonground_checkpoint(handle)),
    };
  } finally {
    assert.equal(moonground_close(handle), true);
  }
}
function rawFixture() {
  const start = 9007199254740993n;
  const source = {
    session_id: "velocity-old-cp",
    mode: "ground",
    diagnostics: true,
    motion: {
      min_observations: 2,
      min_span_us: "0",
      max_gap_us: "500000",
      q: 0.2,
      gate: 9.21034,
    },
  };
  const frames = Array.from({ length: 8 }, (_, i) => ({
    timestamp_us: String(start + BigInt(i) * 100000n),
    observations:
      i === 4
        ? []
        : [
            {
              track_id: 7,
              point: i === 3 ? [100, 100] : [i * 0.1, 0],
              covariance: [0.01, 0.002, 0.02],
            },
          ],
  }));
  return { source, frames };
}

const zone = (
  id = "workspace",
  vertices = [
    [0, 0],
    [1, 0],
    [1, 1],
    [0, 1],
  ],
  k = 2,
) => ({ zone_id: id, vertices_m: vertices, sigma_multiplier: k });
const config = (
  zones = [zone()],
  session_id = "zone-web",
  max_tracks = 32,
) => ({ session_id, zones, max_tracks });
function track(
  time,
  point = [0.5, 0.5],
  covariance = [0.01, 0, 0.01],
  id = 1,
  status = "ready",
  segment = String(id),
) {
  if (status === "rejected_projection")
    return {
      track_id: id,
      segment_id: null,
      status,
      reason: "outside calibration roi",
      position_m: null,
      position_covariance: null,
      velocity_mps: null,
      velocity_covariance: null,
      position_std_m: null,
      velocity_std_mps: null,
      speed_mps: null,
    };
  const accepted = ["initializing", "ready", "uncertain"].includes(status),
    observable = ["ready", "uncertain"].includes(status);
  return {
    track_id: id,
    segment_id: segment,
    status,
    position_m: accepted ? point : null,
    position_covariance: accepted ? covariance : null,
    velocity_mps: observable ? [0, 0] : null,
    velocity_covariance: observable ? [0.04, 0, 0.04] : null,
    position_std_m: accepted
      ? Math.sqrt(Math.max(covariance[0], covariance[2]))
      : null,
    velocity_std_mps: observable ? 0.2 : null,
    speed_mps: status === "ready" ? 0 : null,
    observed_path_length_m: 0,
    net_displacement_m: 0,
    accepted_count: status === "initializing" ? 1 : 3,
    last_accepted_timestamp_us: String(accepted ? time : BigInt(time) - 1n),
  };
}
const frame = (source, time, tracks = [], closed = []) => ({
  schema_version: "0.2.0",
  session_id: source.session_id,
  timestamp_us: String(time),
  tracks,
  closed_segment_ids: closed,
  uncertainty_scope: "conditional_on_fixed_calibration_camera_and_anchor",
});

const diskSource = (position, radius = 0.125) => ({
  position: line(position),
  disk: line({ radius_m: radius }),
});
const invokeDisk = (source, measurements) =>
  moonground_disk_zone_evidence(line({ source: line(source), measurements }));
const disk = (position, inputs = [], radius = 0.125) =>
  unpack(
    invokeDisk(
      diskSource(position, radius),
      typeof inputs === "string" ? inputs : ndjson(inputs),
    ),
  );

const DEFAULT = [
  [-0.25, -0.25],
  [1, -0.25],
  [1, 0.25],
  [-0.25, 0.25],
];
const square = (r) => [
  [-r, -r],
  [r, -r],
  [r, r],
  [-r, r],
];
const footprintSource = (position, vertices = DEFAULT) => ({
  position: line(position),
  footprint: line({ vertices_offset_m: vertices }),
});
const invokeFootprint = (source, measurements) =>
  moonground_footprint_zone_evidence(
    line({ source: line(source), measurements }),
  );
const footprint = (position, inputs = [], vertices = DEFAULT) =>
  unpack(
    invokeFootprint(
      footprintSource(position, vertices),
      typeof inputs === "string" ? inputs : ndjson(inputs),
    ),
  );

const diskShape = (radius = 0.25) => ({ kind: "disk", radius_m: radius });
const convexShape = (vertices = DEFAULT) => ({
  kind: "convex",
  vertices_offset_m: vertices,
});
const binding = (track, shape) => ({
  track_id: track.track_id,
  segment_id: track.segment_id,
  shape,
});
const bundle = (
  measurement,
  footprints = measurement.tracks
    .filter((t) => t.segment_id !== null)
    .map((t) =>
      binding(
        t,
        (t.track_id +
          Number((BigInt(measurement.timestamp_us) / 100000n) % 2n)) %
          2
          ? diskShape()
          : convexShape(),
      ),
    ),
) => ({ timestamp_us: measurement.timestamp_us, footprints });
const pair = (measurement, document = bundle(measurement)) => ({
  measurement: line(measurement),
  assignments: line(document),
});
const invokeAssigned = (source, frames) =>
  moonground_assigned_zone_evidence(line({ source: line(source), frames }));
const evaluate = (source, wrapped = []) =>
  unpack(
    invokeAssigned(
      source,
      typeof wrapped === "string" ? wrapped : ndjson(wrapped),
    ),
  );
const assigned = (source, measurements = []) =>
  evaluate(
    source,
    measurements.map((v) => pair(v)),
  );
function tagged(row, shape) {
  const value = clone(row);
  value.shape_kind = shape.kind;
  if (shape.kind === "disk")
    value.faces.forEach((face) => {
      face.footprint_lower_m = -shape.radius_m;
      face.footprint_upper_m = shape.radius_m;
    });
  return value;
}
function grouped(source, measurement, document = bundle(measurement)) {
  const result = browser(source, [measurement]).frames[0];
  result.kind = "assigned_zone_evidence_frame";
  result.evidence_scope =
    "model_position_halfplane_bands_plus_current_target_footprints";
  result.evidence = [];
  for (const track of [...measurement.tracks].sort(
    (a, b) => a.track_id - b.track_id,
  )) {
    if (track.status !== "ready") continue;
    const item = document.footprints.find((v) => v.track_id === track.track_id);
    if (!item) {
      result.unavailable.push({
        track_id: track.track_id,
        segment_id: track.segment_id,
        reason: "missing_footprint",
      });
      continue;
    }
    assert.equal(item.segment_id, track.segment_id);
    const shape = item.shape,
      selected = { ...measurement, tracks: [track] },
      report =
        shape.kind === "disk"
          ? disk(source, [selected], shape.radius_m)
          : footprint(source, [selected], shape.vertices_offset_m);
    result.evidence.push(
      ...report.frames[0].evidence.map((row) => tagged(row, shape)),
    );
  }
  result.unavailable.sort((a, b) => a.track_id - b.track_id);
  return result;
}

const runSource = (position, options = {}) => ({
  position: line(position),
  options: line(options),
});
const invokeRuns = (source, frames) =>
  moonground_footprint_runs(line({ source: line(source), frames }));
const runs = (source, frames = []) =>
  unpack(
    invokeRuns(source, typeof frames === "string" ? frames : ndjson(frames)),
  );
const runPosition = () => config([zone("workspace", undefined, 0)], "run-web");
function runSample(
  position,
  t,
  kind = "inside",
  shape = diskShape(0.125),
  segment = "1",
  closed = [],
) {
  const statuses = {
    initializing: "initializing",
    uncertain: "uncertain",
    rejected: "rejected_innovation",
    numerical: "numerical_failure",
    projection: "rejected_projection",
  };
  const point =
      kind === "outside"
        ? [2, 0.5]
        : kind === "indeterminate"
          ? [1, 0.5]
          : [0.5, 0.5],
    measurement = frame(
      position,
      t,
      kind === "absent"
        ? []
        : [
            track(
              t,
              point,
              [0.01, 0, 0.01],
              1,
              statuses[kind] || "ready",
              segment,
            ),
          ],
      closed,
    ),
    items = ["absent", "missing", "projection"].includes(kind)
      ? []
      : [binding(measurement.tracks[0], shape)];
  return pair(measurement, bundle(measurement, items));
}
const runOptions = { max_gap_us: "10", confirmation_us: "2", min_samples: "2" };

const jointSource = (measurement, runs) => ({
  measurement: line(measurement),
  runs: line(runs),
});
const invokeJoint = (source, frames) =>
  moonground_footprint_run_analysis(line({ source: line(source), frames }));
const joint = (source, frames = []) =>
  unpack(
    invokeJoint(source, typeof frames === "string" ? frames : ndjson(frames)),
  );
const invokePreview = (source, frame) =>
  moonground_footprint_run_preview(
    line({ source: line(source), frame: line(frame) }),
  );
const preview = (source, frame) => unpack(invokePreview(source, frame));
function fixture() {
  const { source, frames } = rawFixture();
  source.session_id = "joint-web";
  source.motion.gate = 1e12;
  const position = config([zone("wide", square(100), 2)], source.session_id),
    runHeader = runSource(position, {
      min_samples: "2",
      confirmation_us: "100000",
    });
  return { source, frames, runHeader };
}
function components(source, runHeader, raw) {
  const measured = oldReplay(source, raw),
    docs = measured.frames.map((v) =>
      bundle(
        v,
        v.tracks
          .filter((t) => t.segment_id !== null)
          .map((t) =>
            binding(t, t.track_id % 2 ? diskShape(0.125) : convexShape()),
          ),
      ),
    );
  const old = runs(
    runHeader,
    measured.frames.map((v, i) => pair(v, docs[i])),
  );
  return {
    frames: measured.frames.map((v, i) => ({
      schema_version: "0.1.0",
      kind: "footprint_run_analysis_frame",
      measurement: v,
      runs: old.frames[i],
    })),
    checkpoint: {
      format: "moonground.footprint-run-analysis",
      checkpoint_version: "1",
      measurement: measured.checkpoint,
      runs: old.checkpoint,
    },
    wrapped: raw.map((v, i) => pair(v, docs[i])),
  };
}
function stable() {
  const source = {
      session_id: "joint-stable",
      mode: "ground",
      diagnostics: true,
      motion: { min_observations: 2, min_span_us: "0", gate: 1e12 },
    },
    frames = Array.from({ length: 4 }, (_, i) => ({
      timestamp_us: String(i * 100000),
      observations: [
        { track_id: 1, point: [0.5, 0.5], covariance: [0.01, 0, 0.01] },
      ],
    }));
  return {
    source,
    frames,
    runHeader: runSource(
      config(
        [zone("one", square(10), 2), zone("two", square(20), 2)],
        source.session_id,
      ),
      { min_samples: "2", confirmation_us: "100000" },
    ),
  };
}
const mode = "--analyze-footprint-runs",
  checkpointMode = "--analyze-footprint-runs-checkpoint",
  previewMode = "--preview-footprint-run";

test("candidate preview exposes actual identities without committing and full outputs equal old components", () => {
  const f = fixture(),
    head = jointSource(f.source, f.runHeader),
    expected = components(f.source, f.runHeader, f.frames);
  const cp = joint(head).checkpoint,
    first = preview(head, f.frames[0]);
  close(first, { measurement: expected.frames[0].measurement });
  close(preview(head, f.frames[0]), first);
  close(joint(head).checkpoint, cp);
  first.measurement.tracks[0].segment_id = "99";
  close(joint(head, expected.wrapped), {
    frames: expected.frames,
    checkpoint: expected.checkpoint,
  });
  close(native(mode, [head, ...expected.wrapped]), expected.frames);
  close(
    native(checkpointMode, [head, ...expected.wrapped])[0],
    expected.checkpoint,
  );
});

test("every joint cut resumes in four native and JavaScript directions with exact Int64 clocks", (t) => {
  const f = fixture(),
    head = jointSource(f.source, f.runHeader),
    expected = components(f.source, f.runHeader, f.frames);
  let comparisons = 0;
  for (let cut = 0; cut <= f.frames.length; cut++) {
    const a = joint(head, expected.wrapped.slice(0, cut)).checkpoint,
      b = native(checkpointMode, [head, ...expected.wrapped.slice(0, cut)])[0];
    close(a, b);
    for (const cp of [a, b]) {
      close(joint({ resume: cp }, expected.wrapped.slice(cut)), {
        frames: expected.frames.slice(cut),
        checkpoint: expected.checkpoint,
      });
      comparisons++;
      close(
        native(mode, [{ resume: cp }, ...expected.wrapped.slice(cut)]),
        expected.frames.slice(cut),
      );
      close(
        native(checkpointMode, [
          { resume: cp },
          ...expected.wrapped.slice(cut),
        ])[0],
        expected.checkpoint,
      );
      comparisons++;
    }
  }
  t.diagnostic(
    JSON.stringify({
      cut_points: f.frames.length + 1,
      runtime_directions: 4,
      continuations: comparisons,
      original_int64_start: f.frames[0].timestamp_us,
    }),
  );
});

test("late identity and physical numeric failures expose no pure prefix and corrected same-time replay matches full checkpoints", () => {
  const f = stable(),
    head = jointSource(f.source, f.runHeader),
    expected = components(f.source, f.runHeader, f.frames.slice(0, 2));
  const wrong = clone(expected.wrapped[0]),
    doc = JSON.parse(wrong.assignments);
  doc.footprints[0].segment_id = "9";
  wrong.assignments = line(doc);
  failure(invokeJoint(head, ndjson([wrong])));
  assert.deepEqual(native(mode, [head, wrong], 2), []);
  const cp = joint(head, [expected.wrapped[0]]).checkpoint,
    bad = clone(expected.wrapped[1]),
    d = JSON.parse(bad.assignments);
  d.footprints[0].shape = diskShape(1e-30);
  bad.assignments = line(d);
  failure(invokeJoint(head, ndjson([expected.wrapped[0], bad])));
  close(
    native(mode, [head, expected.wrapped[0], bad], 2),
    expected.frames.slice(0, 1),
  );
  assert.deepEqual(
    native(checkpointMode, [head, expected.wrapped[0], bad], 2),
    [],
  );
  close(joint({ resume: cp }, [expected.wrapped[1]]), {
    frames: expected.frames.slice(1),
    checkpoint: expected.checkpoint,
  });
  close(joint({ resume: cp }).checkpoint, cp);
});

test("warm Brown component resumes and transformed original pixels preserve explicit metric run histories", (t) => {
  const records = readFileSync(
      path.join(root, "examples/distorted-camera.ndjson"),
      "utf8",
    )
      .trim()
      .split(/\r?\n/)
      .map(JSON.parse),
    source = records[0];
  source.diagnostics = true;
  const raw = records.slice(1),
    runHeader = runSource(
      config([zone("wide", square(100), 0)], source.session_id),
    ),
    head = jointSource(source, runHeader),
    expected = components(source, runHeader, raw),
    cut = Math.min(4, raw.length - 1);
  const cp = joint(head, expected.wrapped.slice(0, cut)).checkpoint,
    transform = { scale_x: 0.5, scale_y: 1.25, offset_x: -15, offset_y: 8 };
  const changed = native("--reframe", [
      { source: { resume: cp.measurement }, transform },
      ...raw.slice(cut),
    ]),
    adapted = clone(cp);
  adapted.measurement = changed[0].resume;
  const original = joint({ resume: cp }, expected.wrapped.slice(cut)),
    actual = joint(
      { resume: adapted },
      changed
        .slice(1)
        .map((v, i) =>
          pair(v, JSON.parse(expected.wrapped[cut + i].assignments)),
        ),
    );
  let maximumAbsolute = 0,
    numericalValues = 0;
  function warm(a, b) {
    if (typeof b === "number") {
      assert.equal(typeof a, "number");
      assert.ok(Number.isFinite(a));
      const error = Math.abs(a - b);
      maximumAbsolute = Math.max(maximumAbsolute, error);
      numericalValues++;
      assert.ok(error <= Math.max(1e-11, 3e-8 * Math.abs(b)), `${a} != ${b}`);
    } else if (Array.isArray(b)) {
      assert.equal(a.length, b.length);
      b.forEach((v, i) => warm(a[i], v));
    } else if (b && typeof b === "object") {
      assert.deepEqual(Object.keys(a).sort(), Object.keys(b).sort());
      Object.keys(b).forEach((k) => warm(a[k], b[k]));
    } else assert.equal(a, b);
  }
  warm(actual.frames, original.frames);
  warm(actual.checkpoint.runs, original.checkpoint.runs);
  t.diagnostic(
    JSON.stringify({
      warm_reframe_maximum_absolute_error: maximumAbsolute,
      numerical_values: numericalValues,
      relative_tolerance: 3e-8,
      absolute_tolerance: 1e-11,
    }),
  );
  assert.ok(actual.frames.length > 0);
});

test("strict raw tokens and independently legal component histories cannot bypass joint bindings", () => {
  const f = stable(),
    head = jointSource(f.source, f.runHeader),
    expected = components(f.source, f.runHeader, f.frames.slice(0, 3)),
    cp = expected.checkpoint;
  const mutations = [
    (v) => (v.runs.session_id = "other"),
    (v) => v.runs.states.forEach((s) => (s.last_position_m = [0.6, 0.5])),
    (v) =>
      v.runs.states.forEach((s) => (s.last_position_covariance[0] += 1e-6)),
    (v) => v.runs.states.forEach((s) => (s.run.segment_id = "2")),
    (v) => (v.measurement.configuration.motion.min_observations = 5),
    (v) => {
      v.measurement.motion.tracks[0].accepted_count = 4;
      const r = v.runs.states[1].run;
      r.first_timestamp_us = "150000";
      r.sample_span_us = "50000";
      r.confirmed = false;
    },
  ];
  for (const mutate of mutations) {
    const bad = clone(cp);
    mutate(bad);
    const restored = unpack(moonground_restore(line(bad.measurement))).handle;
    moonground_close(restored);
    runs({ resume: bad.runs });
    failure(invokeJoint({ resume: bad }, ""));
  }
  const value = expected.wrapped[1],
    frac = {
      ...value,
      assignments: value.assignments.replace(
        '"track_id":1',
        '"track_id":1.0000000000000001',
      ),
    };
  for (const bad of [
    frac,
    { ...value, extra: true },
    '{"measurement":"bad",' + line(value).slice(1),
  ])
    failure(invokeJoint(head, ndjson([expected.wrapped[0], bad])));
  failure(invokeJoint({ ...head, extra: 1 }, ""));
  failure(invokePreview(head, expected.frames[0].measurement));
});

test("preview protocol requires one original observation and remains usable when old handles are full", () => {
  const f = fixture(),
    head = jointSource(f.source, f.runHeader),
    first = preview(head, f.frames[0]);
  assert.deepEqual(native(previewMode, [head], 2), []);
  close(native(previewMode, [head, f.frames[0], f.frames[1]], 2), [first]);
  const handles = [];
  try {
    for (let i = 0; i < 64; i++) {
      const v = JSON.parse(
        moonground_create(line({ ...f.source, session_id: "occupied" + i })),
      );
      if (v.error) break;
      handles.push(v.handle);
    }
    assert.ok(handles.length >= 58);
    close(preview(head, f.frames[0]), first);
    assert.equal(joint(head).frames.length, 0);
  } finally {
    handles.forEach((h) => moonground_close(h));
  }
});

test("actual raw frame, batch and whole output budgets preserve complete pure atomicity", (t) => {
  const f = fixture(),
    head = jointSource(f.source, f.runHeader),
    empty = Array.from({ length: 5000 }, (_, i) =>
      pair(
        { timestamp_us: String(i), observations: [] },
        { timestamp_us: String(i), footprints: [] },
      ),
    ),
    result = joint(head, empty);
  assert.equal(result.frames.length, 5000);
  const length = line(result).length;
  assert.ok(length <= 8 * 1048576);
  failure(invokeJoint(head, ndjson([...empty, empty[0]])));
  failure(invokeJoint(head, " ".repeat(8 * 1048576 + 1)));
  failure(moonground_footprint_run_analysis(" ".repeat(16 * 1048576 + 1)));
  const first = pair(
    f.frames[0],
    bundle(preview(head, f.frames[0]).measurement),
  );
  close(joint(head, line(first).padEnd(1048576)), joint(head, [first]));
  failure(invokeJoint(head, line(first).padEnd(1048577)));
  failure(invokeJoint(line(head).padEnd(8 * 1048576 + 12), ""));
  failure(
    moonground_footprint_run_preview(
      line({ source: line(head), frame: line(f.frames[0]), extra: 1 }),
    ),
  );
  t.diagnostic(
    JSON.stringify({
      successful_empty_frames: 5000,
      whole_return_utf16: length,
      frames_limit: 5000,
      whole_return_limit_utf16: 8 * 1048576,
    }),
  );
});

test("actual maximum joint Ready targets retain all supported faces and states before pure output budget rejects", (t) => {
  const n = 32,
    vertices = Array.from({ length: n }, (_, i) => {
      const x = i - 15.5;
      return [x, i * i - 360];
    }),
    source = {
      session_id: "joint-max",
      mode: "ground",
      motion: { min_observations: 2, min_span_us: "0", max_tracks: 128 },
    },
    position = config(
      Array.from({ length: 16 }, (_, i) => zone("z" + i, vertices, 0)),
      source.session_id,
      128,
    ),
    runHeader = runSource(position),
    head = jointSource(source, runHeader),
    raw = [0, 100000].map((time) => ({
      timestamp_us: String(time),
      observations: Array.from({ length: 128 }, (_, i) => ({
        track_id: i + 1,
        point: [0, 0],
        covariance: [0.01, 0, 0.01],
      })),
    }));
  const measured = native("--stream", [source, ...raw]),
    wrapped = raw.map((v, i) =>
      pair(
        v,
        bundle(
          measured[i],
          measured[i].tracks.map((track) =>
            binding(track, convexShape(vertices)),
          ),
        ),
      ),
    ),
    out = native(mode, [head, ...wrapped]),
    cp = native(checkpointMode, [head, ...wrapped])[0],
    last = out[1];
  assert.equal(last.runs.evidence.evidence.length, 2048);
  assert.equal(
    last.runs.evidence.evidence.reduce((n, v) => n + v.faces.length, 0),
    65536,
  );
  assert.equal(cp.runs.states.length, 2048);
  const equivalent = line({ frames: out, checkpoint: cp }).length;
  assert.ok(equivalent > 8 * 1048576);
  failure(invokeJoint(head, ndjson(wrapped)));
  t.diagnostic(
    JSON.stringify({
      maximum_actual_face_expansions: 65536,
      maximum_actual_support_vertex_projections: 2097152,
      ready_targets: 128,
      zones: 16,
      faces_per_zone: 32,
      retained_states: 2048,
      equivalent_whole_return_utf16: equivalent,
      checkpoint_utf16: line(cp).length,
    }),
  );
});
