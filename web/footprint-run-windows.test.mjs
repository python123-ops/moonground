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
  moonground_footprint_run_windows,
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

const windowMode = "--footprint-run-windows",
  windowCheckpoint = "--footprint-run-windows-checkpoint",
  MAX = 9223372036854775807n;
const reasons = [
  "gap_exceeded",
  "segment_closed",
  "segment_changed",
  "missing_target",
  "unavailable_evidence",
  "shape_changed",
  "indeterminate_evidence",
  "decision_changed",
];
const windowSource = (source, width = 3n, origin = 0n) => ({
  runs: line(source),
  window: line({ window_us: String(width), origin_us: String(origin) }),
});
const invokeWindow = (source, frames) =>
  moonground_footprint_run_windows(line({ source: line(source), frames }));
const windows = (source, frames = []) =>
  unpack(
    invokeWindow(source, typeof frames === "string" ? frames : ndjson(frames)),
  );
function offlineWindows(initial, width, origin, values) {
  const buckets = new Map(),
    openings = new Map(),
    frames = [];
  let previous = initial.states.map((s) => s.run),
    current = null,
    lastIndex = null;
  for (const value of values) {
    const t = BigInt(value.evidence.timestamp_us),
      index = (t - origin) / width;
    let closed = null,
      skipped = 0n;
    if (!buckets.has(index)) {
      if (lastIndex !== null) {
        closed = clone(current);
        skipped = index - lastIndex - 1n;
      }
      buckets.set(index, []);
      openings.set(index, clone(previous));
      lastIndex = index;
    }
    const group = buckets.get(index);
    group.push(value);
    const opening = openings.get(index),
      start = origin + index * width,
      end = start + width;
    current = {
      start_us: String(start),
      end_exclusive_us: end <= MAX ? String(end) : null,
      first_timestamp_us: group[0].evidence.timestamp_us,
      last_timestamp_us: String(t),
      input_frames: String(group.length),
      zones: initial.zones.map((zone) => {
        const id = zone.zone_id,
          confirmations = group
            .flatMap((v) => v.confirmed)
            .filter((v) => v.zone_id === id),
          endings = group
            .flatMap((v) => v.closed)
            .filter((v) => v.run.zone_id === id),
          active = opening.filter((v) => v.zone_id === id);
        return {
          zone_id: id,
          opening_active: String(active.length),
          opening_confirmed: String(active.filter((v) => v.confirmed).length),
          started: String(
            group.reduce(
              (n, v) =>
                n +
                v.active.filter(
                  (r) =>
                    r.zone_id === id &&
                    r.first_timestamp_us === v.evidence.timestamp_us,
                ).length,
              0,
            ),
          ),
          confirmed_inside: String(
            confirmations.filter((v) => v.decision === "inside").length,
          ),
          confirmed_outside: String(
            confirmations.filter((v) => v.decision === "outside").length,
          ),
          endings: reasons.map((reason) => ({
            reason,
            confirmed: String(
              endings.filter((v) => v.reason === reason && v.run.confirmed)
                .length,
            ),
            unconfirmed: String(
              endings.filter((v) => v.reason === reason && !v.run.confirmed)
                .length,
            ),
          })),
        };
      }),
    };
    frames.push({
      schema_version: "0.1.0",
      kind: "footprint_run_window_frame",
      runs: value,
      statistics: {
        session_id: initial.session_id,
        timestamp_us: String(t),
        closed_window: closed,
        current_window: clone(current),
        unobserved_windows: String(skipped),
      },
    });
    previous = value.active;
  }
  return { frames, current };
}
function windowFixture() {
  const position = runPosition(),
    header = runSource(position, {
      max_gap_us: "10",
      confirmation_us: "2",
      min_samples: "2",
    }),
    start = 9007199254740993n,
    inputs = [
      "inside",
      "inside",
      "inside",
      "outside",
      "outside",
      "outside",
      "indeterminate",
      "inside",
    ].map((kind, i) => runSample(position, start + BigInt(i), kind)),
    old = runs(header, inputs),
    initial = runs(header).checkpoint,
    expected = offlineWindows(initial, 3n, 0n, old.frames);
  return {
    position,
    header,
    inputs,
    old,
    initial,
    head: windowSource(header),
    expected: {
      frames: expected.frames,
      checkpoint: {
        format: "moonground.footprint-run-windows",
        checkpoint_version: "1",
        runs: old.checkpoint,
        window_us: "3",
        origin_us: "0",
        baseline_timestamp_us: null,
        current_window: expected.current,
      },
    },
  };
}

