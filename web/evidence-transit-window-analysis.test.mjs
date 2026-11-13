import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_evidence_transit_analysis,
  moonground_evidence_transit,
  moonground_transit_windows,
  moonground_evidence_transit_window_analysis,
  moonground_create,
  moonground_close,
} from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.env.MOONGROUND_CLI
  ? path.resolve(root, process.env.MOONGROUND_CLI)
  : ["main.exe", "main"]
      .map((v) => path.join(root, "_build/native/release/build/cmd/main", v))
      .find(existsSync);
assert.ok(
  binary,
  "Build the native CLI before evidence transit analysis verification.",
);
const clone = (v) => JSON.parse(JSON.stringify(v)),
  line = (v) => (typeof v === "string" ? v : JSON.stringify(v));
const ndjson = (records) =>
  records.map(line).join("\n") + (records.length ? "\n" : "");
const pair = (measurement, transit) => ({
  measurement: line(measurement),
  transit: line(transit),
});
const combine = (measurement, transit) => ({
  format: "moonground.evidence-transit-analysis",
  checkpoint_version: "1",
  measurement,
  transit,
});
const unpack = (text) => {
  const v = JSON.parse(text);
  assert.equal(v.error, undefined, text.slice(0, 1200));
  return v;
};
const failure = (text) => {
  const v = JSON.parse(text);
  assert.equal(typeof v.error, "string", text.slice(0, 1200));
  assert.deepEqual(
    Object.keys(v),
    ["error"],
    "failed pure bundle exposed partial data",
  );
  return v.error;
};
const invoke = (source, observations) =>
  moonground_evidence_transit_analysis(
    JSON.stringify({ source: line(source), observations }),
  );
const browser = (source, frames = []) =>
  unpack(invoke(source, typeof frames === "string" ? frames : ndjson(frames)));
