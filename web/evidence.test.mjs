import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_gate_evidence,
  moonground_gates,
  moonground_create,
  moonground_close,
} from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.env.MOONGROUND_CLI
  ? path.resolve(root, process.env.MOONGROUND_CLI)
  : ["main.exe", "main"]
      .map((v) => path.join(root, "_build/native/release/build/cmd/main", v))
      .find(existsSync);
assert.ok(binary, "Build the native CLI before evidence verification.");
const clone = (v) => JSON.parse(JSON.stringify(v));
const line = (v) => (typeof v === "string" ? v : JSON.stringify(v));
const ndjson = (records) =>
  records.map(line).join("\n") + (records.length ? "\n" : "");
const unpack = (text) => {
  const v = JSON.parse(text);
  assert.equal(v.error, undefined, text.slice(0, 1000));
  return v;
};
const failure = (text) => {
  const v = JSON.parse(text);
  assert.equal(typeof v.error, "string", text.slice(0, 1000));
  assert.deepEqual(
    Object.keys(v),
    ["error"],
    "pure failure exposed partial data",
  );
  return v.error;
};
const invoke = (source, measurements) =>
  moonground_gate_evidence(
    JSON.stringify({ source: line(source), measurements }),
  );
const browser = (source, frames = []) =>
  unpack(invoke(source, typeof frames === "string" ? frames : ndjson(frames)));

function close(actual, expected, where = "$") {
  if (typeof expected === "number") {
    assert.equal(typeof actual, "number", where);
    assert.ok(Number.isFinite(actual), where);
    assert.ok(
      Math.abs(actual - expected) <=
        3e-10 * Math.max(Math.abs(expected), 1e-300),
      `${where}: ${actual} != ${expected}`,
    );
  } else if (Array.isArray(expected)) {
    assert.equal(actual.length, expected.length, where);
    expected.forEach((v, i) => close(actual[i], v, `${where}[${i}]`));
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
  const run = spawnSync(binary, [mode, ...extra], {
    input: ndjson(records),
    encoding: "utf8",
    maxBuffer: 48 * 1024 * 1024,
    timeout: 120000,
  });
  assert.equal(run.status, status, run.stderr || run.error?.message);
  if (!status) assert.equal(run.stderr, "");
  if (run.stdout)
    assert.ok(run.stdout.endsWith("\n"), "partial native output line");
  if (status && mode === "--evidence-checkpoint") assert.equal(run.stdout, "");
  return run.stdout ? run.stdout.trimEnd().split("\n").map(JSON.parse) : [];
}
const gate = (
  id = "horizontal",
  start = [-1, 0],
  end = [1, 0],
  band = 0.05,
) => ({ gate_id: id, start_m: start, end_m: end, deadband_m: band });
function config(k = 2, gates = [gate()], name = "evidence-browser") {
  return {
    counting: line({
      session_id: name,
      gates,
      max_tracks: 32,
      max_gap_us: "500000",
    }),
    sigma_multiplier: k,
  };
}
function track(
  point,
  time,
  covariance = [0.01, 0, 0.01],
  id = 1,
  segment = "1",
) {
  return {
    track_id: id,
    segment_id: segment,
    status: "ready",
    position_m: point,
    position_covariance: covariance,
    velocity_mps: [0, 0],
    velocity_covariance: [0.04, 0, 0.04],
    position_std_m: 0.1,
    velocity_std_mps: 0.2,
    speed_mps: 0,
    observed_path_length_m: 0,
    net_displacement_m: 0,
    accepted_count: 3,
    last_accepted_timestamp_us: String(time),
  };
}
function frame(source, time, tracks = [], closed = []) {
  return {
    schema_version: "0.2.0",
    session_id: JSON.parse(source.counting).session_id,
    timestamp_us: String(time),
    tracks,
    closed_segment_ids: closed,
    uncertainty_scope: "conditional_on_fixed_calibration_camera_and_anchor",
  };
}
function fixture(start = 9007199254740993n, k = 2) {
  const source = config(k, [gate(), gate("vertical", [0, -1], [0, 1])]),
    frames = [];
  const points = [
    [0, -1],
    [0, 0.1],
    [0, 1],
    [0, -1],
    [2, 1],
    [1, -1],
    [0, 0],
    [0, 1],
    [0, -1],
    [0, 1],
    [0, -1],
  ];
  points.forEach((point, i) => {
    const t = start + BigInt(i) * 100000n;
    const cov = i === 2 ? [1, 0.2, 1] : [0.01, 0.002, 0.02];
    const items = [
      track(point, t, cov, 7, "7"),
      track([point[1], point[0]], t, [0.04, -0.005, 0.01], 2, "2"),
    ];
    frames.push(frame(source, t, i === 6 ? [] : items));
  });
  return { source, frames };
}

test("normal covariance bands match analytic axes and correlated rotated cases", () => {
  const source = config(2, [
    gate("horizontal"),
    gate("vertical", [0, -1], [0, 1]),
  ]);
  const result = browser(source, [
    frame(source, 0, [track([1, 1], 0, [100, 0, 0.0001])]),
  ]);
  const [h, v] = result.frames[0].evidence;
  close(h.normal_std_m, 0.01);
  close(v.normal_std_m, 10);
  assert.equal(h.side, "positive");
  assert.equal(v.side, "unconfirmed");
  const rotated = config(2, [gate("diagonal", [-1, 1], [1, -1], 0)]);
  const item = browser(rotated, [
    frame(rotated, 0, [track([1, 1], 0, [1, -0.9, 1])]),
  ]).frames[0].evidence[0];
  close(item.normal_std_m, Math.sqrt(0.1));
  close(item.distance_m, Math.sqrt(2));
  assert.equal(item.side, "positive");
  close(item.lower_m, Math.sqrt(2) - 2 * Math.sqrt(0.1));
});

test("every saved cut continues in all four native/browser directions", (t) => {
  const { source, frames } = fixture(),
    expected = browser(source, frames);
  close(expected.frames, native("--count-evidence", [source, ...frames]));
  close(
    expected.checkpoint,
    native("--evidence-checkpoint", [source, ...frames])[0],
  );
  let continuations = 0;
  for (let cut = 0; cut <= frames.length; cut++) {
    const prefix = frames.slice(0, cut),
      suffix = frames.slice(cut);
    const saves = [
      native("--evidence-checkpoint", [source, ...prefix])[0],
      browser(source, prefix).checkpoint,
    ];
    close(saves[0], saves[1]);
    for (const saved of saves) {
      const resume = { resume: saved },
        result = browser(resume, suffix);
      close(result.frames, expected.frames.slice(cut));
      close(result.checkpoint, expected.checkpoint);
      continuations++;
      close(
        native("--count-evidence", [resume, ...suffix]),
        expected.frames.slice(cut),
      );
      close(
        native("--evidence-checkpoint", [resume, ...suffix])[0],
        expected.checkpoint,
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
        "native_to_browser",
        "browser_to_native",
        "browser_to_browser",
      ],
    }),
  );
});