test("old run output and independent quotient groups match first-confirmed and classified ending counts", () => {
  const f = windowFixture();
  close(windows(f.head, f.inputs), f.expected);
  close(native(windowMode, [f.head, ...f.inputs]), f.expected.frames);
  close(
    native(windowCheckpoint, [f.head, ...f.inputs])[0],
    f.expected.checkpoint,
  );
  assert.equal(
    f.old.frames
      .flatMap((v) => v.confirmed)
      .filter((v) => v.decision === "inside").length,
    1,
  );
  assert.equal(
    f.old.frames
      .flatMap((v) => v.confirmed)
      .filter((v) => v.decision === "outside").length,
    1,
  );
  const instant = runSource(f.position, {
      min_samples: "1",
      confirmation_us: "0",
    }),
    inputs = [runSample(f.position, 0), runSample(f.position, 1, "outside")],
    out = windows(windowSource(instant, 10n), inputs).frames[1];
  assert.equal(out.runs.confirmed.length, 1);
  assert.equal(out.runs.closed.length, 1);
  assert.equal(out.statistics.current_window.zones[0].started, "2");
  assert.equal(
    out.statistics.current_window.zones[0].endings[7].confirmed,
    "1",
  );
});

test("all window cuts resume in four native and JavaScript directions preserving full shape checkpoints", (t) => {
  const f = windowFixture();
  let comparisons = 0;
  for (let cut = 0; cut <= f.inputs.length; cut++) {
    const a = windows(f.head, f.inputs.slice(0, cut)).checkpoint,
      b = native(windowCheckpoint, [f.head, ...f.inputs.slice(0, cut)])[0];
    close(a, b);
    for (const cp of [a, b]) {
      close(windows({ resume: cp }, f.inputs.slice(cut)), {
        frames: f.expected.frames.slice(cut),
        checkpoint: f.expected.checkpoint,
      });
      comparisons++;
      close(
        native(windowMode, [{ resume: cp }, ...f.inputs.slice(cut)]),
        f.expected.frames.slice(cut),
      );
      close(
        native(windowCheckpoint, [{ resume: cp }, ...f.inputs.slice(cut)])[0],
        f.expected.checkpoint,
      );
      comparisons++;
    }
  }
  t.diagnostic(
    JSON.stringify({
      cut_points: f.inputs.length + 1,
      runtime_directions: 4,
      continuations: comparisons,
      first_timestamp: f.old.frames[0].evidence.timestamp_us,
    }),
  );
});

test("started monitor baselines do not backfill confirmed runs and terminal Int64 windows stay half open", () => {
  const f = windowFixture(),
    saved = runs(f.header, f.inputs.slice(0, 3)).checkpoint,
    head = windowSource({ resume: saved }, 100n),
    future = f.inputs.slice(3, 6),
    old = runs({ resume: saved }, future),
    expected = offlineWindows(saved, 100n, 0n, old.frames),
    actual = windows(head, future);
  assert.equal(windows(head).checkpoint.current_window, null);
  close(actual.frames, expected.frames);
  assert.equal(
    actual.frames[0].statistics.current_window.zones[0].opening_confirmed,
    "1",
  );
  assert.equal(
    actual.frames[0].statistics.current_window.zones[0].confirmed_inside,
    "0",
  );
  const h = runSource(f.position, {
      max_gap_us: String(MAX),
      min_samples: "1",
      confirmation_us: "0",
    }),
    terminal = windows(windowSource(h, MAX), [
      runSample(f.position, 0),
      runSample(f.position, MAX - 1n),
      runSample(f.position, MAX),
    ]).frames;
  assert.equal(
    terminal[1].statistics.current_window.end_exclusive_us,
    String(MAX),
  );
  assert.equal(terminal[2].statistics.current_window.start_us, String(MAX));
  assert.equal(terminal[2].statistics.current_window.end_exclusive_us, null);
  const jump = windows(windowSource(h, 1n), [
    runSample(f.position, 0),
    runSample(f.position, MAX),
  ]).frames[1];
  assert.equal(jump.statistics.unobserved_windows, String(MAX - 1n));
});

