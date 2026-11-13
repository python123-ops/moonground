import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_evidence_transit,
  moonground_transit_windows,
  moonground_create,
  moonground_close,
} from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.env.MOONGROUND_CLI
  ? path.resolve(root, process.env.MOONGROUND_CLI)
  : ["main.exe", "main"]
      .map((name) =>
        path.join(root, "_build/native/release/build/cmd/main", name),
      )
      .find(existsSync);
assert.ok(
  binary,
  "Build the native release CLI before evidence transit verification.",
);
const clone = (value) => JSON.parse(JSON.stringify(value));
const line = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
const ndjson = (values) =>
  values.map(line).join("\n") + (values.length ? "\n" : "");

function unpack(text) {
  const value = JSON.parse(text);
  assert.equal(value.error, undefined, text.slice(0, 1000));
  return value;
}

function failure(text) {
  const value = JSON.parse(text);
  assert.equal(typeof value.error, "string", text.slice(0, 1000));
  assert.deepEqual(
    Object.keys(value),
    ["error"],
    "failed batch exposed partial events/checkpoint",
  );
  return value.error;
}

function closeNumeric(actual, expected, location = "$") {
  if (typeof expected === "number") {
    assert.equal(typeof actual, "number", location);
    assert.ok(Number.isFinite(actual), location);
    if (/\.(track_id|pending_count|max_tracks)$/.test(location))
      assert.equal(actual, expected, location);
    else
      assert.ok(
        Math.abs(actual - expected) <= 2e-10 * Math.max(1, Math.abs(expected)),
        `${location}: ${actual} != ${expected}`,
      );
  } else if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual), location);
    assert.equal(actual.length, expected.length, location);
    expected.forEach((value, index) =>
      closeNumeric(actual[index], value, `${location}[${index}]`),
    );
  } else if (expected && typeof expected === "object") {
    assert.deepEqual(
      Object.keys(actual).sort(),
      Object.keys(expected).sort(),
      location,
    );
    for (const key of Object.keys(expected))
      closeNumeric(actual[key], expected[key], `${location}.${key}`);
  } else assert.equal(actual, expected, location);
}

function native(mode, values, status = 0, extra = []) {
  const run = spawnSync(binary, [mode, ...extra], {
    input: ndjson(values),
    encoding: "utf8",
    maxBuffer: 40 * 1024 * 1024,
    timeout: 120000,
  });
  assert.equal(run.status, status, run.stderr || run.error?.message);
  if (!status) assert.equal(run.stderr, "");
  if (run.stdout)
    assert.ok(run.stdout.endsWith("\n"), "partial native output line");
  if (status && mode.endsWith("checkpoint")) assert.equal(run.stdout, "");
  return run.stdout ? run.stdout.trimEnd().split("\n").map(JSON.parse) : [];
}

const invoke = (source, measurements) =>
  moonground_evidence_transit(
    JSON.stringify({ source: line(source), measurements }),
  );
const browser = (source, measurements = []) =>
  unpack(
    invoke(
      source,
      typeof measurements === "string" ? measurements : ndjson(measurements),
    ),
  );
const gate = (gate_id, y) => ({
  gate_id,
  start_m: [-1, y],
  end_m: [1, y],
  deadband_m: 0.05,
});
const section = (section_id, entry_gate_id, exit_gate_id, direction) => ({
  section_id,
  entry_gate_id,
  exit_gate_id,
  entry_direction: direction,
  exit_direction: direction,
});

function config(name = "transit-parity") {
  return {
    counting: line({
      counting: line({
        session_id: name,
        gates: [gate("exit", 3), gate("entry", 0)],
        max_tracks: 16,
        max_gap_us: "500000",
      }),
      sigma_multiplier: 2,
    }),
    sections: [
      section("forward", "entry", "exit", "negative_to_positive"),
      section("backward", "exit", "entry", "positive_to_negative"),
    ],
    max_duration_us: "300000000",
  };
}

