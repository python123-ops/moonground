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
function preserved(combined, original, vertices = DEFAULT) {
  assert.deepEqual(combined.unavailable, original.unavailable);
  assert.equal(combined.evidence.length, original.evidence.length);
  combined.evidence.forEach((row, i) => {
    const base = original.evidence[i];
    assert.deepEqual(row.vertices_offset_m, vertices);
    for (const key of ["track_id", "segment_id", "zone_id", "sigma_multiplier"])
      assert.deepEqual(row[key], base[key]);
    row.faces.forEach((face, j) => {
      const point = base.faces[j];
      for (const key of [
        "edge_index",
        "outward_normal",
        "distance_m",
        "normal_std_m",
      ])
        assert.deepEqual(face[key], point[key]);
      assert.equal(face.position_lower_m, point.lower_m);
      assert.equal(face.position_upper_m, point.upper_m);
      assert.ok(face.footprint_lower_m <= 0 && face.footprint_upper_m >= 0);
      if (face.footprint_lower_m === 0)
        assert.equal(face.lower_m, point.lower_m);
      else assert.ok(face.lower_m < point.lower_m);
      if (face.footprint_upper_m === 0)
        assert.equal(face.upper_m, point.upper_m);
      else assert.ok(face.upper_m > point.upper_m);
    });
  });
}

test("explicit asymmetric support keeps anchor semantics, single zero sides and closed contacts", () => {
  const source = config([zone("zero", undefined, 0)]),
    vertices = [
      [-0.125, 0],
      [0.25, 0],
      [0.25, 0.125],
      [-0.125, 0.125],
    ],
    inputs = [
      [0.75, 0.5],
      [1.125, 0.5],
      [1.25, 0.5],
      [0.5, 0.875],
      [0.5, 1],
    ].map((p, i) => frame(source, i, [track(i, p)])),
    original = browser(source, inputs),
    actual = footprint(source, inputs, vertices);
  actual.frames.forEach((v, i) => preserved(v, original.frames[i], vertices));
  const right = actual.frames[0].evidence[0].faces[1];
  assert.equal(right.footprint_lower_m, -0.125);
  assert.equal(right.footprint_upper_m, 0.25);
  assert.equal(right.upper_m, 0);
  assert.equal(actual.frames[0].evidence[0].decision, "inside");
  assert.equal(actual.frames[1].evidence[0].faces[1].lower_m, 0);
  assert.equal(actual.frames[1].evidence[0].decision, "indeterminate");
  assert.equal(actual.frames[2].evidence[0].decision, "outside");
  assert.equal(actual.frames[3].evidence[0].faces[2].upper_m, 0);
  assert.equal(actual.frames[3].evidence[0].decision, "inside");
  assert.equal(actual.frames[4].evidence[0].faces[2].footprint_lower_m, 0);
  assert.equal(
    actual.frames[4].evidence[0].faces[2].lower_m,
    original.frames[4].evidence[0].faces[2].lower_m,
  );
  assert.equal(actual.frames[0].kind, "footprint_zone_evidence_frame");
  assert.equal(
    actual.frames[0].evidence_scope,
    "model_position_halfplane_bands_plus_explicit_convex_footprint",
  );
  assert.deepEqual(Object.keys(actual), ["frames"]);
  close(
    actual.frames,
    native("--footprint-zone-evidence", [
      footprintSource(source, vertices),
      ...inputs,
    ]),
  );
  const point = frame(source, 0, [track(0, [0.9, 0.5])]);
  assert.equal(
    browser(source, [point]).frames[0].evidence[0].decision,
    "inside",
  );
  assert.equal(
    footprint(source, [point]).frames[0].evidence[0].decision,
    "indeterminate",
  );
});

