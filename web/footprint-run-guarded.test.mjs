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
  moonground_footprint_run_guarded,
  moonground_footprint_run_guarded_preview,
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

const guardMode = "--guarded-footprint-runs",
  guardCheckpoint = "--guarded-footprint-runs-checkpoint",
  guardPreview = "--preview-guarded-footprint-run";
const guardSource = (analysis, health) => ({
  analysis: line(analysis),
  health: line(health),
});
const invokeGuard = (source, frames) =>
  moonground_footprint_run_guarded(line({ source: line(source), frames }));
const guard = (source, frames = []) =>
  unpack(
    invokeGuard(source, typeof frames === "string" ? frames : ndjson(frames)),
  );
const invokeBatchPreview = (source, frames) =>
  moonground_footprint_run_guarded_preview(
    line({ source: line(source), frames }),
  );
const batchPreview = (source, frames = []) =>
  unpack(
    invokeBatchPreview(
      source,
      typeof frames === "string" ? frames : ndjson(frames),
    ),
  );
const fullCP = (analysis, health) => ({
  format: "moonground.footprint-run-guarded",
  checkpoint_version: "1",
  analysis,
  health,
});
function guardFixture(instant = false) {
  const calibration = {
      matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
      roi: square(100),
      max_meters_per_pixel: 2,
      ground_noise_floor_m: 0.001,
    },
    source = {
      session_id: "footprint-guard-web",
      mode: "pixel",
      diagnostics: true,
      calibration,
      motion: {
        max_tracks: 8,
        min_observations: 2,
        min_span_us: "0",
        max_gap_us: "500000",
        gate: 1e12,
      },
    },
    health = {
      monitor_id: "fixed",
      calibration,
      landmarks: [
        { landmark_id: "a", ground_m: [0, 0] },
        { landmark_id: "b", ground_m: [1, 0] },
        { landmark_id: "c", ground_m: [0, 1] },
      ],
      health: {
        min_landmarks: 3,
        min_observations: instant ? 1 : 3,
        confirmation_us: instant ? "0" : "200000",
        max_gap_us: "500000",
        rms_limit_m: 0.1,
        max_error_m: 0.2,
      },
    },
    runHeader = runSource(
      config([zone("wide", square(10), 2)], source.session_id, 8),
      { min_samples: "2", confirmation_us: "100000" },
    );
  const start = 9007199254740993n,
    frames = Array.from({ length: 9 }, (_, i) => {
      const t = String(start + 100000n * BigInt(i));
      return {
        measurement: line({
          timestamp_us: t,
          observations: [2, 1].map((id) => ({
            track_id: id,
            point: [0.5, 0.5],
            covariance: [0.01, 0, 0.01],
          })),
        }),
        health: line({
          timestamp_us: t,
          observations:
            i === 4
              ? []
              : health.landmarks.map((v) => ({
                  landmark_id: v.landmark_id,
                  point: v.ground_m,
                  covariance: [0.01, 0, 0.01],
                })),
        }),
      };
    });
  return {
    source,
    health,
    runHeader,
    head: guardSource(jointSource(source, runHeader), health),
    frames,
  };
}
function hostGuard(head, raw) {
  const sources = JSON.parse(head.analysis);
  let analysis = native(checkpointMode, [sources])[0],
    health = native("--health-checkpoint", [head.health])[0];
  const frames = [],
    wrapped = [],
    previews = [],
    snapshots = [fullCP(analysis, health)];
  for (const value of raw) {
    const replacing = Object.hasOwn(value, "replace_projection");
    let object, landmarks, healthSource;
    if (replacing) {
      const control = JSON.parse(value.replace_projection);
      healthSource = clone(health.configuration);
      healthSource.calibration = control.calibration;
      if (control.camera === null) delete healthSource.camera;
      else healthSource.camera = control.camera;
      object = { timestamp_us: control.timestamp_us, observations: [] };
      landmarks = { timestamp_us: control.timestamp_us, observations: [] };
    } else {
      object = JSON.parse(value.measurement);
      landmarks = JSON.parse(value.health);
      healthSource = { resume: health };
    }
    const report = native("--health", [healthSource, landmarks])[0],
      allowed = !replacing && report.status === "healthy",
      effective = allowed
        ? object
        : {
            timestamp_us: object.timestamp_us,
            observations: [],
            removed: analysis.measurement.motion.tracks
              .map((t) => t.track_id)
              .sort((a, b) => a - b),
          },
      measured = native(previewMode, [{ resume: analysis }, effective])[0]
        .measurement;
    const doc = allowed
        ? bundle(
            measured,
            measured.tracks
              .filter((t) => t.segment_id !== null)
              .map((t) =>
                binding(t, t.track_id % 2 ? diskShape(0.125) : convexShape()),
              ),
          )
        : { timestamp_us: measured.timestamp_us, footprints: [] },
      input = pair(effective, doc),
      current = native(mode, [{ resume: analysis }, input])[0];
    analysis = native(checkpointMode, [{ resume: analysis }, input])[0];
    health = native("--health-checkpoint", [healthSource, landmarks])[0];
    if (replacing) {
      analysis.measurement.configuration.calibration = clone(
        health.configuration.calibration,
      );
      if (health.configuration.camera)
        analysis.measurement.configuration.camera = clone(
          health.configuration.camera,
        );
      else delete analysis.measurement.configuration.camera;
      wrapped.push(value);
    } else wrapped.push({ ...value, assignments: line(doc) });
    const suppressed =
        allowed || replacing
          ? []
          : object.observations.map((t) => t.track_id).sort((a, b) => a - b),
      preview = {
        decision: allowed ? "allowed" : "blocked",
        health: report,
        measurement: current.measurement,
        suppressed_track_ids: suppressed,
      };
    previews.push(preview);
    frames.push({
      schema_version: "0.1.0",
      kind: replacing
        ? "footprint_run_guarded_projection_replaced"
        : "footprint_run_guarded_frame",
      decision: preview.decision,
      health: report,
      analysis: current,
      suppressed_track_ids: suppressed,
    });
    snapshots.push(fullCP(analysis, health));
  }
  return {
    frames,
    checkpoint: fullCP(analysis, health),
    wrapped,
    previews,
    snapshots,
  };
}

