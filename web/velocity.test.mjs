import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_velocity_evidence,
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
assert.ok(binary, "Build the native release before velocity verification.");
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
  moonground_velocity_evidence(line({ source: line(source), measurements }));
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
const probe = (id = "along", direction = [1, 0], threshold = 0, k = 2) => ({
  probe_id: id,
  direction,
  threshold_mps: threshold,
  sigma_multiplier: k,
});
const config = (
  probes = [probe()],
  session_id = "velocity-web",
  max_tracks = 32,
) => ({ session_id, probes, max_tracks });
function track(
  time,
  vector = [1, 0],
  covariance = [0.01, 0, 0.01],
  id = 1,
  status = "ready",
  segment = String(id),
) {
  const accepted = ["ready", "initializing", "uncertain"].includes(status);
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
  return {
    track_id: id,
    segment_id: segment,
    status,
    position_m: accepted ? [0, 0] : null,
    position_covariance: accepted ? [0.01, 0, 0.01] : null,
    velocity_mps: accepted && status !== "initializing" ? vector : null,
    velocity_covariance:
      accepted && status !== "initializing" ? covariance : null,
    position_std_m: accepted ? 0.1 : null,
    velocity_std_mps:
      accepted && status !== "initializing"
        ? Math.sqrt(Math.max(covariance[0], covariance[2]))
        : null,
    speed_mps:
      status === "ready" && Number.isFinite(Math.hypot(...vector))
        ? Math.hypot(...vector)
        : status === "ready"
          ? 0
          : null,
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

test("directed covariance separates anisotropy, signed thresholds and all closed boundary decisions", () => {
  const source = config([
    probe("forward", [1, 0], 0.5),
    probe("back", [-1, 0], -0.5),
    probe("across", [0, 1], 0),
  ]);
  const result = browser(source, [
    frame(source, 0, [track(0, [1, 0], [1e-6, 0, 1e6])]),
  ]);
  const [along, back, across] = result.frames[0].evidence;
  assert.equal(along.decision, "above");
  close(along.axis_std_mps, 0.001);
  close(along.lower_mps, 0.998);
  assert.equal(back.decision, "at_or_below");
  assert.equal(across.decision, "indeterminate");
  close(across.axis_std_mps, 1000);
  assert.equal(
    result.frames[0].evidence_scope,
    "model_velocity_component_band",
  );
  assert.deepEqual(Object.keys(result), ["frames"]);
  const boundary = config([probe("closed", [1, 0], 0.5)]);
  const rows = browser(
    boundary,
    [0, 1, 1 + Number.EPSILON].map((value, i) =>
      frame(boundary, i, [track(i, [value, 0], [0.0625, 0, 0.0625])]),
    ),
  ).frames;
  assert.deepEqual(
    rows.map((value) => value.evidence[0].decision),
    ["at_or_below", "indeterminate", "above"],
  );
  const meanOnly = config([probe("k0", [1, 0], -1, 0)]);
  const exact = browser(meanOnly, [frame(meanOnly, 0, [track(0, [-1, 0])])])
    .frames[0].evidence[0];
  assert.equal(exact.lower_mps, -1);
  assert.equal(exact.upper_mps, -1);
  assert.equal(exact.decision, "at_or_below");
  assert.ok(exact.axis_std_mps > 0);
  close(
    result.frames,
    native("--velocity-evidence", [
      source,
      frame(source, 0, [track(0, [1, 0], [1e-6, 0, 1e6])]),
    ]),
  );
});

test("ordinary orthogonal zero, compensated near zero, huge k0 dot and extreme direction normalization", () => {
  for (const [direction, vector, k, expected] of [
    [[1, 1], [1, -1], 2, 0],
    [[0.6, 0.8], [4, -3], 2, -6.661338147750939e-16],
    [[0.6, 0.8], [1e300, -7.5e299], 0, -1.6653345369377349e284],
    [[1e308, 1e308], [1, 2], 2, 3 / Math.sqrt(2)],
    [[Number.MIN_VALUE, Number.MIN_VALUE], [1, 2], 2, 3 / Math.sqrt(2)],
  ]) {
    const source = config([probe("dot", direction, 0, k)]),
      input = frame(source, 0, [track(0, vector, [1, 0, 1])]);
    const actual = browser(source, [input]).frames[0].evidence[0];
    close(actual.component_mps, expected);
    close(
      [browser(source, [input]).frames[0]],
      native("--velocity-evidence", [source, input]),
    );
  }
  for (const scale of [1e-150, 1, 1e150]) {
    const source = config([probe("correlated", [3, 4])]),
      input = frame(source, 0, [
        track(
          0,
          [3 * scale, scale],
          [scale * scale, 0.9 * scale * scale, scale * scale],
        ),
      ]);
    const actual = browser(source, [input]).frames[0].evidence[0];
    close(actual.axis_std_mps, Math.sqrt(1 + 0.96 * 0.9) * scale);
    close(actual.component_mps, 2.6 * scale);
    close(
      browser(source, [input]).frames,
      native("--velocity-evidence", [source, input]),
    );
  }
});

test("all non Ready statuses remain unavailable and stateless frames may repeat or run backwards", () => {
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
      track(9007199254740993n + BigInt(i), [1, 0], [1, 0, 1], i + 1, status),
    ]),
  );
  inputs.push(
    frame(source, 9223372036854775807n, [track(9223372036854775807n)]),
    frame(source, 0, []),
  );
  const expected = browser(source, inputs).frames;
  assert.deepEqual(
    expected.slice(0, 5).map((value) => value.unavailable[0].reason),
    statuses,
  );
  expected
    .slice(0, 5)
    .forEach((value) => assert.equal(value.evidence.length, 0));
  assert.equal(expected[4].unavailable[0].segment_id, null);
  const permutation = [6, 5, 4, 3, 2, 1, 0, 0, 5];
  close(
    browser(
      source,
      permutation.map((i) => inputs[i]),
    ).frames,
    permutation.map((i) => expected[i]),
  );
  close(
    native("--velocity-evidence", [
      source,
      ...permutation.map((i) => inputs[i]),
    ]),
    permutation.map((i) => expected[i]),
  );
  const mixed = frame(source, 8, [
    track(8, [1, 0], [1, 0, 1], 9, "ready"),
    track(8, [1, 0], [1, 0, 1], 2, "rejected_projection"),
    track(8, [1, 0], [1, 0, 1], 5, "uncertain"),
  ]);
  const result = browser(source, [mixed]).frames[0];
  assert.deepEqual(
    result.evidence.map((value) => value.track_id),
    [9],
  );
  assert.deepEqual(
    result.unavailable.map((value) => value.track_id),
    [2, 5],
  );
});

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

