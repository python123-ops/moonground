import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_zone_evidence,
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

test("closed support bands distinguish inside, face separation, tangent and conservative disjoint corners", () => {
  const source = config([
    zone("one", undefined, 1),
    zone("two", undefined, 2),
    zone("zero", undefined, 0),
  ]);
  const result = browser(
    source,
    [
      [0.5, 0.5],
      [1.2, 1.2],
      [1.25, 0.5],
      [2, 0.5],
      [1, 1],
    ].map((point, i) =>
      frame(source, i, [track(i, point, [0.0625, 0, 0.0625])]),
    ),
  );
  const row = (i, z) => result.frames[i].evidence[z];
  assert.equal(row(0, 1).decision, "inside");
  row(0, 1).faces.forEach((face) => assert.equal(face.upper_m, 0));
  assert.ok(Math.hypot(0.2, 0.2) > 0.25);
  assert.equal(row(1, 0).decision, "indeterminate");
  assert.equal(row(1, 0).separating_edge_index, null);
  assert.equal(row(2, 0).faces[1].lower_m, 0);
  assert.equal(row(2, 0).decision, "indeterminate");
  assert.equal(row(3, 0).decision, "outside");
  assert.equal(row(3, 0).separating_edge_index, 1);
  assert.deepEqual(row(3, 0).faces[1].outward_normal, [1, 0]);
  assert.equal(row(4, 2).decision, "inside");
  assert.ok(row(4, 2).faces.every((face) => face.normal_std_m > 0));
  assert.equal(
    result.frames[0].evidence_scope,
    "model_position_halfplane_bands",
  );
  assert.deepEqual(Object.keys(result), ["frames"]);
  close(
    result.frames,
    native("--zone-evidence", [
      source,
      ...[
        [0.5, 0.5],
        [1.2, 1.2],
        [1.25, 0.5],
        [2, 0.5],
        [1, 1],
      ].map((point, i) =>
        frame(source, i, [track(i, point, [0.0625, 0, 0.0625])]),
      ),
    ]),
  );
});

test("winding, vertex origin, anisotropy, exact slanted boundary and metric scale preserve zone meaning", () => {
  const vertices = [
    [-2, -1],
    [2, -1],
    [3, 2],
    [-1, 3],
  ];
  const source = config([
    zone("ccw", vertices),
    zone("cw", vertices.toReversed()),
    zone("cyclic", [...vertices.slice(2), ...vertices.slice(0, 2)]),
  ]);
  const inputs = [
    [0, 0],
    [4, 0],
    [-2, 3],
  ].map((point, i) => frame(source, i, [track(i, point, [0.01, 0.002, 0.02])]));
  const result = browser(source, inputs);
  for (const output of result.frames)
    assert.equal(new Set(output.evidence.map((row) => row.decision)).size, 1);
  close(result.frames, native("--zone-evidence", [source, ...inputs]));
  const triangle = config([
    zone(
      "triangle",
      [
        [0, 0],
        [3, 4],
        [0, 5],
      ],
      0,
    ),
  ]);
  const boundaries = [
    [0, 0],
    [3, 4],
    [0, 5],
    [1.5, 2],
    [1.5, 4.5],
    [0, 2.5],
  ];
  for (const point of boundaries) {
    const input = frame(triangle, 0, [track(0, point)]),
      output = browser(triangle, [input]).frames[0].evidence[0];
    assert.equal(
      output.decision,
      "inside",
      `own original polygon boundary excluded: ${point}`,
    );
    assert.equal(output.separating_edge_index, null);
    close(
      [browser(triangle, [input]).frames[0]],
      native("--zone-evidence", [triangle, input]),
    );
  }
  const anisotropic = config([
    zone("wide", [
      [-100, -1],
      [100, -1],
      [100, 1],
      [-100, 1],
    ]),
  ]);
  const band = browser(anisotropic, [
    frame(anisotropic, 0, [track(0, [0, 0], [100, 0, 0.0001])]),
  ]).frames[0].evidence[0];
  close(band.faces[0].normal_std_m, 0.01);
  close(band.faces[1].normal_std_m, 10);
  assert.equal(band.decision, "inside");
  for (const scale of [1e-150, 1, 1e150]) {
    const selected = config([
        zone("scaled", [
          [-scale, -scale],
          [scale, -scale],
          [scale, scale],
          [-scale, scale],
        ]),
      ]),
      input = frame(selected, 0, [
        track(
          0,
          [0, 0],
          [0.01 * scale * scale, 0.009 * scale * scale, 0.01 * scale * scale],
        ),
      ]);
    assert.equal(
      browser(selected, [input]).frames[0].evidence[0].decision,
      "inside",
    );
    close(
      browser(selected, [input]).frames,
      native("--zone-evidence", [selected, input]),
    );
  }
});

