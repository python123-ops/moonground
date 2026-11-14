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

test("AND thresholds confirm sampled span once and current evidence remains exact v25", () => {
  const p = runPosition(),
    source = runSource(p, runOptions),
    inputs = [0, 1, 2, 3].map((t) => runSample(p, t)),
    actual = runs(source, inputs);
  assert.deepEqual(
    actual.frames.map((v) => v.confirmed.length),
    [0, 0, 1, 0],
  );
  assert.deepEqual(
    actual.frames.map((v) => v.active[0].sample_count),
    ["1", "2", "3", "4"],
  );
  assert.deepEqual(
    actual.frames.map((v) => v.active[0].sample_span_us),
    ["0", "1", "2", "3"],
  );
  const current = evaluate(p, inputs).frames;
  actual.frames.forEach((v, i) => assert.deepEqual(v.evidence, current[i]));
  assert.equal(
    actual.frames[0].evidence_scope,
    "current_target_footprint_confirmed_sample_runs",
  );
  const instant = runs(
    runSource(p, { ...runOptions, min_samples: "1", confirmation_us: "0" }),
    [inputs[0]],
  );
  assert.equal(instant.frames[0].confirmed.length, 1);
  const byCount = runs(
    runSource(p, { ...runOptions, min_samples: "3", confirmation_us: "0" }),
    inputs,
  );
  assert.deepEqual(
    byCount.frames.map((v) => v.confirmed.length),
    [0, 0, 1, 0],
  );
  close(actual.frames, native("--footprint-runs", [source, ...inputs]));
  assert.deepEqual(
    actual.checkpoint,
    native("--footprint-runs-checkpoint", [source, ...inputs])[0],
  );
});

test("all interruption reasons keep fixed priority and never interpret unknown as Outside", () => {
  const p = runPosition(),
    source = runSource(p, runOptions),
    cases = [
      [
        "gap_exceeded",
        runSample(p, 11, "rejected", diskShape(0.25), "2", ["1"]),
      ],
      [
        "segment_closed",
        runSample(p, 2, "rejected", diskShape(0.25), "2", ["1"]),
      ],
      ["segment_changed", runSample(p, 2, "uncertain", diskShape(0.25), "2")],
      ["missing_target", runSample(p, 2, "projection")],
      ["missing_target", runSample(p, 2, "absent")],
      ["unavailable_evidence", runSample(p, 2, "missing")],
      ["unavailable_evidence", runSample(p, 2, "uncertain")],
      ["shape_changed", runSample(p, 2, "indeterminate", diskShape(0.25))],
      ["indeterminate_evidence", runSample(p, 2, "indeterminate")],
      ["decision_changed", runSample(p, 2, "outside")],
    ];
  for (const [reason, last] of cases) {
    const result = runs(source, [runSample(p, 0), runSample(p, 1), last]);
    assert.equal(result.frames[2].closed[0].reason, reason);
    assert.equal(result.frames[2].closed[0].run.sample_span_us, "1");
    if (
      [
        "missing_target",
        "unavailable_evidence",
        "indeterminate_evidence",
      ].includes(reason)
    )
      assert.equal(result.frames[2].active.length, 0);
  }
  const body = convexShape(),
    changed = convexShape([...DEFAULT.slice(1), DEFAULT[0]]),
    result = runs(source, [
      runSample(p, 0, "outside", body),
      runSample(p, 1, "outside", body),
      runSample(p, 2, "outside", changed),
    ]);
  assert.equal(result.frames[2].closed[0].reason, "shape_changed");
  assert.equal(result.frames[2].active[0].sample_count, "1");
});

