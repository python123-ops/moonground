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
  moonground_footprint_run_windows,
  moonground_footprint_run_window_guarded,
  moonground_footprint_run_window_guarded_preview,
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
        ? value.assignments
          ? JSON.parse(value.assignments)
          : bundle(
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

const windowGuardSource = (guarded, width = 300000, origin = 0) => ({
  guarded: line(guarded),
  window: line({ window_us: String(width), origin_us: String(origin) }),
});
const invokeWindowGuard = (source, frames) =>
  moonground_footprint_run_window_guarded(
    line({ source: line(source), frames }),
  );
const windowGuard = (source, frames = []) =>
  unpack(
    invokeWindowGuard(
      source,
      typeof frames === "string" ? frames : ndjson(frames),
    ),
  );
const invokeDiscovery = (source, frames) =>
  moonground_footprint_run_window_guarded_preview(
    line({ source: line(source), frames }),
  );
const discovery = (source, frames = []) =>
  unpack(
    invokeDiscovery(
      source,
      typeof frames === "string" ? frames : ndjson(frames),
    ),
  );
const windowMode = "--guarded-footprint-run-windows",
  windowCheckpoint = "--guarded-footprint-run-windows-checkpoint",
  windowPreview = "--preview-guarded-footprint-run-window";
const oldWindows = (source, frames = []) =>
  unpack(
    moonground_footprint_run_windows(
      line({ source: line(source), frames: ndjson(frames) }),
    ),
  );
function windowComponents(head, raw, cut = 0, width = 300000, origin = 0) {
  const old = hostGuard(head, raw),
    initial = old.snapshots[cut],
    measured = old.frames
      .slice(cut)
      .map((v, i) =>
        pair(
          v.analysis.measurement,
          Object.hasOwn(old.wrapped[cut + i], "assignments")
            ? JSON.parse(old.wrapped[cut + i].assignments)
            : { timestamp_us: v.health.timestamp_us, footprints: [] },
        ),
      ),
    windows = oldWindows(
      {
        runs: line({ resume: initial.analysis.runs }),
        window: line({ window_us: String(width), origin_us: String(origin) }),
      },
      measured,
    ),
    original = cut ? { resume: initial } : head;
  close(guard(head, old.wrapped), {
    frames: old.frames,
    checkpoint: old.checkpoint,
  });
  return {
    head: windowGuardSource(original, width, origin),
    old,
    wrapped: old.wrapped.slice(cut),
    previews: old.previews.slice(cut),
    frames: old.frames
      .slice(cut)
      .map((v, i) => ({
        ...v,
        kind: v.kind.endsWith("projection_replaced")
          ? "footprint_run_window_guarded_projection_replaced"
          : "footprint_run_window_guarded_frame",
        analysis: {
          schema_version: "0.1.0",
          kind: "footprint_run_window_analysis_frame",
          measurement: v.analysis.measurement,
          windows: windows.frames[i],
        },
      })),
    checkpoint: {
      format: "moonground.footprint-run-window-guarded",
      checkpoint_version: "1",
      analysis: {
        format: "moonground.footprint-run-window-analysis",
        checkpoint_version: "1",
        measurement: old.checkpoint.analysis.measurement,
        windows: windows.checkpoint,
      },
      health: old.checkpoint.health,
    },
  };
}

test("full old guarded and independent window paths match with genuine discovery and no shadow run CP", () => {
  const f = guardFixture(),
    e = windowComponents(f.head, f.frames),
    before = windowGuard(e.head).checkpoint;
  close(windowGuard(e.head, e.wrapped), {
    frames: e.frames,
    checkpoint: e.checkpoint,
  });
  close(native(windowMode, [e.head, ...e.wrapped]), e.frames);
  close(discovery(e.head, f.frames), { frames: e.previews });
  close(windowGuard(e.head).checkpoint, before);
  assert.equal(Object.hasOwn(e.checkpoint.analysis, "runs"), false);
  assert.ok(e.frames.some((v) => v.decision === "blocked"));
  assert.ok(e.frames.some((v) => v.decision === "allowed"));
});

test("all selected cuts and genuine started baselines resume in four runtime directions", (t) => {
  let cuts = 0,
    comparisons = 0;
  for (const [instant, baseline] of [
    [false, 0],
    [true, 0],
    [true, 3],
  ]) {
    const f = guardFixture(instant),
      e = windowComponents(f.head, f.frames, baseline);
    for (let cut = 0; cut <= e.wrapped.length; cut++) {
      const js = windowGuard(e.head, e.wrapped.slice(0, cut)).checkpoint,
        n = native(windowCheckpoint, [e.head, ...e.wrapped.slice(0, cut)])[0];
      for (const cp of [js, n]) {
        close(windowGuard({ resume: cp }, e.wrapped.slice(cut)), {
          frames: e.frames.slice(cut),
          checkpoint: e.checkpoint,
        });
        close(
          native(windowMode, [{ resume: cp }, ...e.wrapped.slice(cut)]),
          e.frames.slice(cut),
        );
        close(
          native(windowCheckpoint, [
            { resume: cp },
            ...e.wrapped.slice(cut),
          ])[0],
          e.checkpoint,
        );
        comparisons += 2;
      }
      if (cut < e.wrapped.length) {
        const v = e.wrapped[cut];
        close(
          native(windowPreview, [
            { resume: js },
            { measurement: v.measurement, health: v.health },
          ])[0],
          e.previews[cut],
        );
      }
      cuts++;
    }
    if (baseline) {
      assert.equal(
        windowGuard(e.head).checkpoint.analysis.windows.current_window,
        null,
      );
      assert.equal(
        e.checkpoint.analysis.windows.baseline_timestamp_us,
        JSON.parse(f.frames[baseline - 1].measurement).timestamp_us,
      );
    }
  }
  t.diagnostic(
    JSON.stringify({
      cut_points: cuts,
      runtime_directions: 4,
      comparisons,
      original_decimal_clocks_above_2pow53: true,
    }),
  );
});

test("first Healthy identity and late support failures preserve all health motion run window state", () => {
  const f = guardFixture(),
    e = windowComponents(f.head, f.frames.slice(0, 4));
  for (const [index, wrongIdentity] of [
    [2, true],
    [3, false],
  ]) {
    const failed = clone(e.wrapped[index]),
      d = JSON.parse(failed.assignments);
    if (wrongIdentity) d.footprints[0].segment_id = "99";
    else d.footprints.forEach((v) => (v.shape = diskShape(1e-30)));
    failed.assignments = line(d);
    failure(
      invokeWindowGuard(e.head, ndjson([...e.wrapped.slice(0, index), failed])),
    );
    close(
      native(windowMode, [e.head, ...e.wrapped.slice(0, index), failed], 2),
      e.frames.slice(0, index),
    );
    assert.deepEqual(
      native(
        windowCheckpoint,
        [e.head, ...e.wrapped.slice(0, index), failed],
        2,
      ),
      [],
    );
    const cp = windowGuard(e.head, e.wrapped.slice(0, index)).checkpoint;
    close(windowGuard({ resume: cp }, e.wrapped.slice(index)), {
      frames: e.frames.slice(index),
      checkpoint: e.checkpoint,
    });
  }
  const blocked = clone(e.wrapped[0]),
    o = JSON.parse(blocked.measurement);
  o.observations.forEach((v) => {
    v.point = [1e308, -1e308];
    v.covariance = [1e300, 0, 1e300];
  });
  blocked.measurement = line(o);
  const result = windowGuard(e.head, [blocked]).frames[0];
  assert.deepEqual(result.analysis.measurement.tracks, []);
  assert.deepEqual(result.suppressed_track_ids, [1, 2]);
  for (const mutate of [
    (o) => o.observations.push(clone(o.observations[0])),
    (o) => (o.observations[0].covariance = [1, 2, 1]),
  ]) {
    const bad = clone(blocked),
      objects = JSON.parse(bad.measurement);
    mutate(objects);
    bad.measurement = line(objects);
    failure(invokeWindowGuard(e.head, ndjson([bad])));
  }
});

function sparseWindowFixture(times, shapeSince = 0, samples = 1) {
  const f = guardFixture(true);
  f.source.motion.max_gap_us = "100";
  f.health.health.max_gap_us = "4";
  f.health.health.min_observations = samples;
  f.runHeader.options = line({
    min_samples: "1",
    confirmation_us: "0",
    max_gap_us: "100",
  });
  f.head = guardSource(jointSource(f.source, f.runHeader), f.health);
  const raw = times.map((t) => ({
      measurement: line({
        timestamp_us: String(t),
        observations: [
          { track_id: 1, point: [0.5, 0.5], covariance: [0.01, 0, 0.01] },
        ],
      }),
      health: line({
        timestamp_us: String(t),
        observations: f.health.landmarks.map((v) => ({
          landmark_id: v.landmark_id,
          point: v.ground_m,
          covariance: [0.01, 0, 0.01],
        })),
      }),
    })),
    old = hostGuard(f.head, raw);
  for (let i = 0; i < raw.length; i++)
    if (times[i] < shapeSince)
      raw[i].assignments = line({
        timestamp_us: String(times[i]),
        footprints: [],
      });
  return windowComponents(f.head, raw, 0, 100);
}
function separatelyValid(cp) {
  native("--analyze-footprint-run-windows-checkpoint", [
    { resume: cp.analysis },
  ]);
  guard({
    resume: fullCP(
      {
        format: "moonground.footprint-run-analysis",
        checkpoint_version: "1",
        measurement: cp.analysis.measurement,
        runs: cp.analysis.windows.runs,
      },
      cp.health,
    ),
  });
}
test("separately legal health and window histories reject local gap exact count and restart-slot contradictions", () => {
  const local = clone(sparseWindowFixture([0, 1, 8, 20], 8).checkpoint);
  local.health.state.streak.since_us = "0";
  local.analysis.measurement.motion.tracks[0].accepted_count = 10;
  local.analysis.windows.current_window.input_frames = "10";
  local.analysis.windows.runs.states.forEach((s) => (s.run.sample_count = "9"));
  separatelyValid(local);
  failure(invokeWindowGuard({ resume: local }, ""));
  const localGood = clone(local);
  localGood.health.configuration.health.max_gap_us = "9";
  close(windowGuard({ resume: localGood }).checkpoint, localGood);
  const restart = clone(sparseWindowFixture([0, 1, 10, 11], 11).checkpoint);
  restart.analysis.measurement.motion.tracks[0].accepted_count = 2;
  restart.analysis.windows.current_window.input_frames = "10";
  separatelyValid(restart);
  failure(invokeWindowGuard({ resume: restart }, ""));
  restart.analysis.windows.current_window.input_frames = "9";
  close(windowGuard({ resume: restart }).checkpoint, restart);
  const exact = clone(sparseWindowFixture([0, 1, 2], 0, 5).checkpoint);
  exact.health.state.streak.observations = 2;
  separatelyValid(exact);
  failure(invokeWindowGuard({ resume: exact }, ""));
  const f = guardFixture(),
    e = windowComponents(f.head, f.frames.slice(0, 1)),
    v = e.wrapped[0];
  for (const bad of [
    { ...v, extra: true },
    '{"measurement":"bad",' + line(v).slice(1),
    {
      ...v,
      measurement: v.measurement.replace(
        '"track_id":2',
        '"track_id":2.0000000000000001',
      ),
    },
    {
      ...v,
      assignments: line({
        timestamp_us: JSON.parse(v.measurement).timestamp_us,
        footprints: [{ track_id: 1, segment_id: "1", shape: diskShape() }],
      }),
    },
  ])
    failure(invokeWindowGuard(e.head, ndjson([bad])));
});

test("explicit projection replacement occupies a cold empty window barrier and discovery advances real identities", () => {
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
    e = windowComponents(f.head, raw),
    actual = windowGuard(e.head, e.wrapped);
  close(actual, { frames: e.frames, checkpoint: e.checkpoint });
  close(discovery(e.head, raw), { frames: e.previews });
  assert.equal(
    actual.frames.at(-1).kind,
    "footprint_run_window_guarded_projection_replaced",
  );
  assert.equal(actual.frames.at(-1).health.status, "insufficient");
  assert.equal(actual.checkpoint.analysis.windows.runs.states.length, 0);
  assert.equal(
    actual.checkpoint.analysis.windows.current_window.last_timestamp_us,
    stamp,
  );
  const cp = actual.checkpoint,
    last = clone(f.frames[0]);
  for (const key of ["measurement", "health"]) {
    const v = JSON.parse(last[key]);
    v.timestamp_us = String(BigInt(stamp) + 100000n);
    last[key] = line(v);
  }
  const next = discovery({ resume: cp }, [last]).frames[0];
  assert.equal(next.decision, "allowed");
  assert.ok(next.measurement.tracks.every((v) => BigInt(v.segment_id) >= 3n));
});

test("warm Brown reframe preserves joint health evidence metric run suffix and window counts", (t) => {
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
    camera = source.camera,
    known = ideals.map((p, i) => {
      const z = H[6] * p[0] + H[7] * p[1] + H[8];
      return {
        landmark_id: String(i),
        ground_m: [
          (H[0] * p[0] + H[1] * p[1] + H[2]) / z,
          (H[3] * p[0] + H[4] * p[1] + H[5]) / z,
        ],
      };
    });
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
    raw = original
      .slice(1)
      .map((v) => ({
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
    e = windowComponents(head, raw),
    cut = e.old.snapshots.findIndex((v) => v.analysis.runs.states.length > 0),
    cp = windowGuard(e.head, e.wrapped.slice(0, cut)).checkpoint,
    transform = { scale_x: 0.5, scale_y: 1.25, offset_x: -15, offset_y: 8 },
    changed = native("--reframe", [
      { source: { resume: cp.analysis.measurement }, transform },
      ...original.slice(1 + cut),
    ]),
    adapted = clone(cp);
  adapted.analysis.measurement = changed[0].resume;
  adapted.health.configuration.calibration = clone(
    adapted.analysis.measurement.configuration.calibration,
  );
  adapted.health.configuration.camera = clone(
    adapted.analysis.measurement.configuration.camera,
  );
  const transformed = changed.slice(1).map((v, i) => {
      const landmark = JSON.parse(raw[cut + i].health);
      landmark.observations.forEach((p) => {
        p.point = [p.point[0] * 0.5 - 15, p.point[1] * 1.25 + 8];
        p.covariance = [
          p.covariance[0] * 0.25,
          p.covariance[1] * 0.625,
          p.covariance[2] * 1.5625,
        ];
      });
      return {
        measurement: line(v),
        health: line(landmark),
        assignments: e.wrapped[cut + i].assignments,
      };
    }),
    actual = windowGuard({ resume: adapted }, transformed),
    wanted = windowGuard({ resume: cp }, e.wrapped.slice(cut));
  let maximum = 0,
    count = 0;
  function warm(a, b) {
    if (typeof b === "number") {
      const d = Math.abs(a - b);
      maximum = Math.max(maximum, d);
      count++;
      assert.ok(d <= Math.max(1e-11, 3e-8 * Math.abs(b)), `${a} != ${b}`);
    } else if (Array.isArray(b)) {
      assert.equal(a.length, b.length);
      b.forEach((v, i) => warm(a[i], v));
    } else if (b && typeof b === "object") {
      assert.deepEqual(Object.keys(a).sort(), Object.keys(b).sort());
      Object.keys(b).forEach((k) => warm(a[k], b[k]));
    } else assert.equal(a, b);
  }
  assert.ok(cut > 0 && cut < raw.length);
  assert.ok(
    actual.frames.some((v) => v.analysis.windows.runs.active.length > 0),
  );
  assert.ok(
    wanted.frames.some((v) => v.analysis.windows.runs.active.length > 0),
  );
  warm(actual.frames, wanted.frames);
  warm(actual.checkpoint.analysis.windows, wanted.checkpoint.analysis.windows);
  t.diagnostic(
    JSON.stringify({
      warm_reframe_maximum_absolute_error: maximum,
      numerical_values: count,
      relative_tolerance: 3e-8,
      absolute_tolerance: 1e-11,
    }),
  );
});

test("actual empty5000 native input and pure complete budgets remain distinct with handle-free discovery", (t) => {
  const f = guardFixture(),
    head = windowGuardSource(f.head),
    empty = Array.from({ length: 5000 }, (_, i) => ({
      measurement: line({ timestamp_us: String(i), observations: [] }),
      health: line({ timestamp_us: String(i), observations: [] }),
      assignments: line({ timestamp_us: String(i), footprints: [] }),
    })),
    text = invokeWindowGuard(head, ndjson(empty)),
    value = JSON.parse(text),
    raw = empty.map(({ measurement, health }) => ({ measurement, health }));
  let successful = 0;
  if (value.error) assert.match(failure(text), /output exceeds/);
  else {
    successful = value.frames.length;
    assert.equal(successful, 5000);
    assert.ok(text.length <= 8 * 1048576);
  }
  const nativeOut = native(windowMode, [head, ...empty]);
  assert.equal(nativeOut.length, 5000);
  const previews = discovery(head, raw);
  assert.equal(previews.frames.length, 5000);
  assert.match(
    failure(invokeWindowGuard(head, ndjson([...empty, empty[0]]))),
    /5000/,
  );
  assert.match(
    failure(invokeDiscovery(head, ndjson([...raw, raw[0]]))),
    /5000/,
  );
  failure(invokeWindowGuard(head, " ".repeat(8 * 1048576 + 1)));
  failure(
    moonground_footprint_run_window_guarded(" ".repeat(16 * 1048576 + 1)),
  );
  const first = windowComponents(f.head, f.frames.slice(0, 1)).wrapped[0];
  close(
    windowGuard(head, line(first).padEnd(1048576)),
    windowGuard(head, [first]),
  );
  failure(invokeWindowGuard(head, line(first).padEnd(1048577)));
  const handles = [];
  try {
    for (let i = 0; i < 64; i++) {
      const v = JSON.parse(
        moonground_create(line({ ...f.source, session_id: "occupied" + i })),
      );
      if (v.error) break;
      handles.push(v.handle);
    }
    assert.equal(handles.length, 64);
    assert.equal(discovery(head, raw.slice(0, 1)).frames.length, 1);
  } finally {
    handles.forEach((h) => moonground_close(h));
  }
  t.diagnostic(
    JSON.stringify({
      empty_frame_count: 5000,
      native_accepted_frames: nativeOut.length,
      successful_pure_frames: successful,
      pure_return_utf16: text.length,
      preview_frames: previews.frames.length,
      preview_return_utf16: line(previews).length,
      whole_output_limit_utf16: 8 * 1048576,
    }),
  );
});

test("maximum actual supported geometry and complete reachable guarded window checkpoint are measured", (t) => {
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
    head = windowGuardSource(
      guardSource(jointSource(source, runHeader), f.health),
    ),
    raw = [0, 100000].map((t) => ({
      measurement: line({
        timestamp_us: String(t),
        observations: Array.from({ length: 128 }, (_, i) => ({
          track_id: i + 1,
          point: [0, 0],
          covariance: [0.01, 0, 0.01],
        })),
      }),
      health: line({
        timestamp_us: String(t),
        observations: f.health.landmarks.map((v) => ({
          landmark_id: v.landmark_id,
          point: v.ground_m,
          covariance: [0.01, 0, 0.01],
        })),
      }),
    })),
    ids = discovery(head, raw).frames,
    wrapped = raw.map((v, i) => ({
      ...v,
      assignments: line(
        bundle(
          ids[i].measurement,
          ids[i].measurement.tracks.map((t) =>
            binding(t, convexShape(vertices)),
          ),
        ),
      ),
    })),
    out = native(windowMode, [head, ...wrapped]),
    cp = native(windowCheckpoint, [head, ...wrapped])[0],
    last = out[1];
  assert.equal(last.analysis.windows.runs.evidence.evidence.length, 2048);
  assert.equal(
    last.analysis.windows.runs.evidence.evidence.reduce(
      (n, v) => n + v.faces.length,
      0,
    ),
    65536,
  );
  assert.equal(cp.analysis.windows.runs.states.length, 2048);
  close(windowGuard({ resume: cp }).checkpoint, cp);
  close(
    native(windowCheckpoint, [{ resume: cp }], 0, [
      "--max-line-bytes",
      "16777216",
    ])[0],
    cp,
  );
  const length = line({ frames: out, checkpoint: cp }).length;
  assert.ok(length > 8 * 1048576);
  failure(invokeWindowGuard(head, ndjson(wrapped)));
  t.diagnostic(
    JSON.stringify({
      maximum_actual_face_expansions: 65536,
      maximum_actual_support_vertex_projections: 2097152,
      ready_targets: 128,
      zones: 16,
      retained_states: 2048,
      equivalent_whole_return_utf16: length,
      checkpoint_utf16: line(cp).length,
    }),
  );
});
