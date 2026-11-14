import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_zone_evidence,
  moonground_zone_intersection,
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
  moonground_zone_intersection(line({ source: line(source), measurements }));
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

// Exact real arithmetic on the actual binary64 inputs, independent of the
// production outward-rounded interval algorithm.
const gcd = (a, b) => {
  a = a < 0n ? -a : a;
  while (b) {
    const r = a % b;
    a = b;
    b = r;
  }
  return a;
};
function R(n, d = 1n) {
  if (d < 0n) {
    n = -n;
    d = -d;
  }
  if (!n) return { n: 0n, d: 1n };
  const g = gcd(n, d);
  return { n: n / g, d: d / g };
}
const add = (a, b) => R(a.n * b.d + b.n * a.d, a.d * b.d),
  neg = (a) => R(-a.n, a.d),
  sub = (a, b) => add(a, neg(b)),
  mul = (a, b) => R(a.n * b.n, a.d * b.d),
  div = (a, b) => R(a.n * b.d, a.d * b.n),
  cmp = (a, b) => {
    const n = a.n * b.d - b.n * a.d;
    return n < 0n ? -1 : n > 0n ? 1 : 0;
  },
  zero = R(0n),
  one = R(1n);
function rational(value) {
  assert.ok(Number.isFinite(value));
  if (value === 0) return zero;
  const view = new DataView(new ArrayBuffer(8));
  view.setFloat64(0, value, false);
  const bits = view.getBigUint64(0, false),
    e = Number((bits >> 52n) & 2047n),
    sign = bits >> 63n ? -1n : 1n,
    m = (bits & ((1n << 52n) - 1n)) + (e ? 1n << 52n : 0n),
    power = e ? e - 1075 : -1074;
  return power >= 0
    ? R(sign * m * (1n << BigInt(power)))
    : R(sign * m, 1n << BigInt(-power));
}
const exactCache = new Map();
function exactMinimum(selected, point, covariance) {
  const key = line([selected.vertices_m, point, covariance]);
  if (exactCache.has(key)) return exactCache.get(key);
  const vertices = selected.vertices_m.map((p) => p.map(rational)),
    mu = point.map(rational),
    [xx, xy, yy] = covariance.map(rational),
    det = sub(mul(xx, yy), mul(xy, xy));
  assert.ok(cmp(det, zero) > 0);
  const metric = (u, v) =>
    div(
      add(
        sub(
          mul(yy, mul(u[0], v[0])),
          mul(xy, add(mul(u[0], v[1]), mul(u[1], v[0]))),
        ),
        mul(xx, mul(u[1], v[1])),
      ),
      det,
    );
  let area = zero;
  vertices.forEach((a, i) => {
    const b = vertices[(i + 1) % vertices.length];
    area = add(area, sub(mul(a[0], b[1]), mul(a[1], b[0])));
  });
  const sign = cmp(area, zero);
  const inside = vertices.every((a, i) => {
    const b = vertices[(i + 1) % vertices.length],
      e = [sub(b[0], a[0]), sub(b[1], a[1])],
      r = [sub(mu[0], a[0]), sub(mu[1], a[1])];
    return sign * cmp(sub(mul(e[0], r[1]), mul(e[1], r[0])), zero) >= 0;
  });
  let q = inside ? zero : null;
  if (!inside)
    vertices.forEach((a, i) => {
      const b = vertices[(i + 1) % vertices.length],
        e = [sub(b[0], a[0]), sub(b[1], a[1])],
        r = [sub(a[0], mu[0]), sub(a[1], mu[1])],
        t0 = div(neg(metric(r, e)), metric(e, e)),
        t = cmp(t0, zero) < 0 ? zero : cmp(t0, one) > 0 ? one : t0,
        v = [add(r[0], mul(t, e[0])), add(r[1], mul(t, e[1]))],
        value = metric(v, v);
      if (q === null || cmp(value, q) < 0) q = value;
    });
  const result = { q, inside, vertices, mu, metric };
  exactCache.set(key, result);
  return result;
}
function certify(output, source, measurement) {
  assert.equal(output.kind, "position_zone_intersection_frame");
  assert.equal(output.timestamp_us, measurement.timestamp_us);
  assert.equal(
    output.evidence_scope,
    "model_position_ellipse_convex_zone_intersection",
  );
  const expected = [];
  for (const t of [...measurement.tracks].sort(
    (a, b) => a.track_id - b.track_id,
  ))
    if (t.status === "ready")
      for (const selected of source.zones) expected.push([t, selected]);
  assert.equal(output.evidence.length, expected.length);
  output.evidence.forEach((row, i) => {
    const [t, z] = expected[i],
      { q, inside, vertices, mu, metric } = exactMinimum(
        z,
        t.position_m,
        t.position_covariance,
      ),
      lo = rational(row.minimum_quadratic_lower),
      hi = rational(row.minimum_quadratic_upper),
      threshold = mul(
        rational(z.sigma_multiplier ?? 2),
        rational(z.sigma_multiplier ?? 2),
      );
    assert.ok(
      cmp(lo, zero) >= 0 && cmp(lo, q) <= 0 && cmp(q, hi) <= 0,
      "exact Q escaped bounds",
    );
    assert.equal(row.track_id, t.track_id);
    assert.equal(row.segment_id, t.segment_id);
    assert.equal(row.zone_id, z.zone_id);
    if (row.decision === "disjoint") assert.ok(cmp(q, threshold) > 0);
    else if (row.decision === "intersects") assert.ok(cmp(q, threshold) <= 0);
    else assert.equal(row.decision, "indeterminate");
    if (row.witness_edge_index === null) {
      assert.equal(row.witness_fraction, null);
      assert.ok(inside);
      assert.ok(
        row.witness_position_m.every(
          (value, index) => value === t.position_m[index],
        ),
      );
    } else {
      const edge = row.witness_edge_index;
      assert.ok(Number.isInteger(edge) && edge >= 0 && edge < vertices.length);
      assert.ok(row.witness_fraction >= 0 && row.witness_fraction <= 1);
      const a = vertices[edge],
        b = vertices[(edge + 1) % vertices.length],
        f = rational(row.witness_fraction),
        v = [
          sub(add(a[0], mul(f, sub(b[0], a[0]))), mu[0]),
          sub(add(a[1], mul(f, sub(b[1], a[1]))), mu[1]),
        ];
      assert.ok(
        cmp(metric(v, v), hi) <= 0,
        "exact explicit witness escaped upper",
      );
    }
    assert.ok(row.witness_position_m.every(Number.isFinite));
  });
}