function close(actual, expected, where = "$") {
  if (typeof expected === "number") {
    assert.equal(typeof actual, "number", where);
    assert.ok(Number.isFinite(actual), where);
    if (/\.(track_id|accepted_count|max_tracks|min_observations)$/.test(where))
      assert.equal(actual, expected, where);
    else
      assert.ok(
        Math.abs(actual - expected) <= 2e-10 * Math.max(1, Math.abs(expected)),
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
    for (const k of Object.keys(expected))
      close(actual[k], expected[k], `${where}.${k}`);
  } else assert.equal(actual, expected, where);
}
function native(mode, records, status = 0, extra = []) {
  const run = spawnSync(binary, [mode, ...extra], {
    input: ndjson(records),
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    timeout: 120000,
  });
  assert.equal(run.status, status, run.stderr || run.error?.message);
  if (!status) assert.equal(run.stderr, "");
  if (run.stdout) assert.ok(run.stdout.endsWith("\n"), "partial output line");
  if (status && mode.endsWith("checkpoint")) assert.equal(run.stdout, "");
  return run.stdout ? run.stdout.trimEnd().split("\n").map(JSON.parse) : [];
}

const observation = (track_id, point, covariance = [0.01, 0, 0.01]) => ({
  track_id,
  point,
  covariance,
});
const frame = (time, observations = [], lost = [], removed = []) => ({
  timestamp_us: String(time),
  observations,
  lost,
  removed,
});
const gate = (gate_id, y) => ({
  gate_id,
  start_m: [-100, y],
  end_m: [100, y],
  deadband_m: 0.005,
});
function policy(name, selected = [gate("entry", 0), gate("exit", 3)]) {
  return {
    counting: line({
      counting: line({
        session_id: name,
        gates: selected,
        max_gap_us: "500000",
        max_tracks: 1000,
      }),
      sigma_multiplier: 2,
    }),
    sections: [
      {
        section_id: "forward",
        entry_gate_id: selected[0].gate_id,
        entry_direction: "negative_to_positive",
        exit_gate_id: selected[1].gate_id,
        exit_direction: "negative_to_positive",
      },
      {
        section_id: "backward",
        entry_gate_id: selected[1].gate_id,
        entry_direction: "positive_to_negative",
        exit_gate_id: selected[0].gate_id,
        exit_direction: "positive_to_negative",
      },
    ],
    max_duration_us: "300000000",
  };
}
function fixture(start = 9007199254740993n) {
  const measurement = {
    session_id: "transit-analysis-browser",
    mode: "ground",
    diagnostics: true,
    motion: {
      max_tracks: 10,
      max_gap_us: "500000",
      min_observations: 2,
      min_span_us: "0",
      initial_velocity_std: 1000,
      gate: 1e12,
      q: 1e6,
    },
  };
  const transit = policy(measurement.session_id);
  const frames = [-1, 1, 2, 4, 1, -1].map((y, i) =>
    frame(start + BigInt(i) * 100000n, [observation(1, [0, y])]),
  );
  frames.push(frame(start + 600000n));
  frames.push(frame(start + 700000n, [], [1]));
  frames.push(frame(start + 800000n, [observation(1, [0, -1])], [], [2]));
  frames.push(frame(start + 1300000n, [observation(1, [0, -1])]));
  frames.push(frame(start + 1400000n, [observation(1, [0, 4])]));
  return { measurement, transit, frames, header: pair(measurement, transit) };
}
function separate(measurement, transit, frames) {
  const measured = native("--stream", [measurement, ...frames]);
  const counted = unpack(
    moonground_evidence_transit(
      JSON.stringify({ source: line(transit), measurements: ndjson(measured) }),
    ),
  );
  return {
    frames: measured.map((measurement, i) => ({
      schema_version: "0.1.0",
      kind: "evidence_transit_analysis_frame",
      measurement,
      transit: counted.frames[i],
    })),
    checkpoint: combine(
      native("--checkpoint", [measurement, ...frames])[0],
      counted.checkpoint,
    ),
  };
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

const strategy = (width = 250000n, origin = 0n) => ({
  window_us: String(width),
  duration_limits_us: [0n, 1n, 100000n, 200000n, 300000n, MAX].map(String),
  origin_us: String(origin),
});
const joined = (analysis, config = strategy()) => ({
  analysis: line(analysis),
  windows: line(config),
});
const jointCP = (analysis, windows) => ({
  format: "moonground.evidence-transit-window-analysis",
  checkpoint_version: "1",
  analysis,
  windows,
});
const invokeJoint = (source, observations) =>
  moonground_evidence_transit_window_analysis(
    JSON.stringify({ source: line(source), observations }),
  );
const joint = (source, observations = []) =>
  unpack(
    invokeJoint(
      source,
      typeof observations === "string" ? observations : ndjson(observations),
    ),
  );
function host(analysis, config, observations) {
  const initial = browser(analysis).checkpoint,
    upstream = browser(analysis, observations);
  const windowHeader =
    "resume" in config
      ? config
      : { ...config, transit: line({ resume: initial.transit }) };
  const grouped = windows(
    windowHeader,
    upstream.frames.map((value) => value.transit),
  );
  if (!("resume" in config))
    assert.deepEqual(
      grouped.frames,
      offline(
        upstream.frames.map((value) => value.transit),
        config,
        initial.transit.sections,
        initial.transit.counting.configuration.counting.session_id,
      ),
    );
  return {
    frames: upstream.frames.map((analysis, index) => ({
      schema_version: "0.1.0",
      kind: "evidence_transit_window_analysis_frame",
      analysis,
      windows: grouped.frames[index],
    })),
    checkpoint: jointCP(upstream.checkpoint, grouped.checkpoint),
  };
}
function samples() {
  const values = [fixture()];
  for (const name of ["warehouse", "distorted-camera", "reframe"]) {
    const raw = readFileSync(path.join(root, `examples/${name}.ndjson`), "utf8")
      .trimEnd()
      .split("\n")
      .map(JSON.parse);
    const measurement = raw[0];
    measurement.diagnostics = true;
    const transit = policy(measurement.session_id, [
      gate("entry", 3.8),
      gate("exit", 4.3),
    ]);
    values.push({
      measurement,
      transit,
      frames: raw.slice(1),
      header: pair(measurement, transit),
    });
  }
  return values;
}

test("raw joint results equal independent v16 then v18 and offline integer grouping", () => {
  for (const sample of samples()) {
    const config = strategy(),
      expected = host(sample.header, config, sample.frames),
      actual = joint(joined(sample.header, config), sample.frames);
    assert.deepEqual(actual, expected);
    const nativeFrames = native("--analyze-transit-windows", [
      joined(sample.header, config),
      ...sample.frames,
    ]);
    close(nativeFrames, actual.frames);
    assert.deepEqual(
      nativeFrames.map((value) => value.windows),
      actual.frames.map((value) => value.windows),
    );
    close(
      native("--analyze-transit-windows-checkpoint", [
        joined(sample.header, config),
        ...sample.frames,
      ])[0],
      actual.checkpoint,
    );
  }
});

test("every cut resumes the entire raw owner across four runtime directions", (context) => {
  let cuts = 0,
    continuations = 0;
  for (const sample of [samples()[0], samples()[2]]) {
    const header = joined(sample.header),
      complete = joint(header, sample.frames);
    for (let cut = 0; cut <= sample.frames.length; cut++) {
      const nativeSaved = native("--analyze-transit-windows-checkpoint", [
        header,
        ...sample.frames.slice(0, cut),
      ])[0];
      const webSaved = joint(header, sample.frames.slice(0, cut)).checkpoint;
      close(nativeSaved, webSaved);
      for (const saved of [nativeSaved, webSaved]) {
        close(joint({ resume: saved }, sample.frames.slice(cut)), {
          frames: complete.frames.slice(cut),
          checkpoint: complete.checkpoint,
        });
        close(
          joint(
            joined({ resume: saved.analysis }, { resume: saved.windows }),
            sample.frames.slice(cut),
          ),
          {
            frames: complete.frames.slice(cut),
            checkpoint: complete.checkpoint,
          },
        );
        close(
          native("--analyze-transit-windows", [
            { resume: saved },
            ...sample.frames.slice(cut),
          ]),
          complete.frames.slice(cut),
        );
        close(
          native("--analyze-transit-windows-checkpoint", [
            { resume: saved },
            ...sample.frames.slice(cut),
          ])[0],
          complete.checkpoint,
        );
        continuations += 2;
      }
      cuts++;
    }
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

test("late origin rejection discards the candidate and upper-stage overflow permits same-time correction", () => {
  const sample = fixture(0n),
    header = joined(sample.header, strategy(250000n, 100n));
  const initial = joint(header).checkpoint;
  const early = frame(99n, [observation(9, [0, -1])]);
  assert.equal(
    browser(sample.header, [early]).checkpoint.measurement.motion.tracks[0]
      .segment_id,
    "1",
  );
  failure(invokeJoint(header, ndjson([early])));
  const corrected = joint({ resume: initial }, [
    frame(100n, [observation(9, [0, -1])]),
  ]);
  assert.equal(
    corrected.checkpoint.analysis.measurement.motion.tracks[0].segment_id,
    "1",
  );
  assert.equal(corrected.checkpoint.windows.current_window.input_frames, "1");
  const saved = joint(
    joined(sample.header),
    sample.frames.slice(0, 1),
  ).checkpoint;
  for (const value of saved.analysis.transit.counting.state.counts) {
    value.negative_to_positive = String(MAX);
    value.positive_to_negative = String(MAX);
  }
  failure(invokeJoint({ resume: saved }, ndjson([sample.frames[1]])));
  const fixed = frame(100000n, [
    observation(1, [0, -2]),
    observation(9, [0, -1]),
  ]);
  const after = joint({ resume: saved }, [fixed]);
  assert.equal(
    after.checkpoint.analysis.measurement.motion.tracks[1].segment_id,
    "2",
  );
  assert.equal(after.checkpoint.windows.current_window.input_frames, "2");
  const near = frame(100000n, [
    observation(1, [0, -1], [1, 0.9999999999999999, 1]),
  ]);
  failure(invokeJoint(joined(sample.header), ndjson([near])));
});

test("joint restore rejects independently valid sparse sample, count and entry-budget contradictions", () => {
  const sample = fixture(0n),
    header = joined(sample.header, strategy(MAX));
  const stationary = [
    frame(0n, [observation(1, [0, -1]), observation(2, [0, -1])]),
    frame(100000n, [observation(2, [0, -1])]),
    frame(200000n, [observation(1, [0, -1])]),
  ];
  const saved = joint(header, stationary).checkpoint;
  const incompatible = (value) => {
    browser({ resume: value.analysis });
    windows({ resume: value.windows });
    failure(invokeJoint({ resume: value }, ""));
    native("--analyze-transit-windows-checkpoint", [{ resume: value }], 2);
  };
  let invalid = clone(saved);
  invalid.windows.current_window.first_timestamp_us = "200000";
  invalid.windows.current_window.input_frames = "1";
  incompatible(invalid);
  invalid = clone(saved);
  invalid.windows.current_window.input_frames = "2";
  incompatible(invalid);
  invalid = clone(saved);
  invalid.windows.origin_us = "1";
  Object.assign(invalid.windows.current_window, {
    start_us: "1",
    end_exclusive_us: null,
    first_timestamp_us: "100000",
    input_frames: "2",
  });
  incompatible(invalid);
  const dense = Array.from({ length: 11 }, (_, i) =>
    frame(BigInt(i), [observation(1, [0, -1])]),
  );
  invalid = joint(joined(sample.header, strategy(6n)), dense).checkpoint;
  invalid.windows.current_window.input_frames = "4";
  incompatible(invalid);
  const pending = joint(header, sample.frames.slice(0, 3)).checkpoint;
  assert.ok(pending.analysis.transit.pending.length);
  invalid = clone(pending);
  invalid.windows.current_window.sections[0].cancellations[0].count = "1";
  incompatible(invalid);
  const finished = joint(header, sample.frames.slice(0, 4)).checkpoint;
  invalid = clone(finished);
  for (const value of invalid.windows.current_window.sections) {
    value.completed = "0";
    for (const row of value.duration_limits)
      Object.assign(row, { within: "0", exceeded: "0", indeterminate: "0" });
  }
  incompatible(invalid);
  for (const mutate of [
    (v) => {
      v.windows.sigma_multiplier = 3;
    },
    (v) => {
      v.windows.config.max_tracks = 1001;
    },
    (v) => {
      delete v.windows.window_us;
    },
    (v) => {
      delete v.windows.gates[0].deadband_m;
    },
  ]) {
    invalid = clone(saved);
    mutate(invalid);
    failure(invokeJoint({ resume: invalid }, ""));
  }
});

test("started pending entries precede the statistics baseline and future clocks remain exact", () => {
  for (const start of [9007199254740993n, MAX - 3n]) {
    const sample = fixture(start);
    sample.measurement.motion.initial_velocity_std = 1e7;
    const raw = [-1, 1, 2, 4].map((y, i) =>
      frame(start + BigInt(i), [observation(1, [0, y])]),
    );
    const analysis = browser(
      pair(sample.measurement, sample.transit),
      raw.slice(0, 3),
    ).checkpoint;
    assert.ok(analysis.transit.pending.length);
    const header = joined({ resume: analysis }, strategy(MAX));
    assert.equal(joint(header).checkpoint.windows.current_window, null);
    const actual = joint(header, raw.slice(3));
    assert.equal(
      actual.frames[0].windows.current_window.sections[0].completed,
      "1",
    );
    assert.equal(actual.frames[0].windows.closed_window, null);
    assert.equal(actual.frames[0].windows.unobserved_windows, "0");
    assert.equal(
      actual.checkpoint.windows.baseline_timestamp_us,
      String(start + 2n),
    );
    if (start === MAX - 3n)
      assert.equal(
        actual.frames[0].windows.current_window.end_exclusive_us,
        null,
      );
    close(actual, host({ resume: analysis }, strategy(MAX), raw.slice(3)));
  }
});

test("warm Brown reframing preserves every window field and future integer classifications", () => {
  const sample = samples()[2],
    header = joined(sample.header),
    cut = 4;
  const baseline = joint(header, sample.frames),
    saved = joint(header, sample.frames.slice(0, cut)).checkpoint;
  const transform = { scale_x: 0.6, scale_y: 1.3, offset_x: -40, offset_y: 16 };
  const converted = native("--reframe", [
    { source: { resume: saved.analysis.measurement }, transform },
    ...sample.frames.slice(cut),
  ]);
  const changed = clone(saved);
  changed.analysis.measurement = converted[0].resume;
  assert.deepEqual(changed.windows, saved.windows);
  assert.deepEqual(changed.analysis.transit, saved.analysis.transit);
  const actual = joint({ resume: changed }, converted.slice(1));
  close(
    actual,
    host(
      { resume: changed.analysis },
      { resume: changed.windows },
      converted.slice(1),
    ),
  );
  close(actual.frames, baseline.frames.slice(cut));
  assert.deepEqual(
    actual.frames.map((value) => value.windows),
    baseline.frames.slice(cut).map((value) => value.windows),
  );
});

test("raw source budgets and pure total-output budgets remain separate from observed samples", (context) => {
  const sample = fixture(0n),
    header = joined(sample.header),
    initial = joint(header);
  const exact = line({ resume: initial.checkpoint }).padEnd(8388619, " ");
  assert.deepEqual(joint(exact).checkpoint, initial.checkpoint);
  failure(invokeJoint(exact + " ", ""));
  const rawConfig = line(strategy()).padEnd(1048576, " ");
  assert.equal(joint(joined(sample.header, rawConfig)).frames.length, 0);
  failure(invokeJoint(joined(sample.header, rawConfig + " "), ""));
  const exactLine = line(frame(0n)).padEnd(1048576, " ");
  assert.equal(joint(header, exactLine).frames.length, 1);
  failure(invokeJoint(header, exactLine + " "));
  const exactBatch = Array.from(
    { length: 8 },
    (_, i) => line(frame(BigInt(i))).padEnd(1048575, " ") + "\n",
  ).join("");
  assert.equal(exactBatch.length, 8388608);
  assert.equal(joint(header, exactBatch).frames.length, 8);
  failure(invokeJoint(header, exactBatch + " "));
  const config = strategy(MAX);
  config.duration_limits_us = [String(MAX)];
  const single = clone(sample.transit);
  single.sections = single.sections.slice(0, 1);
  const narrow = joined(pair(sample.measurement, single), config),
    empty = Array.from({ length: 5000 }, (_, i) => frame(BigInt(i)));
  const measured = invokeJoint(narrow, ndjson(empty.slice(0, 4000)));
  assert.equal(unpack(measured).frames.length, 4000);
  const outputLimit = failure(invokeJoint(narrow, ndjson(empty)));
  assert.match(outputLimit, /output.*8388608/);
  const frameLimit = failure(
    invokeJoint(narrow, ndjson([...empty, frame(5000n)])),
  );
  assert.match(frameLimit, /batch exceeds 5000 frames/);
  context.diagnostic(
    JSON.stringify({
      successful_empty_frames: 4000,
      complete_return_utf16_units: measured.length,
      five_thousand_input_rejection: "output_budget",
      five_thousand_one_rejection: "frame_count_budget",
    }),
  );
  const request = JSON.stringify({
    source: line(header),
    observations: "",
  }).padEnd(16777216, " ");
  unpack(moonground_evidence_transit_window_analysis(request));
  failure(moonground_evidence_transit_window_analysis(request + " "));
  failure(
    moonground_evidence_transit_window_analysis(
      JSON.stringify({ source: line(header), observations: "", extra: true }),
    ),
  );
  failure(invokeJoint('{"analysis":"bad",' + line(header).slice(1), ""));
  failure(
    invokeJoint(
      header,
      ndjson(sample.frames).replace(
        '"track_id":1',
        '"track_id":1.0000000000000001',
      ),
    ),
  );
  const handles = [];
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(
            JSON.stringify({ session_id: `joint-window-${i}`, mode: "ground" }),
          ),
        ).handle,
      );
    failure(moonground_create('{"session_id":"full","mode":"ground"}'));
    assert.equal(joint(header).frames.length, 0);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
});

test("all sixteen sections and thresholds operate together on raw trajectories", () => {
  const sample = fixture(0n);
  sample.transit.sections = Array.from({ length: 16 }, (_, i) => ({
    ...sample.transit.sections[0],
    section_id: `section-${i}`,
  }));
  const config = strategy(MAX);
  config.duration_limits_us = [
    ...Array.from({ length: 15 }, (_, i) => String(i)),
    String(MAX),
  ];
  const raw = [-1, 1, 2, 4].map((y, i) =>
    frame(
      BigInt(i) * 100000n,
      Array.from({ length: 10 }, (_, j) => observation(j + 1, [0, y])),
    ),
  );
  const actual = joint(
    joined(pair(sample.measurement, sample.transit), config),
    raw,
  );
  assert.equal(actual.checkpoint.windows.current_window.sections.length, 16);
  for (const section of actual.checkpoint.windows.current_window.sections) {
    assert.equal(section.completed, "10");
    assert.equal(section.duration_limits.length, 16);
  }
  assert.equal(actual.frames.at(-1).analysis.transit.passages.length, 160);
});