function track(track_id, point, timestamp, segment_id = "1", status = "ready") {
  const accepted = ["initializing", "ready", "uncertain"].includes(status);
  return {
    track_id,
    segment_id,
    status,
    position_m: accepted ? point : null,
    position_covariance: accepted ? [0.01, 0, 0.01] : null,
    velocity_mps: accepted ? [0, 0] : null,
    velocity_covariance: accepted ? [0.04, 0, 0.04] : null,
    position_std_m: accepted ? 0.1 : null,
    velocity_std_mps: accepted ? 0.2 : null,
    speed_mps: status === "ready" ? 0 : null,
    observed_path_length_m: 0,
    net_displacement_m: 0,
    accepted_count: 3,
    last_accepted_timestamp_us: String(
      accepted ? timestamp : BigInt(timestamp) - 1n,
    ),
  };
}

function frame(timestamp, tracks = [], name = "transit-parity", closed = []) {
  return {
    schema_version: "0.2.0",
    session_id: name,
    timestamp_us: String(timestamp),
    tracks,
    closed_segment_ids: closed,
    uncertainty_scope: "conditional_on_fixed_calibration_camera_and_anchor",
  };
}

function fixture() {
  const source = config();
  const start = 9007199254740993n;
  const points = [
    [0, -1],
    [0, 1],
    [0, 2],
    [0, 4],
    [0, 2],
    [0, 1],
    [0, -1],
    [0, 4],
  ];
  const frames = points.map((point, i) =>
    frame(start + BigInt(i) * 100000n, [
      track(1, point, start + BigInt(i) * 100000n),
    ]),
  );
  frames.push(frame(start + 800000n, [], "transit-parity", ["1"]));
  frames.push(frame(start + 900000n, [track(1, [0, 4], start + 900000n, "2")]));
  return { source, frames };
}

const MAX = 9223372036854775807n;
const reasons = [
  "discontinuity",
  "expired",
  "reentered",
  "reversed",
  "ambiguous_order",
];
const windowSource = (
  transit,
  width = 250000n,
  limits = [0n, 1n, 100000n, 200000n, 300000n, MAX],
  origin = 0n,
) => ({
  transit: line(transit),
  window_us: String(width),
  duration_limits_us: limits.map(String),
  origin_us: String(origin),
});
const invokeWindows = (source, transits) =>
  moonground_transit_windows(
    JSON.stringify({ source: line(source), transits }),
  );
const windows = (source, frames = []) =>
  unpack(
    invokeWindows(source, typeof frames === "string" ? frames : ndjson(frames)),
  );
const timestamp = (value) => BigInt(value.counting.counting.timestamp_us);

function recount(frames, source, sections) {
  const width = BigInt(source.window_us),
    origin = BigInt(source.origin_us ?? "0");
  const first = timestamp(frames[0]),
    last = timestamp(frames.at(-1));
  const start = origin + ((first - origin) / width) * width;
  return {
    start_us: String(start),
    end_exclusive_us: start + width <= MAX ? String(start + width) : null,
    first_timestamp_us: String(first),
    last_timestamp_us: String(last),
    input_frames: String(frames.length),
    sections: sections.map((section) => {
      const passages = frames
        .flatMap((frame) => frame.passages)
        .filter((item) => item.section_id === section.section_id);
      const cancellations = frames
        .flatMap((frame) => frame.cancellations)
        .filter((item) => item.section_id === section.section_id);
      return {
        section_id: section.section_id,
        completed: String(passages.length),
        duration_limits: source.duration_limits_us.map((limit) => {
          const within = passages.filter(
            (item) => BigInt(item.elapsed_upper_us) <= BigInt(limit),
          ).length;
          const exceeded = passages.filter(
            (item) => BigInt(item.elapsed_lower_us) > BigInt(limit),
          ).length;
          return {
            limit_us: limit,
            within: String(within),
            exceeded: String(exceeded),
            indeterminate: String(passages.length - within - exceeded),
          };
        }),
        cancellations: reasons.map((reason) => ({
          reason,
          count: String(
            cancellations.filter((item) => item.reason === reason).length,
          ),
        })),
      };
    }),
  };
}