test("flow-balanced reachable MAX counters reject late reduction atomically and corrected same-time continuation succeeds", () => {
  const position = config(
      [zone("workspace", undefined, 0)],
      "window-max-counter",
      2,
    ),
    h = runSource(position, {
      max_gap_us: String(MAX),
      min_samples: "1",
      confirmation_us: "0",
    }),
    head = windowSource(h, MAX),
    measurement = frame(position, MAX - 2n, [
      track(MAX - 2n, undefined, undefined, 1),
      track(MAX - 2n, undefined, undefined, 2),
    ]),
    input = pair(
      measurement,
      bundle(
        measurement,
        measurement.tracks.map((v) => binding(v, diskShape(0.125))),
      ),
    ),
    cp = windows(head, [input]).checkpoint,
    row = cp.current_window.zones[0];
  cp.current_window.first_timestamp_us = "0";
  cp.current_window.input_frames = String(MAX / 2n + 1n);
  row.started = String(MAX);
  row.confirmed_inside = String(MAX);
  row.endings[5].confirmed = String(MAX - 2n);
  close(windows({ resume: cp }).checkpoint, cp);
  close(native(windowCheckpoint, [{ resume: cp }])[0], cp);
  const next = clone(measurement);
  next.timestamp_us = String(MAX - 1n);
  next.tracks.forEach((v) => {
    v.last_accepted_timestamp_us = String(MAX - 1n);
    v.position_m = [2, 0.5];
  });
  const bad = pair(
    next,
    bundle(
      next,
      next.tracks.map((v) => binding(v, diskShape(0.125))),
    ),
  );
  failure(invokeWindow({ resume: cp }, ndjson([bad])));
  assert.deepEqual(native(windowCheckpoint, [{ resume: cp }, bad], 2), []);
  next.tracks.forEach((v) => (v.position_m = [0.5, 0.5]));
  const corrected = pair(
      next,
      bundle(
        next,
        next.tracks.map((v) => binding(v, diskShape(0.125))),
      ),
    ),
    result = windows({ resume: cp }, [corrected]);
  assert.equal(
    result.frames[0].statistics.current_window.zones[0].started,
    String(MAX),
  );
  assert.equal(result.frames[0].runs.active[0].sample_count, "2");
  close(windows({ resume: cp }).checkpoint, cp);
});

test("strict aggregate flow sparse suffix and original raw binding failures expose only errors", () => {
  const position = runPosition(),
    header = runSource(position, { min_samples: "1", confirmation_us: "0" }),
    head = windowSource(header, 10n),
    inputs = [0, 1, 2].map((t) => runSample(position, t)),
    cp = windows(head, inputs).checkpoint;
  for (const change of [
    (v) => (v.current_window = null),
    (v) => (v.current_window.zones[0].started = "0"),
    (v) => (v.current_window.zones[0].confirmed_inside = "0"),
    (v) => (v.current_window.input_frames = "2"),
    (v) => (v.runs.states[0].run.sample_count = "2"),
    (v) => v.current_window.zones[0].endings.reverse(),
    (v) => (v.current_window.zones[0].endings[0].unconfirmed = "1"),
  ]) {
    const bad = clone(cp);
    change(bad);
    failure(invokeWindow({ resume: bad }, ""));
  }
  failure(invokeWindow({ ...head, extra: 1 }, ""));
  failure(
    invokeWindow({ ...head, window: '{"window_us":3.0000000000000001}' }, ""),
  );
  failure(
    invokeWindow(
      head,
      ndjson([
        {
          ...inputs[0],
          assignments: inputs[0].assignments.replace(
            '"track_id":1',
            '"track_id":1.0000000000000001',
          ),
        },
      ]),
    ),
  );
  failure(
    invokeWindow(
      head,
      ndjson(['{"measurement":"bad",' + line(inputs[0]).slice(1)]),
    ),
  );
  const late = windowSource(header, 10n, 99n);
  failure(invokeWindow(late, ndjson([runSample(position, 98)])));
  assert.equal(
    windows(late, [runSample(position, 99)]).frames[0].runs.active[0]
      .sample_count,
    "1",
  );
});