test("raw slanted contact, anchor edge or vertex, winding, metric scale and disk compatibility", () => {
  const shape = [
      [0, 0],
      [3, 4],
      [0, 5],
    ],
    source = config([zone("slanted", shape, 0)]),
    value = frame(source, 0, [track(0, [0, 0])]);
  const band = footprint(source, [value], shape).frames[0].evidence[0];
  assert.equal(band.decision, "inside");
  band.faces.forEach((v) => assert.equal(v.upper_m, 0));
  const big = config([
      zone(
        "large",
        [
          [0, 0],
          [6, 8],
          [0, 10],
        ],
        0,
      ),
    ]),
    points = [
      [1.5, 2],
      [1.5, 2 - Number.EPSILON],
      [1.5, 2 + 2 * Number.EPSILON],
    ],
    result = footprint(
      big,
      points.map((p, i) => frame(big, i, [track(i, p)])),
      shape,
    );
  assert.deepEqual(
    result.frames.map((v) => v.evidence[0].decision),
    ["inside", "indeterminate", "inside"],
  );
  for (const vertices of [
    DEFAULT,
    [...DEFAULT].reverse(),
    [...DEFAULT.slice(2), ...DEFAULT.slice(0, 2)],
    [
      [-0.25, 0],
      [0.5, 0],
      [0.5, 0.25],
      [-0.25, 0.25],
    ],
    [
      [0, 0],
      [0.5, 0],
      [0, 0.25],
    ],
  ]) {
    const p = config(),
      input = frame(p, 0, [track(0)]),
      original = browser(p, [input]).frames[0];
    preserved(footprint(p, [input], vertices).frames[0], original, vertices);
  }
  for (const scale of [1e-100, 1, 1e100]) {
    const p = config([
        zone(
          "scaled",
          [
            [0, 0],
            [4 * scale, 0],
            [4 * scale, 4 * scale],
            [0, 4 * scale],
          ],
          1,
        ),
      ]),
      vertices = DEFAULT.map(([x, y]) => [x * scale, y * scale]),
      input = frame(p, 0, [
        track(
          0,
          [scale, scale],
          [0.01 * scale * scale, 0.003 * scale * scale, 0.02 * scale * scale],
        ),
      ]);
    preserved(
      footprint(p, [input], vertices).frames[0],
      browser(p, [input]).frames[0],
      vertices,
    );
    close(
      footprint(p, [input], vertices).frames,
      native("--footprint-zone-evidence", [
        footprintSource(p, vertices),
        input,
      ]),
    );
  }
  const p = config(),
    input = frame(p, 0, [track(0)]),
    a = footprint(p, [input], square(0.125)).frames[0].evidence[0],
    b = disk(p, [input], 0.125).frames[0].evidence[0];
  assert.equal(a.decision, b.decision);
  a.faces.forEach((v, i) => {
    assert.equal(v.lower_m, b.faces[i].lower_m);
    assert.equal(v.upper_m, b.faces[i].upper_m);
  });
  const other = footprint(p, [input], square(0.25)).frames[0].evidence[0];
  a.faces.forEach((v, i) => {
    assert.equal(v.position_lower_m, other.faces[i].position_lower_m);
    assert.equal(v.position_upper_m, other.faces[i].position_upper_m);
  });
});
test("all lifecycle statuses and exact Int64 clocks remain stateless with sorted unavailability", () => {
  const source = config(),
    statuses = [
      "initializing",
      "uncertain",
      "rejected_innovation",
      "numerical_failure",
      "rejected_projection",
    ];
  const inputs = statuses.map((status, i) =>
    frame(source, 9007199254740993n + BigInt(i), [
      track(
        9007199254740993n + BigInt(i),
        [0.5, 0.5],
        [0.01, 0, 0.01],
        i + 1,
        status,
      ),
    ]),
  );
  inputs.push(
    frame(source, 9223372036854775807n, [track(9223372036854775807n)]),
    frame(source, 0, []),
  );
  const expected = footprint(source, inputs).frames;
  assert.deepEqual(
    expected.slice(0, 5).map((v) => v.unavailable[0].reason),
    statuses,
  );
  assert.equal(expected[4].unavailable[0].segment_id, null);
  const order = [6, 5, 4, 3, 2, 1, 0, 0, 5];
  close(
    footprint(
      source,
      order.map((i) => inputs[i]),
    ).frames,
    order.map((i) => expected[i]),
  );
  close(
    native("--footprint-zone-evidence", [
      footprintSource(source),
      ...order.map((i) => inputs[i]),
    ]),
    order.map((i) => expected[i]),
  );
  const mixed = frame(source, 9, [
      track(9, [0.5, 0.5], [0.01, 0, 0.01], 9),
      track(9, [0, 0], [1, 0, 1], 2, "rejected_projection"),
      track(9, [0, 0], [1, 0, 1], 5, "uncertain"),
    ]),
    output = footprint(source, [mixed]).frames[0];
  assert.deepEqual(
    output.evidence.map((v) => v.track_id),
    [9],
  );
  assert.deepEqual(
    output.unavailable.map((v) => v.track_id),
    [2, 5],
  );
});

