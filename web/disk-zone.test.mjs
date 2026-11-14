import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_zone_evidence,
  moonground_disk_zone_evidence,
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
function preserved(combined, original, radius) {
  assert.deepEqual(combined.unavailable, original.unavailable);
  assert.equal(combined.evidence.length, original.evidence.length);
  combined.evidence.forEach((row, i) => {
    const base = original.evidence[i];
    assert.equal(row.radius_m, radius);
    for (const key of ["track_id", "segment_id", "zone_id", "sigma_multiplier"])
      assert.deepEqual(row[key], base[key]);
    row.faces.forEach((face, j) => {
      const position = base.faces[j];
      for (const key of [
        "edge_index",
        "outward_normal",
        "distance_m",
        "normal_std_m",
      ])
        assert.deepEqual(face[key], position[key]);
      assert.equal(face.position_lower_m, position.lower_m);
      assert.equal(face.position_upper_m, position.upper_m);
      if (radius === 0) {
        assert.equal(face.lower_m, position.lower_m);
        assert.equal(face.upper_m, position.upper_m);
      } else {
        assert.ok(face.lower_m < position.lower_m);
        assert.ok(face.upper_m > position.upper_m);
      }
    });
    if (radius === 0) {
      assert.equal(row.decision, base.decision);
      assert.equal(row.separating_edge_index, base.separating_edge_index);
    }
  });
}

test("closed explicit body tangencies preserve center bands and zero radius exactly", () => {
  const source = config([
    zone("zero", undefined, 0),
    zone("one", undefined, 1),
    zone("two", undefined, 2),
  ]);
  const points = [
      [0.5, 0.5],
      [0.875, 0.5],
      [1.125, 0.5],
      [1.25, 0.5],
      [1.5, 0.5],
      [1.2, 1.2],
      [1, 1],
    ],
    inputs = points.map((p, i) =>
      frame(source, i, [track(i, p, [0.015625, 0, 0.015625])]),
    ),
    original = browser(source, inputs),
    result = disk(source, inputs);
  for (let i = 0; i < inputs.length; i++)
    preserved(result.frames[i], original.frames[i], 0.125);
  assert.equal(result.frames[1].evidence[0].decision, "inside");
  assert.equal(result.frames[1].evidence[0].faces[1].upper_m, 0);
  assert.equal(result.frames[2].evidence[0].faces[1].lower_m, 0);
  assert.equal(result.frames[2].evidence[0].decision, "indeterminate");
  assert.equal(result.frames[4].evidence[0].decision, "outside");
  assert.equal(result.frames[4].evidence[0].separating_edge_index, 1);
  const zero = disk(source, inputs, 0);
  zero.frames.forEach((v, i) => preserved(v, original.frames[i], 0));
  const centerSource = config([zone("center", undefined, 0)]),
    center = frame(centerSource, 0, [track(0, [0.9, 0.5])]);
  assert.equal(
    browser(centerSource, [center]).frames[0].evidence[0].decision,
    "inside",
  );
  assert.equal(
    disk(centerSource, [center], 0.2).frames[0].evidence[0].decision,
    "indeterminate",
  );
  assert.equal(
    result.frames[0].evidence_scope,
    "model_position_halfplane_bands_plus_explicit_disk",
  );
  assert.equal(result.frames[0].kind, "disk_zone_evidence_frame");
  assert.deepEqual(Object.keys(result), ["frames"]);
  close(
    result.frames,
    native("--disk-zone-evidence", [diskSource(source), ...inputs]),
  );
});