test("raw batch return and legacy handle budgets are measured on actual 5000 empty frames", (t) => {
  const f = windowFixture(),
    empty = Array.from({ length: 5000 }, (_, i) => {
      const m = frame(f.position, i, []);
      return pair(m, { timestamp_us: String(i), footprints: [] });
    }),
    text = invokeWindow(f.head, ndjson(empty)),
    parsed = JSON.parse(text);
  let success = 0;
  if (parsed.error) {
    failure(text);
    assert.match(parsed.error, /output exceeds/);
  } else {
    success = parsed.frames.length;
    assert.equal(success, 5000);
    assert.ok(text.length <= 8 * 1048576);
  }
  assert.match(
    failure(invokeWindow(f.head, ndjson([...empty, empty[0]]))),
    /5000/,
  );
  failure(invokeWindow(f.head, " ".repeat(8 * 1048576 + 1)));
  failure(moonground_footprint_run_windows(" ".repeat(16 * 1048576 + 1)));
  close(
    windows(f.head, line(empty[0]).padEnd(1048576)),
    windows(f.head, [empty[0]]),
  );
  failure(invokeWindow(f.head, line(empty[0]).padEnd(1048577)));
  failure(invokeWindow(line(f.head).padEnd(8388620), ""));
  const handles = [];
  try {
    for (let i = 0; i < 64; i++) {
      const r = JSON.parse(
        moonground_create(
          line({ session_id: "window-handle" + i, mode: "ground" }),
        ),
      );
      assert.equal(r.error, undefined);
      handles.push(r.handle);
    }
    assert.equal(windows(f.head).frames.length, 0);
  } finally {
    handles.forEach((h) => moonground_close(h));
  }
  t.diagnostic(
    JSON.stringify({
      empty_frame_count: 5000,
      successful_formal_frames: success,
      whole_return_utf16: text.length,
      whole_output_limit_utf16: 8 * 1048576,
    }),
  );
});

test("actual maximum expanded geometry and retained full checkpoint remain bounded separately from output budget", (t) => {
  const vertices = Array.from({ length: 32 }, (_, i) => [
      i - 15.5,
      i * i - 360,
    ]),
    position = config(
      Array.from({ length: 16 }, (_, i) => zone("z" + i, vertices, 0)),
      "window-max-work",
      128,
    ),
    header = runSource(position, { min_samples: "1", confirmation_us: "0" }),
    head = windowSource(header, 10n),
    measurement = frame(
      position,
      0,
      Array.from({ length: 128 }, (_, i) => track(0, [0, 0], undefined, i + 1)),
    ),
    input = pair(
      measurement,
      bundle(
        measurement,
        measurement.tracks.map((v) => binding(v, convexShape(vertices))),
      ),
    ),
    out = native(windowMode, [head, input]),
    cp = native(windowCheckpoint, [head, input])[0];
  assert.equal(out[0].runs.evidence.evidence.length, 2048);
  assert.equal(
    out[0].runs.evidence.evidence.reduce((n, v) => n + v.faces.length, 0),
    65536,
  );
  assert.equal(cp.runs.states.length, 2048);
  close(
    native(windowCheckpoint, [{ resume: cp }], 0, [
      "--max-line-bytes",
      "16777216",
    ])[0],
    cp,
  );
  close(windows({ resume: cp }).checkpoint, cp);
  const length = line({ frames: out, checkpoint: cp }).length;
  assert.ok(length > 8 * 1048576);
  failure(invokeWindow(head, ndjson([input])));
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