test("non Ready and projection failures remain unavailable and frames can repeat or run backwards", () => {
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
  const expected = browser(source, inputs).frames;
  assert.deepEqual(
    expected.slice(0, 5).map((row) => row.unavailable[0].reason),
    statuses,
  );
  expected.slice(0, 5).forEach((row) => assert.equal(row.evidence.length, 0));
  assert.equal(expected[4].unavailable[0].segment_id, null);
  const order = [6, 5, 4, 3, 2, 1, 0, 0, 5];
  close(
    browser(
      source,
      order.map((i) => inputs[i]),
    ).frames,
    order.map((i) => expected[i]),
  );
  close(
    native("--zone-evidence", [source, ...order.map((i) => inputs[i])]),
    order.map((i) => expected[i]),
  );
  const mixed = frame(source, 9, [
    track(9, [0.5, 0.5], [0.01, 0, 0.01], 9),
    track(9, [0.5, 0.5], [0.01, 0, 0.01], 2, "rejected_projection"),
    track(9, [0.5, 0.5], [0.01, 0, 0.01], 5, "uncertain"),
  ]);
  const output = browser(source, [mixed]).frames[0];
  assert.deepEqual(
    output.evidence.map((row) => row.track_id),
    [9],
  );
  assert.deepEqual(
    output.unavailable.map((row) => row.track_id),
    [2, 5],
  );
});

test("old motion checkpoints continue in four directions before stateless region evaluation", (t) => {
  const { source, frames } = rawFixture(),
    input = config(
      [
        zone("wide", [
          [-100, -100],
          [100, -100],
          [100, 100],
          [-100, 100],
        ]),
      ],
      source.session_id,
    );
  const measured = native("--stream", [source, ...frames]),
    expected = browser(input, measured).frames;
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
        close(browser(input, outputs).frames, expected.slice(cut));
        close(
          native("--zone-evidence", [input, ...outputs]),
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
      zone_evaluators_per_continuation: 2,
    }),
  );
});