test("slanted boundaries, winding, scales and independent physical and covariance inputs", () => {
  const triangle = [
      [0, 0],
      [3, 4],
      [0, 5],
    ],
    variants = [
      triangle,
      [...triangle].reverse(),
      [triangle[1], triangle[2], triangle[0]],
    ];
  for (const vertices of variants) {
    const source = config([zone("slanted", vertices, 0)]),
      points = [
        ...vertices,
        ...vertices.map((p, i) =>
          p.map((v, j) => (v + vertices[(i + 1) % 3][j]) / 2),
        ),
      ],
      inputs = points.map((p, i) =>
        frame(source, i, [track(i, p, [1, 0.4, 2])]),
      ),
      original = browser(source, inputs);
    assert.ok(
      original.frames.every((v) => v.evidence[0].decision === "inside"),
    );
    disk(source, inputs, 0).frames.forEach((v, i) =>
      preserved(v, original.frames[i], 0),
    );
    disk(source, inputs, 0.125).frames.forEach((v, i) =>
      preserved(v, original.frames[i], 0.125),
    );
  }
  for (const scale of [1e-100, 1, 1e100]) {
    const source = config([
        zone(
          "scale",
          [
            [0, 0],
            [scale, 0],
            [scale, scale],
            [0, scale],
          ],
          1,
        ),
      ]),
      input = frame(source, 0, [
        track(
          0,
          [0.5 * scale, 0.5 * scale],
          [0.01 * scale * scale, 0.003 * scale * scale, 0.02 * scale * scale],
        ),
      ]),
      original = browser(source, [input]).frames[0],
      actual = disk(source, [input], 0.125 * scale).frames[0];
    preserved(actual, original, 0.125 * scale);
    close(
      [actual],
      native("--disk-zone-evidence", [
        diskSource(source, 0.125 * scale),
        input,
      ]),
    );
  }
  const source = config(),
    input = frame(source, 0, [track(0)]),
    a = disk(source, [input], 0.125).frames[0],
    b = disk(source, [input], 0.25).frames[0];
  a.evidence[0].faces.forEach((v, i) => {
    assert.equal(v.position_lower_m, b.evidence[0].faces[i].position_lower_m);
    assert.equal(v.position_upper_m, b.evidence[0].faces[i].position_upper_m);
  });
  const differentP = clone(input);
  differentP.tracks[0] = track(0, [0.5, 0.5], [0.04, 0.01, 0.09]);
  const c = disk(source, [differentP], 0.125).frames[0];
  assert.equal(c.evidence[0].radius_m, a.evidence[0].radius_m);
  assert.notEqual(
    c.evidence[0].faces[0].position_lower_m,
    a.evidence[0].faces[0].position_lower_m,
  );
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
  const expected = disk(source, inputs).frames;
  assert.deepEqual(
    expected.slice(0, 5).map((v) => v.unavailable[0].reason),
    statuses,
  );
  assert.equal(expected[4].unavailable[0].segment_id, null);
  const order = [6, 5, 4, 3, 2, 1, 0, 0, 5];
  close(
    disk(
      source,
      order.map((i) => inputs[i]),
    ).frames,
    order.map((i) => expected[i]),
  );
  close(
    native("--disk-zone-evidence", [
      diskSource(source),
      ...order.map((i) => inputs[i]),
    ]),
    order.map((i) => expected[i]),
  );
  const mixed = frame(source, 9, [
      track(9, [0.5, 0.5], [0.01, 0, 0.01], 9),
      track(9, [0, 0], [1, 0, 1], 2, "rejected_projection"),
      track(9, [0, 0], [1, 0, 1], 5, "uncertain"),
    ]),
    output = disk(source, [mixed]).frames[0];
  assert.deepEqual(
    output.evidence.map((v) => v.track_id),
    [9],
  );
  assert.deepEqual(
    output.unavailable.map((v) => v.track_id),
    [2, 5],
  );
});