test("zero multiplier preserves the existing counter on supported covariance inputs", () => {
  const { source, frames } = fixture(0n, 0),
    actual = browser(source, frames);
  const old = unpack(
    moonground_gates(
      JSON.stringify({ source: source.counting, measurements: ndjson(frames) }),
    ),
  );
  assert.deepEqual(
    actual.frames.map((v) => v.counting),
    old.frames,
  );
  const state = clone(actual.checkpoint.state);
  for (const item of state.tracks)
    for (const anchor of item.anchors) if (anchor) delete anchor.covariance;
  assert.deepEqual(state, old.checkpoint.state);
  const missing = clone(frames[0]);
  missing.tracks[0].position_covariance = null;
  failure(invoke(source, ndjson([missing])));
});

test("unconfirmed observations retain the original covariance and cannot extend anchor lifetime", () => {
  for (const start of [9007199254740993n, 9223372036854775807n - 500000n]) {
    const source = config(),
      a = frame(source, start, [track([0, -1], start)]),
      b = frame(source, start + 250000n, [
        track([0, 1], start + 250000n, [1, 0.2, 1]),
      ]);
    const middle = browser(source, [a, b]);
    assert.equal(middle.frames[1].evidence[0].side, "unconfirmed");
    const anchor = middle.checkpoint.state.tracks[0].anchors[0];
    assert.equal(anchor.timestamp_us, String(start));
    assert.deepEqual(anchor.covariance, [0.01, 0, 0.01]);
    const before = browser({ resume: middle.checkpoint }, [
      frame(source, start + 499999n, [track([0, 1], start + 499999n)]),
    ]);
    assert.equal(before.frames[0].counting.crossings.length, 1);
    const expired = browser({ resume: middle.checkpoint }, [
      frame(source, start + 500000n, [track([0, 1], start + 500000n)]),
    ]);
    assert.equal(expired.frames[0].counting.crossings.length, 0);
  }
});