test("Brown old checkpoint warm reframe preserves future metric region evidence", () => {
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
    baseline = native("--stream", [{ resume: saved }, ...future]);
  const changed = native("--reframe", [
    {
      source: { resume: saved },
      transform: { scale_x: 0.5, scale_y: 1.25, offset_x: -40, offset_y: 16 },
    },
    ...future,
  ]);
  const source = config(
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
    actual = browser(source, native("--stream", changed)),
    expected = browser(source, baseline);
  assert.ok(actual.frames.some((row) => row.evidence.length));
  close(actual, expected);
});

test("raw strict geometry, identity and numerical failures expose no failed pure prefix", () => {
  const source = config(),
    first = frame(source, 100, [track(100)]),
    prefix = native("--zone-evidence", [source, first]);
  const invalidSources = [
    { ...source, zones: [] },
    { ...source, zones: [zone(), zone()] },
    { ...source, resume: {} },
    { ...source, max_tracks: 0 },
    { ...source, max_tracks: 10000, zones: [zone("a"), zone("b")] },
    ...[
      [
        [0, 0],
        [1, 0],
      ],
      [
        [0, 0],
        [1, 0],
        [1, 0],
        [0, 1],
      ],
      [
        [0, 0],
        [1, 1],
        [0, 1],
        [1, 0],
      ],
      [
        [0, 0],
        [2, 0],
        [0.5, 0.5],
        [0, 2],
      ],
      [
        [0, 0],
        [1, 0],
        [2, 0],
        [0, 1],
      ],
    ].map((points) => config([zone("invalid", points)])),
    line(source).replace('"max_tracks":32', '"max_tracks":32.000000000000001'),
    '{"session_id":"duplicate",' + line(source).slice(1),
  ];
  for (const invalid of invalidSources) failure(invoke(invalid, ""));
  for (const mutate of [
    (v) => v.tracks.push(clone(v.tracks[0])),
    (v) => v.tracks.push({ ...clone(v.tracks[0]), track_id: 2 }),
    (v) => (v.tracks[0].last_accepted_timestamp_us = "99"),
    (v) => (v.tracks[0].position_m = null),
    (v) => (v.tracks[0].position_covariance = [1, 2, 1]),
    (v) => (v.closed_segment_ids = ["1"]),
    (v) => (v.tracks[0].segment_id = "01"),
    (v) => (v.extra = 1),
  ]) {
    const invalid = clone(first);
    mutate(invalid);
    failure(invoke(source, ndjson([first, invalid])));
    assert.deepEqual(
      native("--zone-evidence", [source, first, invalid], 2),
      prefix,
    );
  }
  for (const [selected, point, cov] of [
    [
      zone("near", [
        [0, -2],
        [2, 0],
        [0, 2],
        [-2, 0],
      ]),
      [0, 0],
      [1, 1 - Number.EPSILON / 2, 1],
    ],
    [zone("radius", undefined, 1e308), [0.5, 0.5], [1e308, 0, 1e308]],
    [
      zone("underflow", undefined, Number.MIN_VALUE),
      [0.5, 0.5],
      [Number.MIN_VALUE, 0, Number.MIN_VALUE],
    ],
    [zone(), [1e300, 0.5], [1, 0, 1]],
  ]) {
    const head = config([selected]),
      value = frame(head, 0, [track(0, point, cov)]);
    failure(invoke(head, ndjson([value])));
    assert.deepEqual(native("--zone-evidence", [head, value], 2), []);
  }
  const capacity = config([zone()], source.session_id, 1);
  failure(
    invoke(
      capacity,
      ndjson([
        frame(source, 0, [
          track(0),
          track(0, [0, 0], [1, 0, 1], 2, "rejected_projection"),
        ]),
      ]),
    ),
  );
  close(
    browser(source, [line(first).replace('"track_id":1', '"track_id":10e-1')])
      .frames,
    prefix,
  );
  failure(
    invoke(
      source,
      ndjson([
        line(first).replace('"track_id":1', '"track_id":1.0000000000000001'),
      ]),
    ),
  );
  close(browser(source, [first]).frames, prefix);
});

test("actual line and batch budgets, all 65536 configured faces and pure calls with old handles occupied", (t) => {
  const Mi = 1048576,
    source = config(),
    empty = frame(source, 0, []),
    exact = line(source).padEnd(Mi, " ");
  assert.deepEqual(browser(exact).frames, []);
  failure(invoke(exact + " ", ""));
  assert.equal(browser(source, line(empty).padEnd(Mi, " ")).frames.length, 1);
  failure(invoke(source, line(empty).padEnd(Mi + 1, " ")));
  const frames = Array.from({ length: 5000 }, (_, i) => frame(source, i, [])),
    complete = browser(source, frames);
  assert.equal(complete.frames.length, 5000);
  assert.match(failure(invoke(source, ndjson([...frames, empty]))), /5000/);
  const exactMeasurements = Array.from(
    { length: 8 },
    (_, i) => line(frame(source, i, [])).padEnd(Mi - 1, " ") + "\n",
  ).join("");
  assert.equal(exactMeasurements.length, 8 * Mi);
  assert.equal(browser(source, exactMeasurements).frames.length, 8);
  failure(invoke(source, exactMeasurements + " "));
  const request = line({ source: line(source), measurements: "" }).padEnd(
    16 * Mi,
    " ",
  );
  assert.deepEqual(unpack(moonground_zone_evidence(request)).frames, []);
  failure(moonground_zone_evidence(request + " "));
  const vertices = Array.from({ length: 32 }, (_, i) => [
      10 * Math.cos((2 * Math.PI * i) / 32),
      10 * Math.sin((2 * Math.PI * i) / 32),
    ]),
    zones = Array.from({ length: 16 }, (_, i) => zone(String(i), vertices));
  const maximum = config(zones, "zone-maxfaces", 128);
  assert.deepEqual(browser(maximum).frames, []);
  failure(invoke({ ...maximum, max_tracks: 129 }, ""));
  const input = frame(
    maximum,
    0,
    Array.from({ length: 128 }, (_, i) =>
      track(0, [0, 0], [0.01, 0, 0.01], i + 1),
    ),
  );
  const nativeMaximum = native("--zone-evidence", [maximum, input]);
  assert.equal(nativeMaximum[0].evidence.length, 2048);
  const actualFaces = nativeMaximum[0].evidence.reduce(
    (sum, row) => sum + row.faces.length,
    0,
  );
  assert.equal(actualFaces, 65536);
  const pureMaximum = invoke(maximum, ndjson([input]));
  if (line({ frames: nativeMaximum }).length > 8 * Mi)
    assert.match(failure(pureMaximum), /output.*8388608/);
  else close(unpack(pureMaximum).frames, nativeMaximum);
  const outputHead = config(
    Array.from({ length: 16 }, (_, i) => zone(String(i))),
  );
  assert.match(
    failure(
      invoke(
        outputHead,
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
            line({ session_id: "occupied-zone-" + i, mode: "ground" }),
          ),
        ).handle,
      );
    assert.deepEqual(browser(source, frames), complete);
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
      native_maximum_return_utf16_units: line({ frames: nativeMaximum }).length,
      old_handles_occupied: 64,
    }),
  );
});
