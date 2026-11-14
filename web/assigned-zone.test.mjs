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
    maxBuffer: 48 * 1024 * 1024,
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

test("mixed same-position footprints match old grouped arithmetic and missing is explicit", () => {
  const source = config(),
    time = "9007199254740993",
    measurement = frame(source, time, [
      track(
        time,
        [0.5, 0.5],
        [0.01, 0, 0.01],
        9,
        "ready",
        "9223372036854775807",
      ),
      track(time, [0.5, 0.5], [0.01, 0, 0.01], 2, "ready", "9007199254740993"),
      track(time, [0.5, 0.5], [0.01, 0, 0.01], 5, "ready", "1"),
    ]),
    document = bundle(measurement, [
      binding(measurement.tracks[1], convexShape()),
      binding(measurement.tracks[0], diskShape(0.125)),
    ]),
    result = evaluate(source, [pair(measurement, document)]).frames[0];
  assert.deepEqual(result, grouped(source, measurement, document));
  assert.deepEqual(
    result.evidence.map((v) => v.track_id),
    [2, 9],
  );
  assert.equal(result.evidence[0].shape_kind, "convex");
  assert.equal(result.evidence[1].shape_kind, "disk");
  assert.equal(result.evidence[0].decision, "indeterminate");
  assert.equal(result.evidence[1].decision, "inside");
  assert.deepEqual(result.unavailable, [
    { track_id: 5, segment_id: "1", reason: "missing_footprint" },
  ]);
  const point = browser(source, [measurement]).frames[0];
  for (const row of result.evidence) {
    const original = point.evidence.find((v) => v.track_id === row.track_id);
    row.faces.forEach((v, i) => {
      assert.equal(v.position_lower_m, original.faces[i].lower_m);
      assert.equal(v.position_upper_m, original.faces[i].upper_m);
    });
  }
  close(
    [result],
    native("--assigned-zone-evidence", [source, pair(measurement, document)]),
  );
  assert.deepEqual(Object.keys(evaluate(source, [])), ["frames"]);
});

test("current exact identity and time join keeps lifecycle priority and legal rejected closed segments", () => {
  const source = config(),
    time = 9007199254740993n,
    statuses = [
      "initializing",
      "uncertain",
      "rejected_innovation",
      "numerical_failure",
      "rejected_projection",
    ],
    measurements = statuses.map((status, i) =>
      frame(source, time + BigInt(i), [
        track(time + BigInt(i), [0.5, 0.5], [0.01, 0, 0.01], i + 1, status),
      ]),
    );
  const complete = assigned(source, measurements).frames;
  assert.deepEqual(
    complete.map((v) => v.unavailable[0].reason),
    statuses,
  );
  assert.equal(complete[4].unavailable[0].segment_id, null);
  const order = [4, 3, 2, 1, 0, 0];
  close(
    assigned(
      source,
      order.map((i) => measurements[i]),
    ).frames,
    order.map((i) => complete[i]),
  );
  const ready = frame(source, 100, [track(100)]),
    old = pair(ready),
    newer = frame(source, 101, [
      track(
        101,
        [0.5, 0.5],
        [0.01, 0, 0.01],
        1,
        "ready",
        "9223372036854775807",
      ),
    ]);
  failure(
    invokeAssigned(
      source,
      ndjson([
        pair(newer, {
          timestamp_us: "101",
          footprints: bundle(ready).footprints,
        }),
      ]),
    ),
  );
  const fresh = assigned(source, [newer]).frames[0];
  assert.equal(fresh.evidence[0].segment_id, "9223372036854775807");
  const wrong = clone(bundle(newer));
  wrong.timestamp_us = "100";
  failure(invokeAssigned(source, ndjson([pair(newer, wrong)])));
  const rejected = frame(
    source,
    200,
    [track(200, [0.5, 0.5], [0.01, 0, 0.01], 1, "rejected_innovation", "1")],
    ["1"],
  );
  assert.equal(
    assigned(source, [rejected]).frames[0].unavailable[0].reason,
    "rejected_innovation",
  );
  for (const status of statuses.slice(0, 4)) {
    const m = frame(source, 300, [
        track(300, [0.5, 0.5], [0.01, 0, 0.01], 1, status),
      ]),
      huge = bundle(m, [binding(m.tracks[0], diskShape(1e308))]);
    assert.equal(
      evaluate(source, [pair(m, huge)]).frames[0].unavailable[0].reason,
      status,
    );
  }
  close(
    evaluate(source, [old]).frames,
    native("--assigned-zone-evidence", [source, old]),
  );
});