function offline(frames, source, sections, session_id) {
  const groups = new Map(),
    output = [];
  const width = BigInt(source.window_us),
    origin = BigInt(source.origin_us ?? "0");
  let previous;
  for (const frame of frames) {
    const time = timestamp(frame),
      index = (time - origin) / width;
    let closed_window = null,
      unobserved_windows = 0n;
    if (!groups.has(index)) {
      if (previous !== undefined) {
        closed_window = recount(groups.get(previous), source, sections);
        unobserved_windows = index - previous - 1n;
      }
      groups.set(index, []);
      previous = index;
    }
    groups.get(index).push(frame);
    output.push({
      schema_version: "0.1.0",
      kind: "evidence_transit_window_frame",
      session_id,
      timestamp_us: String(time),
      closed_window,
      current_window: recount(groups.get(index), source, sections),
      unobserved_windows: String(unobserved_windows),
      classification_scope: "observed_chord_elapsed_bounds",
    });
  }
  return output;
}

test("integer offline groups match native and pure windows on complete upstream outcomes", () => {
  const { source, frames } = fixture();
  const upstream = browser(source, frames);
  const header = windowSource(source);
  const actual = windows(header, upstream.frames);
  assert.deepEqual(
    actual.frames,
    offline(upstream.frames, header, source.sections, "transit-parity"),
  );
  assert.deepEqual(
    actual.frames,
    native("--transit-windows", [header, ...upstream.frames]),
  );
  assert.deepEqual(
    actual.checkpoint,
    native("--transit-windows-checkpoint", [header, ...upstream.frames])[0],
  );
  assert.ok(actual.frames.some((value) => value.closed_window));
  assert.ok(
    actual.frames
      .flatMap((value) => value.current_window.sections)
      .some((value) => value.completed !== "0"),
  );
  for (const value of actual.frames)
    for (const section of value.current_window.sections) {
      for (const limit of section.duration_limits)
        assert.equal(
          BigInt(limit.within) +
            BigInt(limit.exceeded) +
            BigInt(limit.indeterminate),
          BigInt(section.completed),
        );
      assert.equal(section.duration_limits[0].within, "0");
      assert.equal(section.duration_limits.at(-1).within, section.completed);
    }
});

test("every cut preserves closed and current windows across four runtime directions", (context) => {
  const { source, frames } = fixture();
  const events = browser(source, frames).frames,
    header = windowSource(source);
  const complete = windows(header, events);
  let cuts = 0,
    continuations = 0;
  for (let cut = 0; cut <= events.length; cut++) {
    const nativeSaved = native("--transit-windows-checkpoint", [
      header,
      ...events.slice(0, cut),
    ])[0];
    const webSaved = windows(header, events.slice(0, cut)).checkpoint;
    assert.deepEqual(nativeSaved, webSaved);
    for (const saved of [nativeSaved, webSaved]) {
      assert.deepEqual(windows({ resume: saved }, events.slice(cut)), {
        frames: complete.frames.slice(cut),
        checkpoint: complete.checkpoint,
      });
      assert.deepEqual(
        native("--transit-windows", [{ resume: saved }, ...events.slice(cut)]),
        complete.frames.slice(cut),
      );
      assert.deepEqual(
        native("--transit-windows-checkpoint", [
          { resume: saved },
          ...events.slice(cut),
        ])[0],
        complete.checkpoint,
      );
      continuations += 2;
    }
    cuts++;
  }
  context.diagnostic(
    JSON.stringify({
      cut_points: cuts,
      continuations,
      directions: [
        "native_to_native",
        "native_to_javascript",
        "javascript_to_native",
        "javascript_to_javascript",
      ],
    }),
  );
});