test("every representative run cut resumes in four native and JavaScript directions", (t) => {
  const p = runPosition(),
    source = runSource(p, runOptions),
    kinds = [
      "inside",
      "inside",
      "inside",
      "outside",
      "outside",
      "indeterminate",
      "inside",
      "missing",
      "inside",
      "projection",
      "inside",
      "inside",
    ],
    inputs = kinds.map((kind, i) =>
      runSample(p, 9007199254740993n + BigInt(i), kind),
    ),
    expected = runs(source, inputs);
  let continuations = 0;
  for (let cut = 0; cut <= inputs.length; cut++) {
    const nativeCP = native("--footprint-runs-checkpoint", [
        source,
        ...inputs.slice(0, cut),
      ])[0],
      jsCP = runs(source, inputs.slice(0, cut)).checkpoint;
    assert.deepEqual(nativeCP, jsCP);
    for (const saved of [nativeCP, jsCP]) {
      const resume = { resume: saved };
      const nativeFrames = native("--footprint-runs", [
          resume,
          ...inputs.slice(cut),
        ]),
        nativeFinal = native("--footprint-runs-checkpoint", [
          resume,
          ...inputs.slice(cut),
        ])[0];
      assert.deepEqual(nativeFrames, expected.frames.slice(cut));
      assert.deepEqual(nativeFinal, expected.checkpoint);
      continuations++;
      const js = runs(resume, inputs.slice(cut));
      assert.deepEqual(js.frames, expected.frames.slice(cut));
      assert.deepEqual(js.checkpoint, expected.checkpoint);
      continuations++;
    }
  }
  t.diagnostic(
    JSON.stringify({
      cut_points: inputs.length + 1,
      continuations,
      directions: [
        "native_to_native",
        "native_to_javascript",
        "javascript_to_native",
        "javascript_to_javascript",
      ],
      exact_clock_start: "9007199254740993",
    }),
  );
});

test("warm Brown old motion and run checkpoint resume preserve explicit ground shape runs", () => {
  const records = readFileSync(
    path.join(root, "examples/distorted-camera.ndjson"),
    "utf8",
  )
    .trim()
    .split("\n")
    .map(JSON.parse);
  records[0].diagnostics = true;
  records[0].motion = {
    ...records[0].motion,
    min_observations: 2,
    min_span_us: "0",
    max_position_std_m: 1e5,
    max_velocity_std_mps: 1e5,
  };
  const position = config(
      [
        zone("wide", [
          [-100, -100],
          [100, -100],
          [100, 100],
          [-100, 100],
        ]),
      ],
      records[0].session_id,
    ),
    source = runSource(position, {
      max_gap_us: "500000",
      confirmation_us: "100000",
      min_samples: "2",
    }),
    cut = 3,
    oldCP = native("--checkpoint", records.slice(0, cut + 1))[0],
    prefix = native("--stream", records.slice(0, cut + 1)),
    future = records.slice(cut + 1),
    baseline = native("--stream", [{ resume: oldCP }, ...future]),
    changed = native("--reframe", [
      {
        source: { resume: oldCP },
        transform: { scale_x: 0.5, scale_y: 1.25, offset_x: -40, offset_y: 16 },
      },
      ...future,
    ]),
    altered = native("--stream", changed),
    fixed = (frames) =>
      frames.map((m) =>
        pair(
          m,
          bundle(
            m,
            m.tracks
              .filter((v) => v.segment_id !== null)
              .map((v) => binding(v, convexShape())),
          ),
        ),
      ),
    runCP = runs(source, fixed(prefix)).checkpoint,
    expected = runs({ resume: runCP }, fixed(baseline)),
    actual = runs({ resume: runCP }, fixed(altered));
  assert.ok(expected.frames.some((v) => v.active.length));
  close(actual, expected);
});