test("strict raw documents and corrupted covariant anchors return only an error", () => {
  const { source, frames } = fixture(),
    saved = browser(source, frames.slice(0, 1)).checkpoint;
  const old = unpack(
    moonground_gates(
      JSON.stringify({ source: source.counting, measurements: "" }),
    ),
  ).checkpoint;
  const badSources = [
    { ...source, sigma_multiplier: -1 },
    { ...source, counting: JSON.parse(source.counting) },
    '{"sigma_multiplier":0,' + line(source).slice(1),
    { resume: old },
    { ...source, counting: line({ resume: old }) },
    {
      ...source,
      counting: source.counting.replace(
        '"max_tracks":32',
        '"max_tracks":32.0000000000000001',
      ),
    },
  ];
  for (const value of badSources) failure(invoke(value, ""));
  close(
    browser({ counting: source.counting }, frames),
    browser(source, frames),
  );
  for (const mutate of [
    (v) => delete v.state.tracks[0].anchors[1].covariance,
    (v) => (v.state.tracks[0].anchors[1].covariance = [1, 2, 1]),
    (v) => (v.state.tracks[0].anchors[1].covariance = [1, 0, 1]),
    (v) =>
      (v.state.tracks[0].anchors[1].timestamp_us = String(9007199254740994n)),
    (v) => (v.state.last_timestamp_us = String(9007199255240993n)),
    (v) => (v.configuration.sigma_multiplier = -1),
    (v) => delete v.configuration.counting.max_gap_us,
    (v) => delete v.configuration.counting.max_tracks,
    (v) => delete v.configuration.counting.gates[0].deadband_m,
  ]) {
    const bad = clone(saved);
    mutate(bad);
    failure(invoke({ resume: bad }, ""));
  }
  const before = line(saved),
    invalid = clone(frames[1]);
  invalid.tracks[0].position_covariance = [1, 2, 1];
  failure(invoke(source, ndjson([frames[0], invalid])));
  native("--evidence-checkpoint", [source, frames[0], invalid], 2);
  assert.equal(line(saved), before);
  close(
    browser({ resume: saved }, [frames[1]]).checkpoint,
    browser(source, frames.slice(0, 2)).checkpoint,
  );
});

test("exact Int64 counters, saturation rejection, and corrected same-time replay retain durable state", () => {
  const source = config(),
    frames = [
      frame(source, 0, [track([0, -1], 0)]),
      frame(source, 1, [track([0, 1], 1)]),
    ];
  const saved = browser(source, frames.slice(0, 1)).checkpoint;
  saved.state.counts[0].negative_to_positive = "9007199254740993";
  assert.equal(
    browser({ resume: saved }, frames.slice(1)).frames[0].counting.counts[0]
      .negative_to_positive,
    "9007199254740994",
  );
  saved.state.counts[0].negative_to_positive = "9223372036854775807";
  failure(invoke({ resume: saved }, ndjson(frames.slice(1))));
  const corrected = browser({ resume: saved }, [
    frame(source, 1, [track([0, -0.5], 1)]),
  ]);
  assert.equal(corrected.checkpoint.state.last_timestamp_us, "1");
  assert.deepEqual(corrected.checkpoint.state.counts, saved.state.counts);
});