test("old measurement checkpoints reissue assignments in four runtime directions", (t) => {
  const { source, frames } = rawFixture(),
    position = config(
      [
        zone("wide", [
          [-100, -100],
          [100, -100],
          [100, 100],
          [-100, 100],
        ]),
      ],
      source.session_id,
    ),
    measured = native("--stream", [source, ...frames]),
    expected = assigned(position, measured).frames;
  assert.deepEqual(
    [
      ...new Set(
        expected.flatMap((frame) =>
          frame.evidence.map((row) => row.shape_kind),
        ),
      ),
    ].sort(),
    ["convex", "disk"],
  );
  let continuations = 0;
  for (let cut = 0; cut <= frames.length; cut++) {
    const nativeCP = native("--checkpoint", [
        source,
        ...frames.slice(0, cut),
      ])[0],
      jsCP = oldReplay(source, frames.slice(0, cut)).checkpoint;
    close(nativeCP, jsCP);
    for (const saved of [nativeCP, jsCP])
      for (const outputs of [
        native("--stream", [{ resume: saved }, ...frames.slice(cut)]),
        oldReplay(source, frames.slice(cut), saved).frames,
      ]) {
        close(assigned(position, outputs).frames, expected.slice(cut));
        close(
          native("--assigned-zone-evidence", [
            position,
            ...outputs.map((v) => pair(v)),
          ]),
          expected.slice(cut),
        );
        continuations++;
      }
  }
  t.diagnostic(
    JSON.stringify({
      cut_points: frames.length + 1,
      continuations,
      directions: [
        "native_to_native",
        "native_to_javascript",
        "javascript_to_native",
        "javascript_to_javascript",
      ],
      assigned_evaluators_per_continuation: 2,
      shape_kinds: ["convex", "disk"],
      assignments_reissued_per_frame: true,
    }),
  );
});