test("old health and v27 chain match all guarded outputs and batch preview discovers post-block identities", () => {
  const f = guardFixture(),
    expected = hostGuard(f.head, f.frames);
  close(guard(f.head, expected.wrapped), {
    frames: expected.frames,
    checkpoint: expected.checkpoint,
  });
  close(native(guardMode, [f.head, ...expected.wrapped]), expected.frames);
  close(batchPreview(f.head, f.frames), { frames: expected.previews });
  assert.equal(expected.previews[0].decision, "blocked");
  assert.deepEqual(expected.previews[0].measurement.tracks, []);
  assert.equal(expected.previews[2].measurement.tracks[0].segment_id, "1");
  assert.equal(expected.previews[7].measurement.tracks[0].segment_id, "3");
  assert.deepEqual(Object.keys(batchPreview(f.head, f.frames)).sort(), [
    "frames",
  ]);
  close(guard(f.head).checkpoint, expected.snapshots[0]);
});

test("every selected guarded cut continues in four native and JavaScript directions", (t) => {
  const f = guardFixture(),
    expected = hostGuard(f.head, f.frames);
  let count = 0;
  for (let cut = 0; cut <= f.frames.length; cut++) {
    const a = guard(f.head, expected.wrapped.slice(0, cut)).checkpoint,
      b = native(guardCheckpoint, [
        f.head,
        ...expected.wrapped.slice(0, cut),
      ])[0];
    close(a, b);
    for (const cp of [a, b]) {
      close(guard({ resume: cp }, expected.wrapped.slice(cut)), {
        frames: expected.frames.slice(cut),
        checkpoint: expected.checkpoint,
      });
      count++;
      close(
        native(guardMode, [{ resume: cp }, ...expected.wrapped.slice(cut)]),
        expected.frames.slice(cut),
      );
      close(
        native(guardCheckpoint, [
          { resume: cp },
          ...expected.wrapped.slice(cut),
        ])[0],
        expected.checkpoint,
      );
      count++;
    }
  }
  t.diagnostic(
    JSON.stringify({
      cut_points: f.frames.length + 1,
      runtime_directions: 4,
      continuations: count,
      original_int64_timestamp: JSON.parse(f.frames[0].measurement)
        .timestamp_us,
    }),
  );
});