test("exclusive MAX boundary, one-microsecond buckets and giant gaps stay exact", () => {
  for (const [start, width, origin] of [
    [9007199254740993n, 1n, 9007199254740993n],
    [MAX - 3n, MAX, 0n],
    [MAX - 3n, 1n, 0n],
  ]) {
    const source = config();
    const measured = [-1, 1, 2, 4].map((y, i) =>
      frame(start + BigInt(i), [track(1, [0, y], start + BigInt(i))]),
    );
    const events = browser(source, measured).frames;
    const header = windowSource(source, width, [0n, 1n, 2n, 3n, MAX], origin);
    const actual = windows(header, events);
    assert.deepEqual(
      actual.frames,
      offline(events, header, source.sections, "transit-parity"),
    );
    assert.deepEqual(
      actual.frames,
      native("--transit-windows", [header, ...events]),
    );
    if (start === MAX - 3n)
      assert.equal(actual.frames.at(-1).current_window.end_exclusive_us, null);
    if (width === MAX) {
      assert.equal(
        actual.frames[0].current_window.end_exclusive_us,
        String(MAX),
      );
      assert.equal(actual.frames.at(-1).current_window.start_us, String(MAX));
    }
  }
  const source = config(),
    events = browser(source, [frame(0n), frame(MAX)]).frames;
  const actual = windows(windowSource(source, 1n), events);
  assert.equal(actual.frames[1].unobserved_windows, String(MAX - 1n));
  assert.equal(actual.frames[1].current_window.input_frames, "1");
  assert.ok(actual.frames[1].closed_window);
});

test("started upstream checkpoint seeds a baseline but neither a window nor prior outcomes", () => {
  const source = config();
  const measured = [-1, 1, 4, -1, 1, 4].map((y, i) =>
    frame(BigInt(i) * 100000n, [track(1, [0, y], BigInt(i) * 100000n)]),
  );
  const past = browser(source, measured.slice(0, 5));
  assert.ok(past.checkpoint.pending.length);
  assert.equal(past.checkpoint.counts[0].completed, "1");
  const header = windowSource({ resume: past.checkpoint }, 1n);
  const initial = windows(header);
  assert.equal(initial.checkpoint.current_window, null);
  assert.equal(initial.checkpoint.last_timestamp_us, "400000");
  assert.deepEqual(initial.checkpoint.counts, past.checkpoint.counts);
  const future = browser({ resume: past.checkpoint }, measured.slice(5));
  const actual = windows(header, future.frames);
  assert.equal(actual.frames[0].closed_window, null);
  assert.equal(actual.frames[0].unobserved_windows, "0");
  assert.equal(actual.frames[0].current_window.sections[0].completed, "1");
  assert.equal(actual.checkpoint.counts[0].completed, "2");
});

test("lifetime completed baselines above 2^53 remain exact while new window counts start at zero", () => {
  const source = config();
  const measured = [-1, 1, 4, -1, 4].map((y, i) =>
    frame(BigInt(i) * 100000n, [track(1, [0, y], BigInt(i) * 100000n)]),
  );
  const saved = browser(source, measured.slice(0, 3)).checkpoint;
  const baseline = 9007199254740993n;
  saved.counts[0].completed = String(baseline);
  for (const value of saved.counting.state.counts) {
    value.negative_to_positive = String(baseline + 2n);
    value.positive_to_negative = String(baseline + 2n);
  }
  const future = browser({ resume: saved }, measured.slice(3));
  const header = windowSource({ resume: saved }, MAX);
  const actual = windows(header, future.frames);
  assert.equal(
    actual.checkpoint.baseline_counts[0].completed,
    String(baseline),
  );
  assert.equal(actual.checkpoint.counts[0].completed, String(baseline + 1n));
  assert.equal(actual.checkpoint.current_window.sections[0].completed, "1");
  assert.deepEqual(
    actual.checkpoint,
    native("--transit-windows-checkpoint", [header, ...future.frames])[0],
  );
});