test("Brown checkpoint warm reframe preserves fixed metric target shape assignments", () => {
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
  const cut = 3,
    saved = native("--checkpoint", records.slice(0, cut + 1))[0],
    future = records.slice(cut + 1),
    baseline = native("--stream", [{ resume: saved }, ...future]),
    changed = native("--reframe", [
      {
        source: { resume: saved },
        transform: { scale_x: 0.5, scale_y: 1.25, offset_x: -40, offset_y: 16 },
      },
      ...future,
    ]),
    position = config(
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
    expected = assigned(position, baseline),
    actual = assigned(position, native("--stream", changed));
  assert.ok(actual.frames.some((v) => v.evidence.length));
  assert.deepEqual(
    [
      ...new Set(
        actual.frames.flatMap((frame) =>
          frame.evidence.map((row) => row.shape_kind),
        ),
      ),
    ].sort(),
    ["convex", "disk"],
  );
  close(actual, expected);
});

test("nested raw documents reject stale extra duplicate and malformed shapes with complete CLI prefixes", () => {
  const source = config(),
    measurement = frame(source, 100, [track(100)]),
    document = bundle(measurement),
    first = pair(measurement, document),
    prefix = native("--assigned-zone-evidence", [source, first]);
  const badFrames = [
    { measurement: first.measurement },
    { assignments: first.assignments },
    { ...first, measurement },
    { ...first, assignments: document },
    { ...first, extra: 0 },
    '{"measurement":"duplicate",' + line(first).slice(1),
    ...[
      { footprints: document.footprints },
      { ...document, timestamp_us: 100 },
      { ...document, timestamp_us: "0100" },
      { ...document, timestamp_us: "101" },
      { ...document, extra: 0 },
      {
        ...document,
        footprints: document.footprints.concat(document.footprints),
      },
      { ...document, footprints: [{ ...document.footprints[0], track_id: 9 }] },
      {
        ...document,
        footprints: [{ ...document.footprints[0], segment_id: "2" }],
      },
    ].map((v) => pair(measurement, v)),
  ];
  for (const shape of [
    { kind: "unknown", radius_m: 0.25 },
    diskShape(-1),
    { ...diskShape(), extra: 0 },
    { ...convexShape(), radius_m: 0.25 },
    convexShape([[0, 0]]),
    convexShape([
      [1, 1],
      [2, 1],
      [1, 2],
    ]),
  ])
    badFrames.push(
      pair(
        measurement,
        bundle(measurement, [binding(measurement.tracks[0], shape)]),
      ),
    );
  for (const text of [
    line(document).replace('"track_id":1', '"track_id":1.0000000000000001'),
    line(document).replace('"track_id":1', '"track_id":1,"track_id":1'),
    line(document).replace('"kind":"disk"', '"kind":"disk","kind":"disk"'),
    line(document).replace('"radius_m":0.25', '"radius_m":1e999'),
  ])
    badFrames.push(pair(measurement, text));
  badFrames.push(
    pair(
      measurement,
      '{"timestamp_us":"100","footprints":' +
        "[".repeat(33) +
        "0" +
        "]".repeat(33) +
        "}",
    ),
  );
  const projection = frame(source, 100, [
    track(100, [0, 0], [1, 0, 1], 1, "rejected_projection"),
  ]);
  badFrames.push(
    pair(projection, document),
    pair(frame(source, 100, [], ["1"]), document),
  );
  for (const mutate of [
    (v) => (v.tracks[0].last_accepted_timestamp_us = "99"),
    (v) => (v.tracks[0].position_covariance = [1, 2, 1]),
    (v) => (v.tracks[0].position_m = null),
    (v) => (v.closed_segment_ids = ["1"]),
    (v) => (v.extra = 0),
  ]) {
    const changed = clone(measurement);
    mutate(changed);
    badFrames.push(pair(changed, document));
  }
  const huge = frame(source, 100, [track(100, [1e300, 0.5], [1, 0, 1])]);
  badFrames.push(
    pair(huge, bundle(huge, [])),
    pair(
      measurement,
      bundle(measurement, [binding(measurement.tracks[0], diskShape(1e16))]),
    ),
  );
  for (const bad of badFrames) {
    failure(invokeAssigned(source, ndjson([first, bad])));
    assert.deepEqual(
      native("--assigned-zone-evidence", [source, first, bad], 2),
      prefix,
    );
  }
  const integral = pair(
    measurement,
    line(document).replace('"track_id":1', '"track_id":10e-1'),
  );
  close(evaluate(source, [integral]).frames, prefix);
  close(evaluate(source, [first]).frames, prefix);
  for (const bad of [
    { ...source, extra: 0 },
    line(source).replace('"max_tracks":32', '"max_tracks":32.000000000000001'),
  ]) {
    failure(invokeAssigned(bad, ""));
    assert.deepEqual(native("--assigned-zone-evidence", [bad], 2), []);
  }
});

test("physical variants retain old closed slanted geometry, zero disk and one-sided supports", () => {
  const source = config([
      zone(
        "slanted",
        [
          [0, 0],
          [3, 4],
          [0, 5],
        ],
        0,
      ),
    ]),
    measurement = frame(source, 0, [track(0, [0, 0], [0.01, 0, 0.01], 2)]),
    document = bundle(measurement, [
      binding(
        measurement.tracks[0],
        convexShape([
          [0, 0],
          [3, 4],
          [0, 5],
        ]),
      ),
    ]),
    result = evaluate(source, [pair(measurement, document)]).frames[0];
  assert.equal(result.evidence[0].decision, "inside");
  result.evidence[0].faces.forEach((v) => assert.equal(v.upper_m, 0));
  assert.deepEqual(result, grouped(source, measurement, document));
  const position = config(),
    ready = frame(position, 0, [track(0)]),
    zero = bundle(ready, [binding(ready.tracks[0], diskShape(0))]),
    a = evaluate(position, [pair(ready, zero)]).frames[0].evidence[0],
    b = browser(position, [ready]).frames[0].evidence[0];
  a.faces.forEach((v, i) => {
    assert.equal(v.lower_m, b.faces[i].lower_m);
    assert.equal(v.upper_m, b.faces[i].upper_m);
    assert.equal(v.footprint_lower_m, 0);
    assert.equal(v.footprint_upper_m, 0);
  });
  const vertices = [
      [0, 0],
      [0.25, 0],
      [0, 0.25],
    ],
    one = bundle(ready, [binding(ready.tracks[0], convexShape(vertices))]),
    band = evaluate(position, [pair(ready, one)]).frames[0].evidence[0];
  assert.equal(band.faces[1].footprint_lower_m, 0);
  assert.equal(band.faces[1].lower_m, band.faces[1].position_lower_m);
});

test("actual raw budgets and maximum 2097152 support projections with 65536 expansions", (t) => {
  const Mi = 1048576,
    source = config(),
    empty = frame(source, 0, []),
    first = pair(empty),
    exact = line(source).padEnd(Mi, " ");
  assert.deepEqual(evaluate(exact).frames, []);
  failure(invokeAssigned(exact + " ", ""));
  assert.equal(evaluate(source, line(first).padEnd(Mi, " ")).frames.length, 1);
  failure(invokeAssigned(source, line(first).padEnd(Mi + 1, " ")));
  const frames = Array.from({ length: 5000 }, (_, i) =>
      pair(frame(source, i, [])),
    ),
    complete = evaluate(source, frames);
  assert.equal(complete.frames.length, 5000);
  assert.match(
    failure(invokeAssigned(source, ndjson([...frames, first]))),
    /5000/,
  );
  const exactFrames = Array.from(
    { length: 8 },
    (_, i) => line(pair(frame(source, i, []))).padEnd(Mi - 1, " ") + "\n",
  ).join("");
  assert.equal(exactFrames.length, 8 * Mi);
  assert.equal(evaluate(source, exactFrames).frames.length, 8);
  failure(invokeAssigned(source, exactFrames + " "));
  const request = line({ source: line(source), frames: "" }).padEnd(
    16 * Mi,
    " ",
  );
  assert.deepEqual(
    unpack(moonground_assigned_zone_evidence(request)).frames,
    [],
  );
  failure(moonground_assigned_zone_evidence(request + " "));
  const vertices = Array.from({ length: 32 }, (_, i) => [
      10 * Math.cos((2 * Math.PI * i) / 32),
      10 * Math.sin((2 * Math.PI * i) / 32),
    ]),
    shape = vertices.map(([x, y]) => [x * 0.025, y * 0.025]),
    maximum = config(
      Array.from({ length: 16 }, (_, i) => zone(String(i), vertices)),
      "assigned-maxfaces",
      128,
    ),
    measurement = frame(
      maximum,
      0,
      Array.from({ length: 128 }, (_, i) =>
        track(0, [0, 0], [0.01, 0, 0.01], i + 1),
      ),
    ),
    document = bundle(
      measurement,
      measurement.tracks.map((v) => binding(v, convexShape(shape))),
    ),
    input = pair(measurement, document);
  assert.deepEqual(evaluate(maximum).frames, []);
  failure(invokeAssigned({ ...maximum, max_tracks: 129 }, ""));
  const nativeMaximum = native("--assigned-zone-evidence", [maximum, input]);
  assert.equal(nativeMaximum[0].evidence.length, 2048);
  const actualFaces = nativeMaximum[0].evidence.reduce(
    (n, row) => n + row.faces.length,
    0,
  );
  assert.equal(actualFaces, 65536);
  assert.equal(nativeMaximum[0].evidence[0].vertices_offset_m.length, 32);
  const equivalentPureReturn = line({ frames: nativeMaximum }).length;
  assert.ok(equivalentPureReturn > 8 * Mi);
  assert.match(
    failure(invokeAssigned(maximum, ndjson([input]))),
    /output.*8388608/,
  );
  const outputHead = config(
    Array.from({ length: 16 }, (_, i) => zone(String(i))),
  );
  assert.match(
    failure(
      invokeAssigned(
        outputHead,
        ndjson(
          Array.from({ length: 5000 }, (_, i) =>
            pair(frame(outputHead, i, [track(i)])),
          ),
        ),
      ),
    ),
    /output.*8388608/,
  );
  const handles = [];
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(
            line({ session_id: "occupied-assigned-" + i, mode: "ground" }),
          ),
        ).handle,
      );
    assert.deepEqual(evaluate(source, frames), complete);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
  t.diagnostic(
    JSON.stringify({
      successful_empty_frames: 5000,
      complete_return_utf16_units: line(complete).length,
      actual_shape_vertices: 32,
      actual_native_tracks: 128,
      actual_native_zone_rows: 2048,
      actual_native_face_rows: actualFaces,
      raw_support_projections: actualFaces * 32,
      equivalent_pure_return_utf16_units: equivalentPureReturn,
      output_budget_rejected: true,
      old_handles_occupied: 64,
      nested_frame_budget:
        "raw inner strings and escaping share outer frame 1Mi limit",
    }),
  );
});