test("first Healthy identity failure and first Ready numeric failure preserve health and motion for same-time correction", () => {
  const f = guardFixture(),
    expected = hostGuard(f.head, f.frames.slice(0, 4)),
    wrong = clone(expected.wrapped[2]),
    doc = JSON.parse(wrong.assignments);
  doc.footprints[0].segment_id = "99";
  wrong.assignments = line(doc);
  failure(
    invokeGuard(f.head, ndjson([...expected.wrapped.slice(0, 2), wrong])),
  );
  close(
    native(guardMode, [f.head, ...expected.wrapped.slice(0, 2), wrong], 2),
    expected.frames.slice(0, 2),
  );
  close(
    guard({ resume: expected.snapshots[2] }, [expected.wrapped[2]]).checkpoint,
    expected.snapshots[3],
  );
  const tiny = clone(expected.wrapped[3]),
    d = JSON.parse(tiny.assignments);
  d.footprints.forEach((t) => (t.shape = diskShape(1e-30)));
  tiny.assignments = line(d);
  failure(invokeGuard({ resume: expected.snapshots[3] }, ndjson([tiny])));
  assert.deepEqual(
    native(guardCheckpoint, [{ resume: expected.snapshots[3] }, tiny], 2),
    [],
  );
  close(
    guard({ resume: expected.snapshots[3] }, [expected.wrapped[3]]).checkpoint,
    expected.snapshots[4],
  );
});

test("blocked raw validation and exact empty assignments cannot be bypassed by preview or missing shapes", () => {
  const f = guardFixture(),
    expected = hostGuard(f.head, f.frames),
    first = expected.wrapped[0];
  for (const mutate of [
    (o) => o.observations.push(clone(o.observations[0])),
    (o) => (o.lost = [1]),
    (o) => (o.observations[0].covariance = [1, 2, 1]),
  ]) {
    const value = clone(first),
      object = JSON.parse(value.measurement);
    mutate(object);
    value.measurement = line(object);
    failure(invokeGuard(f.head, ndjson([value])));
    failure(
      invokeBatchPreview(
        f.head,
        ndjson([{ measurement: value.measurement, health: value.health }]),
      ),
    );
  }
  const extra = clone(first);
  extra.assignments = line({
    timestamp_us: JSON.parse(first.measurement).timestamp_us,
    footprints: [{ track_id: 1, segment_id: "1", shape: diskShape() }],
  });
  failure(invokeGuard(f.head, ndjson([extra])));
  const enormous = clone(first),
    object = JSON.parse(enormous.measurement);
  object.observations.forEach((t) => {
    t.point = [1e308, -1e308];
    t.covariance = [1e300, 0, 1e300];
  });
  enormous.measurement = line(object);
  assert.deepEqual(
    guard(f.head, [enormous]).frames[0].analysis.measurement.tracks,
    [],
  );
  failure(invokeGuard(f.head, ndjson([{ ...first, extra: 1 }])));
  failure(
    invokeGuard(
      f.head,
      ndjson([
        {
          ...first,
          measurement: first.measurement.replace(
            '"track_id":2',
            '"track_id":2.0000000000000001',
          ),
        },
      ]),
    ),
  );
  failure(invokeBatchPreview(f.head, ndjson([first])));
});