test("raw restore and late failure errors expose no partial pure result and support same-time correction", () => {
  const p = runPosition(),
    source = runSource(p, runOptions),
    first = runSample(p, 0),
    prefix = runs(source, [first]),
    good = runs(source, [first, runSample(p, 1), runSample(p, 2)]).checkpoint;
  const mutate = [
    (v) => (v.version = 2),
    (v) => (v.last_timestamp_us = null),
    (v) => (v.states[0].run.sample_count = "0"),
    (v) => (v.states[0].run.sample_span_us = "1"),
    (v) => (v.states[0].run.confirmed = false),
    (v) => (v.states[0].run.decision = "outside"),
    (v) => (v.states[0].last_position_m = [2, 0.5]),
    (v) => (v.states[0].last_position_covariance = [1, 2, 1]),
    (v) => v.states.push(clone(v.states[0])),
    (v) => (v.states[0].run.zone_id = "unknown"),
    (v) => delete v.config.min_samples,
  ];
  for (const change of mutate) {
    const cp = clone(good);
    change(cp);
    failure(invokeRuns({ resume: cp }, ""));
    assert.deepEqual(
      native("--footprint-runs-checkpoint", [{ resume: cp }], 2),
      [],
    );
  }
  const invalid = runSample(p, 1, "inside", diskShape(1e-30));
  failure(invokeRuns(source, ndjson([first, invalid])));
  assert.deepEqual(
    native("--footprint-runs", [source, first, invalid], 2),
    prefix.frames,
  );
  assert.deepEqual(
    native("--footprint-runs-checkpoint", [source, first, invalid], 2),
    [],
  );
  failure(invokeRuns(source, ndjson([first, first])));
  assert.deepEqual(
    runs({ resume: prefix.checkpoint }, [runSample(p, 1)]).frames[0].active[0]
      .sample_count,
    "2",
  );
  const huge = clone(good);
  huge.config = { max_gap_us: "2", confirmation_us: "0", min_samples: "1" };
  huge.last_timestamp_us = "9223372036854775806";
  Object.assign(huge.states[0].run, {
    first_timestamp_us: "0",
    last_timestamp_us: "9223372036854775806",
    sample_span_us: "9223372036854775806",
    sample_count: "9223372036854775807",
    confirmed: true,
  });
  assert.deepEqual(runs({ resume: huge }).checkpoint, huge);
  failure(
    invokeRuns({ resume: huge }, ndjson([runSample(p, 9223372036854775807n)])),
  );
  const fixed = runs({ resume: huge }, [
    runSample(p, 9223372036854775807n, "outside"),
  ]);
  assert.equal(fixed.frames[0].active[0].sample_count, "1");
  assert.equal(fixed.frames[0].closed[0].reason, "decision_changed");
  for (const bad of [
    { ...source, extra: 0 },
    { position: p, options: "{}" },
    runSource(p, { min_samples: 2 }),
    runSource(p, { max_gap_us: "0" }),
  ])
    failure(invokeRuns(bad, ""));
  const raw = clone(runSample(p, 1));
  raw.assignments = raw.assignments.replace(
    '"track_id":1',
    '"track_id":1.0000000000000001',
  );
  failure(invokeRuns(source, ndjson([raw])));
});

test("actual input, output and frame budgets retain empty checkpoints with all old handles occupied", (t) => {
  const Mi = 1048576,
    p = runPosition(),
    source = runSource(p),
    empty = runSample(p, 0, "absent"),
    exact = line(source).padEnd(Mi, " ");
  assert.deepEqual(runs(exact).frames, []);
  failure(invokeRuns(exact + " ", ""));
  assert.equal(runs(source, line(empty).padEnd(Mi, " ")).frames.length, 1);
  failure(invokeRuns(source, line(empty).padEnd(Mi + 1, " ")));
  const frames = Array.from({ length: 5000 }, (_, i) =>
      runSample(p, i, "absent"),
    ),
    complete = runs(source, frames);
  assert.equal(complete.frames.length, 5000);
  assert.equal(complete.checkpoint.last_timestamp_us, "4999");
  assert.match(
    failure(
      invokeRuns(source, ndjson([...frames, runSample(p, 5000, "absent")])),
    ),
    /5000/,
  );
  const exactFrames = Array.from(
    { length: 8 },
    (_, i) => line(runSample(p, i, "absent")).padEnd(Mi - 1, " ") + "\n",
  ).join("");
  assert.equal(runs(source, exactFrames).frames.length, 8);
  failure(invokeRuns(source, exactFrames + " "));
  const request = line({ source: line(source), frames: "" }).padEnd(
    16 * Mi,
    " ",
  );
  assert.deepEqual(unpack(moonground_footprint_runs(request)).frames, []);
  failure(moonground_footprint_runs(request + " "));
  const handles = [];
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(
            line({ session_id: "occupied-runs-" + i, mode: "ground" }),
          ),
        ).handle,
      );
    assert.deepEqual(runs(source, frames), complete);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
  t.diagnostic(
    JSON.stringify({
      successful_empty_frames: 5000,
      complete_return_utf16_units: line(complete).length,
      old_handles_occupied: 64,
      whole_output_includes_checkpoint: true,
    }),
  );
});