test("unsupported covariance precision and interval arithmetic fail without a pure output prefix", () => {
  for (const [variance, offDiagonal] of [
    [1, -0.9999999999999999],
    [1e300, -9.999999999999999e299],
    [1e-300, -9.999999999999999e-301],
  ]) {
    const scale = Math.sqrt(variance),
      source = config(2, [
        gate("diagonal", [-scale, scale], [scale, -scale], 0),
      ]);
    const empty = frame(source, 0),
      invalid = frame(source, 1, [
        track([scale, scale], 1, [variance, offDiagonal, variance]),
      ]);
    failure(invoke(source, ndjson([empty, invalid])));
    assert.equal(
      native("--count-evidence", [source, empty, invalid], 2).length,
      1,
    );
    native("--evidence-checkpoint", [source, empty, invalid], 2);
  }
  for (const [k, point, cov] of [
    [5e-324, [0, 1e-149], [1e-300, 0, 1e-300]],
    [1e308, [0, 1], [100, 0, 100]],
    [2, [0, 1e200], [1, 0, 1]],
  ]) {
    const source = config(k),
      empty = frame(source, 0),
      saved = browser(source, [empty]).checkpoint;
    failure(
      invoke(
        { resume: saved },
        ndjson([frame(source, 1, [track(point, 1, cov)])]),
      ),
    );
    assert.equal(
      browser({ resume: saved }, [frame(source, 1)]).checkpoint.state
        .last_timestamp_us,
      "1",
    );
  }
});

test("inherited source, frame, input, frame-count and request limits are exact", () => {
  const source = config(),
    empty = (i) => frame(source, i),
    saved = browser(source).checkpoint;
  const exactSource = line({ resume: saved }).padEnd(8388619, " ");
  assert.deepEqual(browser(exactSource).checkpoint, saved);
  failure(invoke(exactSource + " ", ""));
  const padded = line(empty(0)).padEnd(1048576, " ");
  assert.equal(browser(source, padded + "\n").frames.length, 1);
  failure(invoke(source, padded + " \n"));
  const input = Array.from(
    { length: 8 },
    (_, i) => line(empty(i)).padEnd(1048575, " ") + "\n",
  ).join("");
  assert.equal(input.length, 8388608);
  assert.equal(browser(source, input).frames.length, 8);
  failure(invoke(source, input + " "));
  const frames = Array.from({ length: 5000 }, (_, i) => empty(i));
  assert.equal(browser(source, frames).frames.length, 5000);
  failure(invoke(source, ndjson([...frames, empty(5000)])));
  const request = JSON.stringify({
    source: line(source),
    measurements: "",
  }).padEnd(16777216, " ");
  unpack(moonground_gate_evidence(request));
  failure(moonground_gate_evidence(request + " "));
});

test("the complete pure result budget includes the covariance checkpoint", () => {
  const limit = 8388608;
  let source, selected;
  for (let width = 1; width <= 128 && !selected; width++) {
    source = config(
      2,
      Array.from({ length: 16 }, (_, i) => gate(String(i).padEnd(width, "x"))),
    );
    const prototype = browser(source, [frame(source, 0, [track([0, 0], 0)])]);
    const frameLength = line(prototype.frames[0]).length;
    let sum = 0;
    for (let count = 1; count <= 5000; count++) {
      const time = String(count - 1);
      sum += frameLength + time.length - 1;
      prototype.checkpoint.state.last_timestamp_us = time;
      const size =
        '{"frames":['.length +
        sum +
        count -
        1 +
        '],"checkpoint":'.length +
        line(prototype.checkpoint).length +
        1;
      if (size > limit) {
        if (sum + count <= limit)
          selected = { count, size, frameBuffer: sum + count };
        break;
      }
    }
  }
  assert.ok(
    selected && selected.frameBuffer <= limit,
    "could not isolate final checkpoint budget",
  );
  const frames = Array.from({ length: selected.count }, (_, i) =>
    frame(source, i, [track([0, 0], i)]),
  );
  assert.equal(
    browser(source, frames.slice(0, -1)).frames.length,
    frames.length - 1,
  );
  assert.match(failure(invoke(source, ndjson(frames))), /output.*8388608/);
});

test("512 actual anchors round-trip; pure evidence remains available with 64 old handles occupied", () => {
  const source = config(
      2,
      Array.from({ length: 16 }, (_, i) => gate(String(i))),
    ),
    items = Array.from({ length: 32 }, (_, i) =>
      track([0, -1], 0, [0.01, 0, 0.01], i + 1, String(i + 1)),
    );
  const result = browser(source, [frame(source, 0, items)]);
  assert.equal(result.frames[0].evidence.length, 512);
  assert.equal(
    result.checkpoint.state.tracks.flatMap((v) => v.anchors).filter(Boolean)
      .length,
    512,
  );
  close(browser({ resume: result.checkpoint }).checkpoint, result.checkpoint);
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
    close(browser(source, [frame(source, 0, items)]), result);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
});