test("raw integers, malformed outcomes and incompatible checkpoints reject the complete batch", () => {
  const source = config(),
    header = windowSource(source);
  const events = browser(
    source,
    [-1, 1, 4].map((y, i) =>
      frame(BigInt(i) * 100000n, [track(1, [0, y], BigInt(i) * 100000n)]),
    ),
  ).frames;
  const saved = windows(header, events).checkpoint;
  for (const value of [
    { ...header, window_us: 1 },
    { ...header, window_us: "01" },
    { ...header, duration_limits_us: ["1", "1"] },
    { ...header, origin_us: "-1" },
    { ...header, extra: true },
  ])
    failure(invokeWindows(value, ""));
  failure(invokeWindows('{"window_us":"1",' + line(header).slice(1), ""));
  for (const mutate of [
    (v) => {
      v.passages = [];
    },
    (v) => {
      v.passages.push(clone(v.passages[0]));
    },
    (v) => {
      v.passages[0].elapsed_upper_us = "199999";
    },
    (v) => {
      v.counts[0].completed = "0";
    },
    (v) => {
      v.passages[0].exit.track_id = 2;
    },
    (v) => {
      v.counting.counting.session_id = "different";
    },
  ]) {
    const value = clone(events[2]);
    mutate(value);
    failure(invokeWindows(header, ndjson([...events.slice(0, 2), value])));
  }
  failure(
    invokeWindows(
      header,
      ndjson(events).replace('"track_id":1', '"track_id":1.0000000000000001'),
    ),
  );
  failure(
    invokeWindows(
      header,
      line(events[0]).replace('"pending_count":0', '"pending_count":1e-999'),
    ),
  );
  assert.deepEqual(
    windows(
      header,
      line(events[0]).replace('"pending_count":0', '"pending_count":0.0e3'),
    ),
    windows(header, events.slice(0, 1)),
  );
  for (const mutate of [
    (v) => {
      delete v.window_us;
    },
    (v) => {
      delete v.config.max_gap_us;
    },
    (v) => {
      v.current_window.start_us = "1";
    },
    (v) => {
      v.current_window.input_frames = "0";
    },
    (v) => {
      v.current_window.sections[0].duration_limits[0].indeterminate = "2";
    },
    (v) => {
      v.current_window.sections[0].duration_limits.at(-1).within = "0";
    },
    (v) => {
      v.current_window = null;
    },
    (v) => {
      v.baseline_counts[0].completed = "2";
    },
  ]) {
    const value = clone(saved);
    mutate(value);
    failure(invokeWindows({ resume: value }, ""));
    native("--transit-windows-checkpoint", [{ resume: value }], 2);
  }
  assert.deepEqual(
    windows(header, ndjson(events).replaceAll("\n", "\r\n")),
    windows(header, events),
  );
  assert.deepEqual(
    windows(header, events.map(line).join("\n")),
    windows(header, events),
  );
});