test("exact rational corner separation improves old face evidence and retains centre and tangent soundness", () => {
  const source = config([
      zone("one", undefined, 1),
      zone("zero", undefined, 0),
    ]),
    frames = [
      [1.125, 1.125],
      [1.125, 0.5],
      [0.5, 0.5],
      [1, 1],
    ].map((p, i) => frame(source, i, [track(i, p, [0.015625, 0, 0.015625])])),
    before = moonground_zone_evidence(
      line({ source: line(source), measurements: ndjson(frames) }),
    ),
    actual = browser(source, frames);
  actual.frames.forEach((out, i) => certify(out, source, frames[i]));
  assert.equal(actual.frames[0].evidence[0].decision, "disjoint");
  assert.equal(actual.frames[1].evidence[0].decision === "disjoint", false);
  assert.equal(actual.frames[2].evidence[0].minimum_quadratic_upper, 0);
  assert.equal(actual.frames[2].evidence[0].decision, "intersects");
  assert.equal(
    JSON.parse(before).frames[0].evidence[0].decision,
    "indeterminate",
  );
  assert.equal(
    moonground_zone_evidence(
      line({ source: line(source), measurements: ndjson(frames) }),
    ),
    before,
  );
  assert.deepEqual(
    native("--zone-intersection", [source, ...frames]),
    actual.frames,
  );
});

test("original binary64 fractions certify slanted boundary correlation scales and repeated unordered frames", () => {
  const cases = [
    {
      z: zone(
        "slanted",
        [
          [0, 0],
          [3, 4],
          [0, 5],
        ],
        0,
      ),
      points: [
        [0, 0],
        [3, 4],
        [1.5, 2],
        [1.5, 1.9999999999999998],
        [1.5, 2.0000000000000004],
      ],
      C: [1, 0, 1],
    },
  ];
  for (const scale of [1e-100, 1, 1e100])
    for (const sign of [-1, 1])
      cases.push({
        z: zone(
          "scaled",
          [
            [-scale, -scale],
            [scale, -scale],
            [scale, scale],
            [-scale, scale],
          ],
          1,
        ),
        points: [
          [1.2 * scale, 1.3 * scale],
          [0, 0],
        ],
        C: [scale * scale, sign * 0.9 * scale * scale, scale * scale],
      });
  const view = new DataView(new ArrayBuffer(8));
  view.setBigUint64(0, 0x001fffffffffffffn);
  cases.push({
    z: zone("boundary", undefined, 0),
    points: [[0.5, 2]],
    C: [2, 0, view.getFloat64(0)],
  });
  cases.push({
    z: zone("signedzero", undefined, 0),
    points: [
      [-0, 0],
      [-Number.MIN_VALUE, 0.5],
    ],
    C: [1, 0, 1],
  });
  for (const c of cases) {
    const source = config([c.z]),
      frames = c.points.map((p, i) => frame(source, i, [track(i, p, c.C)])),
      result = browser(source, frames);
    result.frames.forEach((out, i) => certify(out, source, frames[i]));
    assert.deepEqual(
      native("--zone-intersection", [source, ...frames]),
      result.frames,
    );
    assert.deepEqual(
      browser(source, [...frames].reverse().concat(frames)).frames,
      [...result.frames].reverse().concat(result.frames),
    );
  }
});