test("replacement controls are previewed and committed as cold barriers while Brown warm reframe preserves metric histories", (t) => {
  const f = guardFixture(true),
    base = f.frames.slice(0, 3),
    stamp = String(
      BigInt(JSON.parse(base[2].measurement).timestamp_us) + 100000n,
    ),
    control = {
      replace_projection: line({
        timestamp_us: stamp,
        calibration: f.source.calibration,
        camera: null,
      }),
    },
    raw = [...base, control],
    expected = hostGuard(f.head, raw);
  close(guard(f.head, expected.wrapped), {
    frames: expected.frames,
    checkpoint: expected.checkpoint,
  });
  close(batchPreview(f.head, raw), { frames: expected.previews });
  assert.equal(expected.frames.at(-1).health.status, "insufficient");
  assert.equal(expected.checkpoint.analysis.runs.states.length, 0);
  // Brown calibration is obtained from the existing public example and receives
  // its own fixed landmark truths, projected through the independent old health path.
  const original = readFileSync(
      path.join(root, "examples/distorted-camera.ndjson"),
      "utf8",
    )
      .trim()
      .split(/\r?\n/)
      .map(JSON.parse),
    source = original[0];
  source.diagnostics = true;
  const ideals = [
      [180, 200],
      [320, 200],
      [180, 320],
    ],
    H = source.calibration.matrix,
    known = ideals.map((p, i) => {
      const z = H[6] * p[0] + H[7] * p[1] + H[8];
      return {
        landmark_id: String(i),
        ground_m: [
          (H[0] * p[0] + H[1] * p[1] + H[2]) / z,
          (H[3] * p[0] + H[4] * p[1] + H[5]) / z,
        ],
      };
    }),
    camera = source.camera;
  function distort([u, v]) {
    const x = (u - camera.cx) / camera.fx,
      y = (v - camera.cy) / camera.fy,
      r = x * x + y * y,
      rad =
        1 +
        (camera.k1 || 0) * r +
        (camera.k2 || 0) * r * r +
        (camera.k3 || 0) * r * r * r;
    return [
      camera.fx *
        (x * rad +
          2 * (camera.p1 || 0) * x * y +
          (camera.p2 || 0) * (r + 2 * x * x)) +
        camera.cx,
      camera.fy *
        (y * rad +
          (camera.p1 || 0) * (r + 2 * y * y) +
          2 * (camera.p2 || 0) * x * y) +
        camera.cy,
    ];
  }
  const health = {
      monitor_id: "brown-fixed",
      calibration: source.calibration,
      camera,
      landmarks: known,
      health: {
        min_landmarks: 3,
        min_observations: 1,
        confirmation_us: "0",
        max_gap_us: "500000",
        rms_limit_m: 0.1,
        max_error_m: 0.2,
      },
    },
    head = guardSource(
      jointSource(
        source,
        runSource(
          config(
            [zone("metric", square(100), 0)],
            source.session_id,
            source.motion.max_tracks || 1000,
          ),
        ),
      ),
      health,
    ),
    paired = original.slice(1).map((v) => ({
      measurement: line(v),
      health: line({
        timestamp_us: v.timestamp_us,
        observations: known.map((v, i) => ({
          landmark_id: v.landmark_id,
          point: distort(ideals[i]),
          covariance: [0.04, 0, 0.04],
        })),
      }),
    })),
    oracle = hostGuard(head, paired),
    cut = oracle.snapshots.findIndex((v) => v.analysis.runs.states.length > 0),
    cp = oracle.snapshots[cut],
    transform = { scale_x: 0.5, scale_y: 1.25, offset_x: -15, offset_y: 8 },
    changed = native("--reframe", [
      { source: { resume: cp.analysis.measurement }, transform },
      ...original.slice(1 + cut),
    ]),
    adapted = clone(cp);
  adapted.analysis.measurement = changed[0].resume;
  // Reframe health calibration/camera exactly like the old measurement converter.
  adapted.health.configuration.calibration = clone(
    adapted.analysis.measurement.configuration.calibration,
  );
  adapted.health.configuration.camera = clone(
    adapted.analysis.measurement.configuration.camera,
  );
  const inputs = changed.slice(1).map((value, i) => {
    const old = paired[cut + i],
      landmark = JSON.parse(old.health);
    landmark.observations.forEach((v) => {
      v.point = [v.point[0] * 0.5 - 15, v.point[1] * 1.25 + 8];
      v.covariance = [
        v.covariance[0] * 0.25,
        v.covariance[1] * 0.625,
        v.covariance[2] * 1.5625,
      ];
    });
    return {
      measurement: line(value),
      health: line(landmark),
      assignments: oracle.wrapped[cut + i].assignments,
    };
  });
  const actual = guard({ resume: adapted }, inputs),
    wanted = guard({ resume: cp }, oracle.wrapped.slice(cut));
  let maximum = 0,
    count = 0;
  function warm(a, b) {
    if (typeof b === "number") {
      const e = Math.abs(a - b);
      maximum = Math.max(maximum, e);
      count++;
      assert.ok(e <= Math.max(1e-11, 3e-8 * Math.abs(b)), `${a} != ${b}`);
    } else if (Array.isArray(b)) {
      assert.equal(a.length, b.length);
      b.forEach((v, i) => warm(a[i], v));
    } else if (b && typeof b === "object") {
      assert.deepEqual(Object.keys(a).sort(), Object.keys(b).sort());
      Object.keys(b).forEach((k) => warm(a[k], b[k]));
    } else assert.equal(a, b);
  }
  assert.ok(cut > 0 && cut < paired.length);
  assert.ok(wanted.frames.some((v) => v.analysis.runs.active.length > 0));
  assert.ok(actual.frames.some((v) => v.analysis.runs.active.length > 0));
  warm(actual.frames, wanted.frames);
  warm(actual.checkpoint.analysis.runs, wanted.checkpoint.analysis.runs);
  t.diagnostic(
    JSON.stringify({
      warm_reframe_maximum_absolute_error: maximum,
      numerical_values: count,
      absolute_tolerance: 1e-11,
      relative_tolerance: 3e-8,
    }),
  );
});