test("all sixteen sections and limits retain bounded live state instead of event history", () => {
  const source = config();
  source.sections = Array.from({ length: 16 }, (_, i) =>
    section(`window-section-${i}`, "entry", "exit", "negative_to_positive"),
  );
  const measured = [-1, 1, 4].map((y, i) =>
    frame(BigInt(i) * 100000n, [track(1, [0, y], BigInt(i) * 100000n)]),
  );
  const events = browser(source, measured).frames;
  const limits = [...Array.from({ length: 15 }, (_, i) => BigInt(i)), MAX];
  const header = windowSource(source, MAX, limits);
  const result = windows(header, events);
  assert.equal(result.checkpoint.current_window.sections.length, 16);
  for (const value of result.checkpoint.current_window.sections) {
    assert.equal(value.completed, "1");
    assert.equal(value.duration_limits.length, 16);
  }
  const loadedSource = clone(source);
  const evidenceConfig = JSON.parse(loadedSource.counting);
  const gateConfig = JSON.parse(evidenceConfig.counting);
  gateConfig.max_tracks = 400;
  evidenceConfig.counting = line(gateConfig);
  loadedSource.counting = line(evidenceConfig);
  const loadedMeasurements = [-1, 1, 4].map((y, index) =>
    frame(
      BigInt(index) * 100000n,
      Array.from({ length: 400 }, (_, i) =>
        track(i + 1, [0, y], BigInt(index) * 100000n, String(i + 1)),
      ),
    ),
  );
  const loaded = browser(loadedSource, loadedMeasurements).frames;
  assert.equal(loaded[2].passages.length, 6400);
  assert.ok(line(loaded[2]).length > 1048576);
  assert.ok(line(loaded[2]).length < 8388608);
  const measuredState = windows(
    windowSource(loadedSource, MAX, limits),
    loaded,
  );
  assert.equal(
    measuredState.checkpoint.current_window.sections[0].completed,
    "400",
  );
  assert.deepEqual(
    measuredState.frames,
    native(
      "--transit-windows",
      [windowSource(loadedSource, MAX, limits), ...loaded],
      0,
      ["--max-line-bytes", "16777216"],
    ),
  );
  assert.equal("pending" in result.checkpoint, false);
  assert.equal("frames" in result.checkpoint, false);
  assert.equal("history" in result.checkpoint, false);
  const future = browser(
    { resume: browser(source, measured).checkpoint },
    Array.from({ length: 100 }, (_, i) => frame(300000n + BigInt(i))),
  ).frames;
  const after = windows({ resume: result.checkpoint }, future).checkpoint;
  assert.equal(after.current_window.input_frames, "103");
  assert.equal(after.current_window.sections[0].completed, "1");
  assert.ok(line(after).length < line(result.checkpoint).length + 32);
});

test("pure limits include old large frames, total output and all legacy handles", () => {
  const source = config(),
    header = windowSource(source),
    initial = windows(header);
  const exact = line({ resume: initial.checkpoint }).padEnd(8388619, " ");
  assert.deepEqual(windows(exact).checkpoint, initial.checkpoint);
  failure(invokeWindows(exact + " ", ""));
  const empty = browser(source, [frame(0n)]).frames[0];
  const frameLimit = line(empty).padEnd(8388608, " ");
  assert.equal(windows(header, frameLimit).frames.length, 1);
  failure(invokeWindows(header, frameLimit + " "));
  const events = browser(
    source,
    Array.from({ length: 5000 }, (_, i) => frame(BigInt(i))),
  ).frames;
  // One section and one limit make the 5000-frame success return fit the total budget.
  const narrow = clone(source);
  narrow.sections = narrow.sections.slice(0, 1);
  const narrowHeader = windowSource(narrow, MAX, [MAX]);
  const narrowEvents = browser(
    narrow,
    Array.from({ length: 5000 }, (_, i) => frame(BigInt(i))),
  ).frames;
  assert.equal(windows(narrowHeader, narrowEvents).frames.length, 5000);
  const extra = browser(narrow, [frame(5000n)]).frames[0];
  failure(invokeWindows(narrowHeader, ndjson([...narrowEvents, extra])));
  assert.match(
    failure(invokeWindows(header, ndjson(events))),
    /output.*8388608/,
  );
  const request = JSON.stringify({ source: line(header), transits: "" }).padEnd(
    16777216,
    " ",
  );
  unpack(moonground_transit_windows(request));
  failure(moonground_transit_windows(request + " "));
  failure(
    moonground_transit_windows(
      JSON.stringify({ source: line(header), transits: "", extra: true }),
    ),
  );
  const handles = [];
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(
            JSON.stringify({ session_id: `window-full-${i}`, mode: "ground" }),
          ),
        ).handle,
      );
    failure(moonground_create('{"session_id":"full","mode":"ground"}'));
    assert.equal(windows(header).frames.length, 0);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
});