test("actual maximum supports retained state and expanded checkpoint size reject at their distinct budgets", (t) => {
  const Mi = 1048576,
    vertices = Array.from({ length: 32 }, (_, i) => [
      10 * Math.cos((2 * Math.PI * i) / 32),
      10 * Math.sin((2 * Math.PI * i) / 32),
    ]),
    shape = vertices.map(([x, y]) => [x * 0.025, y * 0.025]),
    p = config(
      Array.from({ length: 16 }, (_, i) => zone(String(i), vertices)),
      "run-max-work",
      128,
    ),
    source = runSource(p, { min_samples: "1", confirmation_us: "0" }),
    m = frame(
      p,
      0,
      Array.from({ length: 128 }, (_, i) =>
        track(0, [0, 0], [0.01, 0, 0.01], i + 1),
      ),
    ),
    input = pair(
      m,
      bundle(
        m,
        m.tracks.map((v) => binding(v, convexShape(shape))),
      ),
    ),
    actual = native("--footprint-runs", [source, input]);
  assert.equal(actual[0].active.length, 2048);
  assert.equal(
    actual[0].evidence.evidence.reduce((n, v) => n + v.faces.length, 0),
    65536,
  );
  const saved = native("--footprint-runs-checkpoint", [source, input])[0];
  assert.equal(saved.states.length, 2048);
  assert.match(failure(invokeRuns(source, ndjson([input]))), /output.*8388608/);
  // A different legal face configuration permits many small retained states.
  // Long configured IDs enlarge only checkpoint/output, not the input frame.
  const triangles = [
      [0, 0],
      [10, 0],
      [0, 10],
    ],
    large = config(
      Array.from({ length: 16 }, (_, i) =>
        zone(String(i).padEnd(128, "x"), triangles, 0),
      ),
      "run-max-state",
      1365,
    ),
    bigSource = runSource(large, { min_samples: "1", confirmation_us: "0" }),
    measurement = frame(
      large,
      0,
      Array.from({ length: 1365 }, (_, i) =>
        track(0, [1, 1], [0.01, 0, 0.01], i + 1),
      ),
    ),
    wrapped = pair(
      measurement,
      bundle(
        measurement,
        measurement.tracks.map((v) => binding(v, diskShape(0))),
      ),
    );
  assert.ok(
    line(wrapped).length <= Mi,
    "max-state fixture must fit raw frame budget",
  );
  const maximum = native("--footprint-runs", [bigSource, wrapped]);
  assert.equal(maximum[0].active.length, 21840);
  const attempt = spawnSync(binary, ["--footprint-runs-checkpoint"], {
    input: ndjson([bigSource, wrapped]),
    encoding: "utf8",
    maxBuffer: 2 * Mi,
    timeout: 120000,
  });
  assert.equal(attempt.status, 2, attempt.stderr);
  assert.equal(attempt.stdout, "");
  assert.match(attempt.stderr, /checkpoint.*8388608/);
  t.diagnostic(
    JSON.stringify({
      maximum_actual_face_expansions: 65536,
      maximum_raw_support_projections: 2097152,
      max_work_retained_states: 2048,
      max_actual_retained_states: 21840,
      max_state_frame_utf16_units: line(wrapped).length,
      checkpoint_budget_rejected: true,
      equivalent_work_pure_return_utf16_units: line({
        frames: actual,
        checkpoint: saved,
      }).length,
    }),
  );
});