test("independently valid cross checkpoints and raw clock or format mutations are rejected", () => {
  const f = guardFixture(),
    e = hostGuard(f.head, f.frames.slice(0, 4)),
    cp = e.checkpoint;
  for (const mutate of [
    (v) => (v.health.state.streak = null),
    (v) => (v.health.configuration.calibration.matrix[2] = 0.01),
    (v) => (v.analysis.runs.max_tracks = 2),
    (v) =>
      (v.health.state.last_timestamp_us = String(
        BigInt(v.health.state.last_timestamp_us) + 1n,
      )),
  ]) {
    const changed = clone(cp);
    mutate(changed);
    failure(invokeGuard({ resume: changed }, ""));
  }
  const first = e.wrapped[0],
    bad = {
      ...first,
      assignments: line({
        ...JSON.parse(first.assignments),
        timestamp_us: String(
          BigInt(JSON.parse(first.assignments).timestamp_us) + 1n,
        ),
      }),
    };
  failure(invokeGuard(f.head, ndjson([bad])));
  const a = clone(f.head);
  a.health = JSON.parse(a.health);
  failure(invokeGuard(a, ""));
  failure(invokeGuard({ ...f.head, extra: 1 }, ""));
  const normal = { measurement: first.measurement, health: first.health };
  assert.deepEqual(native(guardPreview, [f.head], 2), []);
  close(native(guardPreview, [f.head, normal, normal], 2), [e.previews[0]]);
});