test("old motion checkpoints continue in four runtime directions before independent velocity evaluation", (t) => {
  const { source, frames } = rawFixture(),
    input = config(
      [probe(), probe("diagonal", [3, 4], -0.2)],
      source.session_id,
    );
  const measured = native("--stream", [source, ...frames]);
  const expected = browser(input, measured).frames;
  let continuations = 0;
  for (let cut = 0; cut <= frames.length; cut++) {
    const savedNative = native("--checkpoint", [
      source,
      ...frames.slice(0, cut),
    ])[0];
    const savedJS = oldReplay(source, frames.slice(0, cut)).checkpoint;
    close(savedJS, savedNative);
    for (const saved of [savedNative, savedJS]) {
      const nativeFrames = native("--stream", [
        { resume: saved },
        ...frames.slice(cut),
      ]);
      const jsFrames = oldReplay(source, frames.slice(cut), saved).frames;
      for (const outputs of [nativeFrames, jsFrames]) {
        close(browser(input, outputs).frames, expected.slice(cut));
        close(
          native("--velocity-evidence", [input, ...outputs]),
          expected.slice(cut),
        );
        continuations++;
      }
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
      velocity_evaluators_per_continuation: 2,
    }),
  );
});

test("Brown old checkpoint warm reframe preserves future model velocity bands", () => {
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
    future = records.slice(cut + 1);
  const baseline = native("--stream", [{ resume: saved }, ...future]);
  const converted = native("--reframe", [
    {
      source: { resume: saved },
      transform: { scale_x: 0.5, scale_y: 1.25, offset_x: -40, offset_y: 16 },
    },
    ...future,
  ]);
  const transformed = native("--stream", converted);
  const source = config(
    [probe(), probe("diagonal", [3, 4], -0.5)],
    records[0].session_id,
  );
  const expected = browser(source, baseline),
    actual = browser(source, transformed);
  assert.ok(actual.frames.some((value) => value.evidence.length));
  close(actual, expected);
});