test("old motion checkpoint continuations recompute disk bands in all four runtime directions", (t) => {
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
    expected = disk(position, measured, 0.25).frames;
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
        close(disk(position, outputs, 0.25).frames, expected.slice(cut));
        close(
          native("--disk-zone-evidence", [
            diskSource(position, 0.25),
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
      disk_evaluators_per_continuation: 2,
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
    expected = disk(position, baseline, 0.25),
    actual = disk(position, native("--stream", changed), 0.25);
  assert.ok(actual.frames.some((v) => v.evidence.length));
  close(actual, expected);
  actual.frames.forEach((v) =>
    v.evidence.forEach((row) => assert.equal(row.radius_m, 0.25)),
  );
});

test("raw nested source, covariance and contribution errors retain only complete native prefixes", () => {
  const position = config(),
    source = diskSource(position),
    first = frame(position, 100, [track(100)]),
    prefix = native("--disk-zone-evidence", [source, first]);
  for (const bad of [
    { disk: source.disk },
    { position: source.position },
    { ...source, position },
    { ...source, disk: { radius_m: 0.125 } },
    { ...source, extra: 0 },
    '{"position":"duplicate",' + line(source).slice(1),
    ...[
      "{}",
      '{"radius_m":-1}',
      '{"radius_m":1e999}',
      '{"radius_m":.125}',
      '{"radius_m":0.125,"radius_m":0}',
      '{"radius_m":0,"extra":1}',
    ].map((disk) => ({ ...source, disk })),
    diskSource({ ...position, radius_m: 0.25 }),
    diskSource(
      line(position).replace(
        '"max_tracks":32',
        '"max_tracks":32.000000000000001',
      ),
    ),
    diskSource('{"session_id":"duplicate",' + line(position).slice(1)),
  ]) {
    failure(invokeDisk(bad, ""));
    assert.deepEqual(native("--disk-zone-evidence", [bad], 2), []);
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
    failure(invokeDisk(source, ndjson([first, invalid])));
    assert.deepEqual(
      native("--disk-zone-evidence", [source, first, invalid], 2),
      prefix,
    );
  }
  for (const [k, r, cov, point] of [
    [2, 0.125, [1e32, 0, 1e32], [0.5, 0.5]],
    [2, 1e16, [0.01, 0, 0.01], [0.5, 0.5]],
    [1e154, 1e308, [1e308, 0, 1e308], [0.5, 0.5]],
    [2, 0.25, [1, 0, 1], [1e16, 0.5]],
    [0, Number.MIN_VALUE, [0.01, 0, 0.01], [0.5, 0.5]],
    [2, 1e300, [1, 0, 1], [1e300, 0.5]],
  ]) {
    const p = config([zone("failure", undefined, k)]),
      head = diskSource(p, r),
      value = frame(p, 0, [track(0, point, cov)]);
    failure(invokeDisk(head, ndjson([value])));
    assert.deepEqual(native("--disk-zone-evidence", [head, value], 2), []);
  }
  const capacity = config([zone()], position.session_id, 1);
  failure(
    invokeDisk(
      diskSource(capacity),
      ndjson([
        frame(capacity, 0, [
          track(0),
          track(0, [0, 0], [1, 0, 1], 2, "rejected_projection"),
        ]),
      ]),
    ),
  );
  close(
    disk(position, [line(first).replace('"track_id":1', '"track_id":10e-1')])
      .frames,
    prefix,
  );
  failure(
    invokeDisk(
      source,
      ndjson([
        line(first).replace('"track_id":1', '"track_id":1.0000000000000001'),
      ]),
    ),
  );
  close(disk(position, [first]).frames, prefix);
});

test("actual source and batch budgets, 65536 native disk faces and occupied legacy handles", (t) => {
  const Mi = 1048576,
    position = config(),
    source = diskSource(position),
    empty = frame(position, 0, []),
    exact = line(source).padEnd(Mi, " ");
  assert.deepEqual(unpack(invokeDisk(exact, "")).frames, []);
  failure(invokeDisk(exact + " ", ""));
  assert.equal(disk(position, line(empty).padEnd(Mi, " ")).frames.length, 1);
  failure(invokeDisk(source, line(empty).padEnd(Mi + 1, " ")));
  const frames = Array.from({ length: 5000 }, (_, i) => frame(position, i, [])),
    complete = disk(position, frames);
  assert.equal(complete.frames.length, 5000);
  assert.match(failure(invokeDisk(source, ndjson([...frames, empty]))), /5000/);
  const exactMeasurements = Array.from(
    { length: 8 },
    (_, i) => line(frame(position, i, [])).padEnd(Mi - 1, " ") + "\n",
  ).join("");
  assert.equal(exactMeasurements.length, 8 * Mi);
  assert.equal(disk(position, exactMeasurements).frames.length, 8);
  failure(invokeDisk(source, exactMeasurements + " "));
  const request = line({ source: line(source), measurements: "" }).padEnd(
    16 * Mi,
    " ",
  );
  assert.deepEqual(unpack(moonground_disk_zone_evidence(request)).frames, []);
  failure(moonground_disk_zone_evidence(request + " "));
  const vertices = Array.from({ length: 32 }, (_, i) => [
      10 * Math.cos((2 * Math.PI * i) / 32),
      10 * Math.sin((2 * Math.PI * i) / 32),
    ]),
    maximum = config(
      Array.from({ length: 16 }, (_, i) => zone(String(i), vertices)),
      "disk-zone-maxfaces",
      128,
    ),
    maxSource = diskSource(maximum),
    input = frame(
      maximum,
      0,
      Array.from({ length: 128 }, (_, i) =>
        track(0, [0, 0], [0.01, 0, 0.01], i + 1),
      ),
    );
  assert.deepEqual(disk(maximum).frames, []);
  failure(invokeDisk(diskSource({ ...maximum, max_tracks: 129 }), ""));
  const nativeMaximum = native("--disk-zone-evidence", [maxSource, input]);
  assert.equal(nativeMaximum[0].evidence.length, 2048);
  const actualFaces = nativeMaximum[0].evidence.reduce(
    (n, row) => n + row.faces.length,
    0,
  );
  assert.equal(actualFaces, 65536);
  const equivalentPureReturn = line({ frames: nativeMaximum }).length;
  assert.ok(equivalentPureReturn > 8 * Mi);
  assert.match(
    failure(invokeDisk(maxSource, ndjson([input]))),
    /output.*8388608/,
  );
  const outputHead = config(
    Array.from({ length: 16 }, (_, i) => zone(String(i))),
  );
  assert.match(
    failure(
      invokeDisk(
        diskSource(outputHead),
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
            line({ session_id: "occupied-disk-" + i, mode: "ground" }),
          ),
        ).handle,
      );
    assert.deepEqual(disk(position, frames), complete);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
  t.diagnostic(
    JSON.stringify({
      successful_empty_frames: 5000,
      complete_return_utf16_units: line(complete).length,
      max_configured_zones: 16,
      max_faces_per_zone: 32,
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