test("portable batch input, old handles and complete output budgets are enforced on both pure entry points", (t) => {
  const f = guardFixture(),
    empty = Array.from({ length: 5000 }, (_, i) => {
      const time = String(i);
      return {
        measurement: line({ timestamp_us: time, observations: [] }),
        health: line({ timestamp_us: time, observations: [] }),
        assignments: line({ timestamp_us: time, footprints: [] }),
      };
    }),
    text = ndjson(empty),
    raw = empty.map((v) => ({ measurement: v.measurement, health: v.health }));
  const resultText = invokeGuard(f.head, text),
    parsed = JSON.parse(resultText);
  let successful = 0,
    outputLength = resultText.length;
  if (parsed.error) {
    failure(resultText);
    assert.match(parsed.error, /output exceeds/);
  } else {
    successful = parsed.frames.length;
    assert.equal(successful, 5000);
    assert.ok(outputLength <= 8 * 1048576);
  }
  const previewResult = unpack(invokeBatchPreview(f.head, ndjson(raw)));
  assert.equal(previewResult.frames.length, 5000);
  assert.match(
    failure(invokeGuard(f.head, ndjson([...empty, empty[0]]))),
    /5000/,
  );
  assert.match(
    failure(invokeBatchPreview(f.head, ndjson([...raw, raw[0]]))),
    /5000/,
  );
  failure(invokeGuard(f.head, " ".repeat(8 * 1048576 + 1)));
  failure(moonground_footprint_run_guarded(" ".repeat(16 * 1048576 + 1)));
  failure(invokeBatchPreview(f.head, " ".repeat(8 * 1048576 + 1)));
  const first = hostGuard(f.head, f.frames.slice(0, 1)).wrapped[0];
  close(guard(f.head, line(first).padEnd(1048576)), guard(f.head, [first]));
  failure(invokeGuard(f.head, line(first).padEnd(1048577)));
  const handles = [];
  try {
    for (let i = 0; i < 64; i++) {
      const r = JSON.parse(
        moonground_create(
          line({ ...f.source, session_id: "guard-handle" + i }),
        ),
      );
      if (r.error) break;
      handles.push(r.handle);
    }
    assert.equal(handles.length, 64);
    assert.equal(batchPreview(f.head, f.frames.slice(0, 1)).frames.length, 1);
    assert.equal(guard(f.head).frames.length, 0);
  } finally {
    handles.forEach((h) => moonground_close(h));
  }
  t.diagnostic(
    JSON.stringify({
      empty_frame_count: 5000,
      successful_formal_frames: successful,
      formal_return_utf16: outputLength,
      preview_frames: previewResult.frames.length,
      preview_return_utf16: line(previewResult).length,
      whole_output_limit_utf16: 8 * 1048576,
    }),
  );
});

test("actual guarded maximum expands every supported face and retains complete reachable run state", (t) => {
  const f = guardFixture(true),
    vertices = Array.from({ length: 32 }, (_, i) => [i - 15.5, i * i - 360]),
    source = clone(f.source);
  source.motion.max_tracks = 128;
  const runHeader = runSource(
      config(
        Array.from({ length: 16 }, (_, i) => zone("z" + i, vertices, 0)),
        source.session_id,
        128,
      ),
    ),
    head = guardSource(jointSource(source, runHeader), f.health),
    raw = [0, 100000].map((time) => ({
      measurement: line({
        timestamp_us: String(time),
        observations: Array.from({ length: 128 }, (_, i) => ({
          track_id: i + 1,
          point: [0, 0],
          covariance: [0.01, 0, 0.01],
        })),
      }),
      health: line({
        timestamp_us: String(time),
        observations: f.health.landmarks.map((v) => ({
          landmark_id: v.landmark_id,
          point: v.ground_m,
          covariance: [0.01, 0, 0.01],
        })),
      }),
    })),
    identities = batchPreview(head, raw).frames,
    wrapped = raw.map((v, i) => ({
      ...v,
      assignments: line(
        bundle(
          identities[i].measurement,
          identities[i].measurement.tracks.map((track) =>
            binding(track, convexShape(vertices)),
          ),
        ),
      ),
    })),
    out = native(guardMode, [head, ...wrapped]),
    cp = native(guardCheckpoint, [head, ...wrapped])[0],
    last = out[1];
  assert.equal(last.analysis.runs.evidence.evidence.length, 2048);
  assert.equal(
    last.analysis.runs.evidence.evidence.reduce(
      (n, v) => n + v.faces.length,
      0,
    ),
    65536,
  );
  assert.equal(cp.analysis.runs.states.length, 2048);
  close(
    native(guardCheckpoint, [{ resume: cp }], 0, [
      "--max-line-bytes",
      "16777216",
    ])[0],
    cp,
  );
  close(guard({ resume: cp }).checkpoint, cp);
  const length = line({ frames: out, checkpoint: cp }).length;
  assert.ok(length > 8 * 1048576);
  failure(invokeGuard(head, ndjson(wrapped)));
  t.diagnostic(
    JSON.stringify({
      maximum_actual_face_expansions: 65536,
      maximum_actual_support_vertex_projections: 2097152,
      ready_targets: 128,
      zones: 16,
      retained_states: 2048,
      whole_equivalent_return_utf16: length,
      checkpoint_utf16: line(cp).length,
    }),
  );
});