test("old motion checkpoint continuations recompute footprint bands in all four runtime directions", (t) => {
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
    expected = footprint(position, measured, DEFAULT).frames;
  let continuations = 0;
  for (let cut = 0; cut <= frames.length; cut++) {
    const savedNative = native("--checkpoint", [
        source,
        ...frames.slice(0, cut),
      ])[0],
      savedJS = oldReplay(source, frames.slice(0, cut)).checkpoint;
    close(savedJS, savedNative);
    for (const saved of [savedNative, savedJS])
      for (const outputs of [
        native("--stream", [{ resume: saved }, ...frames.slice(cut)]),
        oldReplay(source, frames.slice(cut), saved).frames,
      ]) {
        close(
          footprint(position, outputs, DEFAULT).frames,
          expected.slice(cut),
        );
        close(
          native("--footprint-zone-evidence", [
            footprintSource(position, DEFAULT),
            ...outputs,
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
      footprint_evaluators_per_continuation: 2,
    }),
  );
});

test("warm Brown checkpoint reframe keeps explicit metres and statistical position bands", () => {
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
    expected = footprint(position, baseline, DEFAULT),
    actual = footprint(position, native("--stream", changed), DEFAULT);
  assert.ok(actual.frames.some((v) => v.evidence.length));
  close(actual, expected);
  actual.frames.forEach((v) =>
    v.evidence.forEach((row) =>
      assert.deepEqual(row.vertices_offset_m, DEFAULT),
    ),
  );
});

test("strict raw footprint geometry and arithmetic failures never expose a failed pure prefix", () => {
  const position = config(),
    source = footprintSource(position),
    first = frame(position, 100, [track(100)]),
    prefix = native("--footprint-zone-evidence", [source, first]);
  const invalidShapes = [
    [],
    [[0, 0]],
    [
      [0, 0],
      [1, 0],
    ],
    [
      [0, 0],
      [0, 0],
      [0, 0],
    ],
    [
      [1, 1],
      [2, 1],
      [1, 2],
    ],
    [
      [0, 0],
      [1, 0],
      [1, 0],
      [0, 1],
    ],
    [
      [0, 0],
      [1, 0],
      [2, 0],
    ],
    [
      [0, 0],
      [1, 0],
      [0.25, 0.25],
      [0, 1],
    ],
    [
      [0, 0],
      [1, 1],
      [0, 1],
      [1, 0],
    ],
    Array.from({ length: 33 }, (_, i) => [
      Math.cos((2 * Math.PI * i) / 33),
      Math.sin((2 * Math.PI * i) / 33),
    ]),
  ];
  const invalidSources = [
    { footprint: source.footprint },
    { position: source.position },
    { ...source, position },
    { ...source, footprint: { vertices_offset_m: DEFAULT } },
    { ...source, extra: 0 },
    '{"position":"duplicate",' + line(source).slice(1),
    ...[
      "{}",
      '{"vertices_offset_m":[]}',
      '{"vertices_offset_m":' + line(DEFAULT) + ',"vertices_offset_m":[]}',
      '{"vertices_offset_m":' + line(DEFAULT) + ',"extra":1}',
      '{"vertices_offset_m":[[0,0],[1e999,0],[0,1]]}',
    ].map((footprint) => ({ ...source, footprint })),
    footprintSource({ ...position, vertices_offset_m: DEFAULT }),
    footprintSource(
      line(position).replace(
        '"max_tracks":32',
        '"max_tracks":32.000000000000001',
      ),
    ),
    ...invalidShapes.map((v) => footprintSource(position, v)),
  ];
  for (const bad of invalidSources) {
    failure(invokeFootprint(bad, ""));
    assert.deepEqual(native("--footprint-zone-evidence", [bad], 2), []);
  }
  for (const mutate of [
    (v) => v.tracks.push(clone(v.tracks[0])),
    (v) => v.tracks.push({ ...clone(v.tracks[0]), track_id: 2 }),
    (v) => (v.tracks[0].last_accepted_timestamp_us = "99"),
    (v) => (v.tracks[0].position_m = null),
    (v) => (v.tracks[0].position_covariance = [1, 2, 1]),
    (v) => (v.closed_segment_ids = ["1"]),
    (v) => (v.extra = 1),
  ]) {
    const invalid = clone(first);
    mutate(invalid);
    failure(invokeFootprint(source, ndjson([first, invalid])));
    assert.deepEqual(
      native("--footprint-zone-evidence", [source, first, invalid], 2),
      prefix,
    );
  }
  for (const [k, vertices, cov, point] of [
    [2, square(0.125), [1e32, 0, 1e32], [0.5, 0.5]],
    [2, square(1e16), [0.01, 0, 0.01], [0.5, 0.5]],
    [1.5e154, square(5e307), [1e308, 0, 1e308], [0.5, 0.5]],
    [2, square(0.25), [1, 0, 1], [1e16, 0.5]],
    [2, square(1e100), [1, 0, 1], [1e300, 0.5]],
  ]) {
    const p = config([zone("numeric", undefined, k)]),
      head = footprintSource(p, vertices),
      value = frame(p, 0, [track(0, point, cov)]);
    failure(invokeFootprint(head, ndjson([value])));
    assert.deepEqual(native("--footprint-zone-evidence", [head, value], 2), []);
  }
  const capacity = config([zone()], position.session_id, 1);
  failure(
    invokeFootprint(
      footprintSource(capacity),
      ndjson([
        frame(capacity, 0, [
          track(0),
          track(0, [0, 0], [1, 0, 1], 2, "rejected_projection"),
        ]),
      ]),
    ),
  );
  close(
    footprint(position, [
      line(first).replace('"track_id":1', '"track_id":10e-1'),
    ]).frames,
    prefix,
  );
  failure(
    invokeFootprint(
      source,
      ndjson([
        line(first).replace('"track_id":1', '"track_id":1.0000000000000001'),
      ]),
    ),
  );
  close(footprint(position, [first]).frames, prefix);
});

test("actual budgets, 65536 face expansions with 32 shape vertices and independent pure handles", (t) => {
  const Mi = 1048576,
    position = config(),
    source = footprintSource(position),
    empty = frame(position, 0, []),
    exact = line(source).padEnd(Mi, " ");
  assert.deepEqual(unpack(invokeFootprint(exact, "")).frames, []);
  failure(invokeFootprint(exact + " ", ""));
  assert.equal(
    footprint(position, line(empty).padEnd(Mi, " ")).frames.length,
    1,
  );
  failure(invokeFootprint(source, line(empty).padEnd(Mi + 1, " ")));
  const frames = Array.from({ length: 5000 }, (_, i) => frame(position, i, [])),
    complete = footprint(position, frames);
  assert.equal(complete.frames.length, 5000);
  assert.match(
    failure(invokeFootprint(source, ndjson([...frames, empty]))),
    /5000/,
  );
  const exactMeasurements = Array.from(
    { length: 8 },
    (_, i) => line(frame(position, i, [])).padEnd(Mi - 1, " ") + "\n",
  ).join("");
  assert.equal(exactMeasurements.length, 8 * Mi);
  assert.equal(footprint(position, exactMeasurements).frames.length, 8);
  failure(invokeFootprint(source, exactMeasurements + " "));
  const request = line({ source: line(source), measurements: "" }).padEnd(
    16 * Mi,
    " ",
  );
  assert.deepEqual(
    unpack(moonground_footprint_zone_evidence(request)).frames,
    [],
  );
  failure(moonground_footprint_zone_evidence(request + " "));
  const vertices = Array.from({ length: 32 }, (_, i) => [
      10 * Math.cos((2 * Math.PI * i) / 32),
      10 * Math.sin((2 * Math.PI * i) / 32),
    ]),
    shape = vertices.map(([x, y]) => [x * 0.025, y * 0.025]),
    maximum = config(
      Array.from({ length: 16 }, (_, i) => zone(String(i), vertices)),
      "footprint-zone-maxfaces",
      128,
    ),
    maxSource = footprintSource(maximum, shape),
    input = frame(
      maximum,
      0,
      Array.from({ length: 128 }, (_, i) =>
        track(0, [0, 0], [0.01, 0, 0.01], i + 1),
      ),
    );
  assert.deepEqual(footprint(maximum, [], shape).frames, []);
  failure(
    invokeFootprint(
      footprintSource({ ...maximum, max_tracks: 129 }, shape),
      "",
    ),
  );
  const nativeMaximum = native("--footprint-zone-evidence", [maxSource, input]);
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
    failure(invokeFootprint(maxSource, ndjson([input]))),
    /output.*8388608/,
  );
  const outputHead = config(
    Array.from({ length: 16 }, (_, i) => zone(String(i))),
  );
  assert.match(
    failure(
      invokeFootprint(
        footprintSource(outputHead),
        ndjson(
          Array.from({ length: 5000 }, (_, i) =>
            frame(outputHead, i, [track(i)]),
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
            line({ session_id: "occupied-footprint-" + i, mode: "ground" }),
          ),
        ).handle,
      );
    assert.deepEqual(footprint(position, frames), complete);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
  t.diagnostic(
    JSON.stringify({
      successful_empty_frames: 5000,
      complete_return_utf16_units: line(complete).length,
      max_configured_zones: 16,
      max_faces_per_zone: 32,
      actual_shape_vertices: 32,
      actual_native_tracks: 128,
      actual_native_zone_rows: 2048,
      actual_native_face_rows: actualFaces,
      equivalent_pure_return_utf16_units: equivalentPureReturn,
      output_budget_rejected: true,
      old_handles_occupied: 64,
      nested_source_budget:
        "outer source includes raw inner strings and wrapper overhead",
    }),
  );
});