test("old measurement checkpoints cross runtimes at every cut before stateless intersection", (t) => {
  const f = rawFixture(),
    source = config(
      [
        zone(
          "wide",
          [
            [-100, -100],
            [100, -100],
            [100, 100],
            [-100, 100],
          ],
          1,
        ),
      ],
      f.source.session_id,
    ),
    measured = oldReplay(f.source, f.frames),
    expected = browser(source, measured.frames).frames;
  let comparisons = 0;
  for (let cut = 0; cut <= f.frames.length; cut++) {
    const js = oldReplay(f.source, f.frames.slice(0, cut)).checkpoint,
      n = native("--checkpoint", [f.source, ...f.frames.slice(0, cut)])[0];
    for (const cp of [js, n])
      for (const continued of [
        oldReplay(null, f.frames.slice(cut), cp).frames,
        native("--stream", [{ resume: cp }, ...f.frames.slice(cut)]),
      ]) {
        const result = browser(source, continued);
        close(result.frames, expected.slice(cut));
        close(
          native("--zone-intersection", [source, ...continued]),
          expected.slice(cut),
        );
        result.frames.forEach((out, i) => certify(out, source, continued[i]));
        comparisons++;
      }
  }
  t.diagnostic(
    JSON.stringify({
      cut_points: f.frames.length + 1,
      motion_checkpoint_runtime_directions: 4,
      comparisons,
    }),
  );
});

test("strict raw domain numerical conditioning and capacity failures preserve only native complete prefix", () => {
  const source = config(),
    first = frame(source, 100, [track(100)]),
    prefix = browser(source, [first]).frames;
  for (const bad of [
    { ...first, extra: true },
    { ...first, session_id: "other" },
    {
      ...first,
      tracks: [{ ...first.tracks[0], position_covariance: [1, 2, 1] }],
    },
    line(first).replace('"track_id":1', '"track_id":1.0000000000000001'),
    '{"tracks":[],' + line(first).slice(1),
  ]) {
    failure(invoke(source, ndjson([first, bad])));
    assert.deepEqual(
      native("--zone-intersection", [source, first, bad], 2),
      prefix,
    );
  }
  for (const C of [
    [0.9, 0.8999999999999999, 0.9],
    [1e308, 0, 1e-308],
  ])
    failure(
      invoke(source, ndjson([frame(source, 101, [track(101, [2, 2], C)])])),
    );
  for (const bad of [
    { ...source, extra: 1 },
    { ...source, max_tracks: 10000, zones: [zone("a"), zone("b")] },
    {
      ...source,
      zones: [
        zone("bad", [
          [0, 0],
          [1, 0],
          [1, 0],
          [0, 1],
        ]),
      ],
    },
    line(source).replace('"max_tracks":32', '"max_tracks":32.000000000000001'),
  ])
    failure(invoke(bad, ndjson([first])));
  assert.deepEqual(
    browser(source, line(first).replace('"track_id":1', '"track_id":10e-1'))
      .frames,
    prefix,
  );
});