test("strict raw tokens and numeric failures discard a pure batch while native preserves complete prefix", () => {
  const source = config(),
    first = frame(source, 100, [track(100)]);
  const prefix = native("--velocity-evidence", [source, first]);
  const malformed = [];
  for (const mutate of [
    (v) => v.tracks.push(clone(v.tracks[0])),
    (v) => v.tracks.push({ ...clone(v.tracks[0]), track_id: 2 }),
    (v) => (v.tracks[0].last_accepted_timestamp_us = "99"),
    (v) => (v.tracks[0].velocity_mps = null),
    (v) => (v.tracks[0].velocity_covariance = [1, 2, 1]),
    (v) => (v.closed_segment_ids = ["1"]),
    (v) => (v.tracks[0].segment_id = "01"),
    (v) => (v.extra = 1),
  ]) {
    const value = clone(first);
    mutate(value);
    malformed.push(value);
  }
  malformed.push(
    line(first).replace('"track_id":1', '"track_id":1.0000000000000001'),
  );
  for (const invalid of malformed) {
    failure(invoke(source, ndjson([first, invalid])));
    assert.deepEqual(
      native("--velocity-evidence", [source, first, invalid], 2),
      prefix,
    );
  }
  for (const [selected, vector, cov] of [
    [probe("near", [1, -1]), [1, 1], [1, 1 - Number.EPSILON / 2, 1]],
    [probe("radius", [1, 0], 0, 1e308), [0, 0], [1e308, 0, 1e308]],
    [
      probe("underflow", [1, 0], 0, Number.MIN_VALUE),
      [0, 0],
      [Number.MIN_VALUE, 0, Number.MIN_VALUE],
    ],
    [probe("collapsed"), [1e300, 0], [1, 0, 1]],
    [probe("dot", [0.6, 0.8]), [1e300, -7.5e299], [1, 0, 1]],
  ]) {
    const badSource = config([selected]),
      value = frame(badSource, 0, [track(0, vector, cov)]);
    failure(invoke(badSource, ndjson([value])));
    assert.deepEqual(native("--velocity-evidence", [badSource, value], 2), []);
  }
  for (const invalid of [
    { ...source, resume: {} },
    { ...source, probes: [] },
    { ...source, probes: [probe(), probe()] },
    { ...source, probes: [probe("zero", [0, 0])] },
    { ...source, max_tracks: 0 },
    line(source).replace('"max_tracks":32', '"max_tracks":32.000000000000001'),
    '{"session_id":"duplicate",' + line(source).slice(1),
  ])
    failure(invoke(invalid, ""));
  const capacity = config([probe()], source.session_id, 1),
    both = frame(source, 0, [
      track(0),
      track(0, [0, 0], [1, 0, 1], 2, "rejected_projection"),
    ]);
  failure(invoke(capacity, ndjson([both])));
  close(
    browser(source, [line(first).replace('"track_id":1', '"track_id":10e-1')])
      .frames,
    prefix,
  );
  close(browser(source, [first]).frames, prefix);
});

test("actual source, line, batch, wrapper and output budgets with 16 probes and no handles", (t) => {
  const Mi = 1048576,
    source = config(),
    empty = frame(source, 0, []),
    exact = line(source).padEnd(Mi, " ");
  assert.deepEqual(browser(exact).frames, []);
  failure(invoke(exact + " ", ""));
  assert.equal(browser(source, line(empty).padEnd(Mi, " ")).frames.length, 1);
  failure(invoke(source, line(empty).padEnd(Mi + 1, " ")));
  const frames = Array.from({ length: 5000 }, (_, i) =>
    frame(source, BigInt(i), []),
  );
  const complete = browser(source, frames);
  assert.equal(complete.frames.length, 5000);
  assert.match(failure(invoke(source, ndjson([...frames, empty]))), /5000/);
  const exactObservations = Array.from(
    { length: 8 },
    (_, i) => line(frame(source, i, [])).padEnd(Mi - 1, " ") + "\n",
  ).join("");
  assert.equal(exactObservations.length, 8 * Mi);
  assert.equal(browser(source, exactObservations).frames.length, 8);
  failure(invoke(source, exactObservations + " "));
  const request = line({ source: line(source), measurements: "" }).padEnd(
    16 * Mi,
    " ",
  );
  assert.deepEqual(unpack(moonground_velocity_evidence(request)).frames, []);
  failure(moonground_velocity_evidence(request + " "));
  failure(
    moonground_velocity_evidence(
      line({ source: line(source), measurements: "", extra: true }),
    ),
  );
  const wide = config(
    Array.from({ length: 16 }, (_, i) => probe(String(i), [1, i % 2], -0.1)),
  );
  const actual = browser(wide, [
    frame(
      wide,
      0,
      Array.from({ length: 32 }, (_, i) => track(0, [1, 2], [1, 0, 1], i + 1)),
    ),
  ]);
  assert.equal(actual.frames[0].evidence.length, 512);
  close(
    actual.frames,
    native("--velocity-evidence", [
      wide,
      frame(
        wide,
        0,
        Array.from({ length: 32 }, (_, i) =>
          track(0, [1, 2], [1, 0, 1], i + 1),
        ),
      ),
    ]),
  );
  const outputOverflow = Array.from({ length: 5000 }, (_, i) =>
    frame(wide, i, [track(i)]),
  );
  assert.match(
    failure(invoke(wide, ndjson(outputOverflow))),
    /output.*8388608/,
  );
  const handles = [];
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(
            line({ session_id: "occupied-" + i, mode: "ground" }),
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
      max_configured_probes: 16,
      actual_evidence_rows: 512,
      output_overflow_rejected: true,
      old_handles_occupied: 64,
    }),
  );
});