test("real Brown and warm pixel reframe are independently certified against exact metric inputs", () => {
  const values = readFileSync(
      path.join(root, "examples/distorted-camera.ndjson"),
      "utf8",
    )
      .trim()
      .split(/\r?\n/)
      .map(JSON.parse),
    source = values[0];
  source.diagnostics = true;
  const raw = values.slice(1),
    cut = Math.min(4, raw.length - 1),
    cp = native("--checkpoint", [source, ...raw.slice(0, cut)])[0],
    future = native("--stream", [{ resume: cp }, ...raw.slice(cut)]),
    transform = { scale_x: 0.5, scale_y: 1.25, offset_x: -15, offset_y: 8 },
    changed = native("--reframe", [
      { source: { resume: cp }, transform },
      ...raw.slice(cut),
    ]),
    reframed = native("--stream", changed),
    head = config(
      [
        zone(
          "far",
          [
            [20, 20],
            [21, 20],
            [21, 21],
            [20, 21],
          ],
          1,
        ),
      ],
      source.session_id,
    ),
    a = browser(head, future),
    b = browser(head, reframed);
  assert.ok(a.frames.some((v) => v.evidence.length > 0));
  for (const [input, out] of [
    [future, a.frames],
    [reframed, b.frames],
  ])
    out.forEach((v, i) => certify(v, head, input[i]));
  assert.deepEqual(
    a.frames.map((v) => v.evidence.map((r) => r.decision)),
    b.frames.map((v) => v.evidence.map((r) => r.decision)),
  );
});

test("actual5000 empty frames handles and raw UTF16 transport limits are bounded without batch partials", (t) => {
  const source = config(),
    empty = Array.from({ length: 5000 }, (_, i) => frame(source, BigInt(i))),
    text = invoke(source, ndjson(empty)),
    result = unpack(text);
  assert.equal(result.frames.length, 5000);
  assert.ok(text.length <= 8 * 1048576);
  assert.match(failure(invoke(source, ndjson([...empty, empty[0]]))), /5000/);
  failure(invoke(source, " ".repeat(8 * 1048576 + 1)));
  failure(moonground_zone_intersection(" ".repeat(16 * 1048576 + 1)));
  const first = frame(source, 100, [track(100)]);
  assert.deepEqual(
    browser(line(source).padEnd(1048576), line(first).padEnd(1048576)),
    browser(source, [first]),
  );
  failure(invoke(line(source).padEnd(1048577), ""));
  failure(invoke(source, line(first).padEnd(1048577)));
  const handles = [];
  try {
    for (let i = 0; i < 64; i++) {
      const value = JSON.parse(
        moonground_create(line({ session_id: "occupied" + i, mode: "ground" })),
      );
      if (value.error) break;
      handles.push(value.handle);
    }
    assert.equal(handles.length, 64);
    assert.equal(browser(source, [first]).frames.length, 1);
  } finally {
    handles.forEach((h) => moonground_close(h));
  }
  t.diagnostic(
    JSON.stringify({
      successful_empty_frames: 5000,
      whole_return_utf16: text.length,
      source_frame_limit_utf16: 1048576,
      whole_output_limit_utf16: 8 * 1048576,
    }),
  );
});

test("maximum actual outside targets and32edge zones execute all supported projections before output budget", (t) => {
  const vertices = Array.from({ length: 32 }, (_, i) => [
      i - 15.5,
      i * i - 360,
    ]),
    source = config(
      Array.from({ length: 16 }, (_, i) => zone("z" + i, vertices, 1)),
      "intersection-max",
      128,
    ),
    measurement = frame(
      source,
      9007199254740993n,
      Array.from({ length: 128 }, (_, i) =>
        track(9007199254740993n, [1000, 1000], [0.01, 0, 0.01], i + 1),
      ),
    ),
    result = browser(source, [measurement]);
  assert.equal(result.frames[0].evidence.length, 2048);
  assert.ok(
    result.frames[0].evidence.every(
      (v) => v.decision === "disjoint" && v.witness_edge_index !== null,
    ),
  );
  certify(result.frames[0], source, measurement);
  assert.deepEqual(
    native("--zone-intersection", [source, measurement]),
    result.frames,
  );
  const repeated = Array.from({ length: 32 }, () => measurement),
    equivalent = line({
      frames: Array.from({ length: 32 }, () => result.frames[0]),
    }).length;
  assert.ok(equivalent > 8 * 1048576);
  assert.ok(ndjson(repeated).length < 8 * 1048576);
  assert.match(failure(invoke(source, ndjson(repeated))), /output exceeds/);
  t.diagnostic(
    JSON.stringify({
      maximum_actual_edges_times_targets: 65536,
      targets: 128,
      zones: 16,
      edges_per_zone: 32,
      evidence_rows: 2048,
      single_whole_return_utf16: line(result).length,
      repeated_output_frames: 32,
      equivalent_whole_return_utf16: equivalent,
    }),
  );
});
