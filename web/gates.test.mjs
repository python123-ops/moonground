import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_gates,
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
assert.ok(binary, "Build the native release CLI before gate verification.");

const clone = (value) => JSON.parse(JSON.stringify(value));
const line = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
const ndjson = (records) => records.map(line).join("\n") + "\n";
const unpack = (source) => {
  const value = JSON.parse(source);
  assert.equal(value.error, undefined, source.slice(0, 1000));
  return value;
};
const failure = (source) => {
  const value = JSON.parse(source);
  assert.equal(typeof value.error, "string", source.slice(0, 500));
  assert.deepEqual(
    Object.keys(value),
    ["error"],
    "failed bundle exposed partial data",
  );
  return value.error;
};

function closeNumeric(actual, expected, location = "$") {
  if (typeof expected === "number") {
    assert.equal(typeof actual, "number", location);
    assert.ok(Number.isFinite(actual), location);
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

function native(mode, records, status = 0, payload = null, extra = []) {
  const run = spawnSync(binary, [mode, ...extra], {
    input: payload ?? ndjson(records),
    encoding: "utf8",
    maxBuffer: 48 * 1024 * 1024,
    timeout: 120000,
  });
  assert.equal(run.status, status, run.stderr || run.error?.message);
  if (!status) assert.equal(run.stderr, "");
  if (run.stdout)
    assert.ok(run.stdout.endsWith("\n"), "partial native output line");
  return run.stdout ? run.stdout.trimEnd().split("\n").map(JSON.parse) : [];
}

function browser(source, measurements) {
  return unpack(
    moonground_gates(JSON.stringify({ source: line(source), measurements })),
  );
}

function gate(gateId = "entrance", start = [-1, 0], end = [1, 0]) {
  return { gate_id: gateId, start_m: start, end_m: end, deadband_m: 0.05 };
}

function config(sessionId = "gate-parity", gates = [gate()]) {
  return {
    session_id: sessionId,
    gates,
    max_gap_us: "500000",
    max_tracks: 100,
  };
}

function track(trackId, point, timestamp, segment = "1") {
  return {
    track_id: trackId,
    segment_id: segment,
    status: "ready",
    position_m: point,
    position_covariance: [0.01, 0, 0.01],
    velocity_mps: [0, 0],
    velocity_covariance: [0.04, 0, 0.04],
    position_std_m: 0.1,
    velocity_std_mps: 0.2,
    speed_mps: 0,
    observed_path_length_m: 0,
    net_displacement_m: 0,
    accepted_count: 3,
    last_accepted_timestamp_us: String(timestamp),
  };
}

function frame(timestamp, tracks = [], sessionId = "gate-parity", closed = []) {
  return {
    schema_version: "0.2.0",
    session_id: sessionId,
    timestamp_us: String(timestamp),
    tracks,
    closed_segment_ids: closed,
    uncertainty_scope: "conditional_on_fixed_calibration_camera_and_anchor",
  };
}

function synthetic() {
  const coordinates = [
    [0, -1],
    [0, 0],
    [0, 1],
    [2, -1],
    [2, 1],
    [1, 1],
    [1, -1],
  ];
  return coordinates.map((point, index) => {
    const time = 9007199254740993n + BigInt(index) * 100000n;
    return frame(time, [
      track(3, point, time, "3"),
      track(1, [point[1], point[0]], time),
    ]);
  });
}

test("native and JavaScript count complete calibrated measurement frames identically", (context) => {
  let totalFrames = 0;
  for (const name of ["warehouse", "distorted-camera", "reframe"]) {
    const replay = readFileSync(
      path.join(root, `examples/${name}.ndjson`),
      "utf8",
    )
      .trimEnd()
      .split("\n")
      .map(JSON.parse);
    replay[0].diagnostics = true;
    const measurements = native("--stream", replay);
    const source = config(replay[0].session_id, [
      gate("vertical", [1, -100], [1, 100]),
      gate("horizontal", [-100, 2], [100, 2]),
    ]);
    const actual = browser(source, ndjson(measurements));
    closeNumeric(actual.frames, native("--count", [source, ...measurements]));
    closeNumeric(
      actual.checkpoint,
      native("--count-checkpoint", [source, ...measurements])[0],
    );
    totalFrames += measurements.length;
  }
  const source = config("gate-parity", [
    gate(),
    gate("vertical", [0, -1], [0, 1]),
  ]);
  const measurements = synthetic();
  const expected = native("--count", [source, ...measurements]);
  const actual = browser(source, ndjson(measurements));
  closeNumeric(actual.frames, expected);
  assert.ok(actual.frames.some((value) => value.crossings.length));
  assert.equal(actual.frames[0].timestamp_us, "9007199254740993");
  assert.deepEqual(actual.frames.at(-1).counts, expected.at(-1).counts);
  context.diagnostic(
    `${totalFrames + measurements.length} actual/synthetic frames across native and JavaScript`,
  );
});

test("all cut points resume across both runtimes with exact large counters and timestamps", (context) => {
  const source = config("gate-parity", [
    gate(),
    gate("vertical", [0, -1], [0, 1]),
  ]);
  const measurements = synthetic();
  const expected = native("--count", [source, ...measurements]);
  const final = native("--count-checkpoint", [source, ...measurements])[0];
  let resumedDirections = 0;
  for (let cut = 0; cut <= measurements.length; cut++) {
    const prefix = measurements.slice(0, cut);
    const checkpoints = [
      native("--count-checkpoint", [source, ...prefix])[0],
      browser(source, prefix.length ? ndjson(prefix) : "").checkpoint,
    ];
    closeNumeric(checkpoints[0], checkpoints[1]);
    for (const checkpoint of checkpoints) {
      const resumed = { resume: checkpoint };
      const future = measurements.slice(cut);
      closeNumeric(
        native("--count", [resumed, ...future]),
        expected.slice(cut),
      );
      const bundle = browser(resumed, future.length ? ndjson(future) : "");
      closeNumeric(bundle.frames, expected.slice(cut));
      closeNumeric(bundle.checkpoint, final);
      closeNumeric(
        native("--count-checkpoint", [resumed, ...future])[0],
        final,
      );
      resumedDirections += 2;
    }
  }
  const saved = browser(source, ndjson(measurements.slice(0, 1))).checkpoint;
  saved.state.counts[0].negative_to_positive = "9007199254740993";
  const future = measurements.slice(1, 3);
  const counted = browser({ resume: saved }, ndjson(future));
  assert.equal(
    counted.frames.at(-1).counts[0].negative_to_positive,
    "9007199254740994",
  );
  closeNumeric(
    counted.frames,
    native("--count", [{ resume: saved }, ...future]),
  );
  context.diagnostic(
    `${resumedDirections} resumed native/JavaScript directions over ${measurements.length + 1} cuts`,
  );
});

test("pure gate calls do not consume any of the 64 measurement session handles", () => {
  const handles = [];
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(
            JSON.stringify({
              session_id: `held-${i}`,
              mode: "ground",
            }),
          ),
        ).handle,
      );
    assert.match(
      failure(moonground_create('{"session_id":"full","mode":"ground"}')),
      /capacity/,
    );
    for (let i = 0; i < 4; i++) {
      const actual = browser(config(), ndjson(synthetic()));
      assert.equal(actual.frames.length, synthetic().length);
    }
    assert.match(
      failure(moonground_create('{"session_id":"still-full","mode":"ground"}')),
      /capacity/,
    );
    assert.equal(moonground_close(handles.pop()), true);
    handles.push(
      unpack(moonground_create('{"session_id":"released","mode":"ground"}'))
        .handle,
    );
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
});

test("raw source and measurement tokens remain exact and failed bundles expose no partial frames", () => {
  const source = config();
  const measurements = synthetic();
  const invoke = (sourceText, text) =>
    moonground_gates(
      JSON.stringify({ source: sourceText, measurements: text }),
    );
  failure(
    invoke(
      JSON.stringify(source).replace(
        '"max_tracks":100',
        '"max_tracks":100.0000000000000001',
      ),
      "",
    ),
  );
  failure(
    invoke(
      line(source),
      ndjson(measurements).replace(
        '"track_id":3',
        '"track_id":3.0000000000000001',
      ),
    ),
  );
  failure(invoke('{"session_id":"duplicate",' + line(source).slice(1), ""));
  failure(
    invoke(
      line(source),
      ndjson([
        measurements[0],
        '{"timestamp_us":"1",' + line(measurements[1]).slice(1),
      ]),
    ),
  );
  failure(
    invoke(
      line(source),
      ndjson([...measurements, { ...measurements.at(-1), extra: 1 }]),
    ),
  );
  failure(invoke(line(source), ndjson([measurements[0], ""])));
  failure(moonground_gates(JSON.stringify({ source, measurements: "" })));
  failure(
    moonground_gates(
      JSON.stringify({ source: line(source), measurements: "", extra: 1 }),
    ),
  );
  const checkpoint = browser(
    source,
    ndjson(measurements.slice(0, 1)),
  ).checkpoint;
  const invalid = clone(checkpoint);
  invalid.state.tracks.find((item) => item.track_id === 3).anchors[0].point_m =
    [0, 0];
  failure(invoke(line({ resume: invalid }), ""));
  failure(invoke(line({ resume: checkpoint, max_tracks: 1 }), ""));
  const expected = browser(source, ndjson(measurements));
  closeNumeric(browser(source, measurements.map(line).join("\r\n")), expected);
  closeNumeric(browser(source, measurements.map(line).join("\n")), expected);
  assert.deepEqual(browser(source, "").frames, []);
  // The same complete request still succeeds after all failed pure invocations.
  closeNumeric(browser(source, ndjson(measurements)), expected);
});

test("UTF-16 source, line, frame-count, input and wrapper limits include their exact boundary", () => {
  const source = config();
  const invoke = (sourceText, text) =>
    moonground_gates(
      JSON.stringify({ source: sourceText, measurements: text }),
    );
  const paddedSource = line(source).padEnd(1048576, " ");
  unpack(invoke(paddedSource, ""));
  failure(invoke(paddedSource + " ", ""));
  const saved = browser(source, "").checkpoint;
  const exactResumeSource = line({ resume: saved }).padEnd(8388619, " ");
  closeNumeric(unpack(invoke(exactResumeSource, "")).checkpoint, saved);
  failure(invoke(exactResumeSource + " ", ""));
  const one = line(frame(0));
  const exactLine = one.padEnd(1048576, " ");
  assert.equal(unpack(invoke(line(source), exactLine)).frames.length, 1);
  failure(invoke(line(source), exactLine + " "));
  const exactInput = Array.from(
    { length: 8 },
    (_, index) => line(frame(index)).padEnd(1048575, " ") + "\n",
  ).join("");
  assert.equal(exactInput.length, 8388608);
  assert.equal(unpack(invoke(line(source), exactInput)).frames.length, 8);
  failure(invoke(line(source), exactInput + " "));
  const maximumFrames = Array.from({ length: 5000 }, (_, index) =>
    frame(index),
  );
  assert.equal(browser(source, ndjson(maximumFrames)).frames.length, 5000);
  failure(invoke(line(source), ndjson([...maximumFrames, frame(5000)])));
  const wrapper = JSON.stringify({
    source: line(source),
    measurements: "",
  }).padEnd(16777216, " ");
  unpack(moonground_gates(wrapper));
  failure(moonground_gates(wrapper + " "));
  assert.equal(
    browser(config("gate-parity", [gate("😀".repeat(64))]), "").checkpoint
      .configuration.gates[0].gate_id.length,
    128,
  );
  failure(invoke(line(config("gate-parity", [gate("😀".repeat(65))])), ""));
});

test("large native event frames remain complete while the pure bundle enforces total output size", (context) => {
  const source = {
    ...config(
      "gate-parity",
      Array.from({ length: 16 }, (_, i) => gate(`gate-${i}`)),
    ),
    max_tracks: 1600,
  };
  const measurements = [0, 100000, 200000].map((time, index) =>
    frame(
      time,
      Array.from({ length: 1600 }, (_, i) =>
        track(i + 1, [0, index % 2 ? 1 : -1], time, String(i + 1)),
      ),
    ),
  );
  for (const value of measurements) assert.ok(line(value).length < 1048576);
  const actual = native("--count", [source, ...measurements]);
  assert.equal(actual.length, 3);
  assert.equal(actual[1].crossings.length, 25600);
  assert.ok(line(actual[1]).length > 1048576);
  const error = failure(
    moonground_gates(
      JSON.stringify({
        source: line(source),
        measurements: ndjson(measurements),
      }),
    ),
  );
  assert.match(error, /output.*8388608/);
  assert.equal(
    browser(config(), ndjson(synthetic())).frames.length,
    synthetic().length,
  );
  context.diagnostic(
    `${actual[1].crossings.length} crossings; native line ${line(actual[1]).length} UTF-16 units`,
  );
});

test("rotated endpoints are closed and unrepresentable crossing fractions fail atomically", () => {
  const source = config("gate-parity", [
    { ...gate("rotated", [0, 0], [1, 6]), deadband_m: 0 },
  ]);
  const measurements = [
    [-5, 7],
    [7, 5],
  ].map((point, i) => frame(i * 100000, [track(1, point, i * 100000)]));
  const actual = browser(source, ndjson(measurements));
  assert.equal(actual.frames[1].crossings.length, 1);
  assert.deepEqual(actual.frames[1].crossings[0].position_m, [1, 6]);
  closeNumeric(actual.frames, native("--count", [source, ...measurements]));
  const vertical = config("gate-parity", [
    { ...gate("vertical", [0, -1], [0, 1]), deadband_m: 0 },
  ]);
  const wide = [1e308, -1e308].map((x, i) =>
    frame(i * 100000, [track(1, [x, 0], i * 100000)]),
  );
  const balanced = browser(vertical, ndjson(wide));
  assert.equal(balanced.frames[1].crossings[0].crossing_fraction, 0.5);
  assert.deepEqual(balanced.frames[1].crossings[0].position_m, [0, 0]);
  closeNumeric(balanced.frames, native("--count", [vertical, ...wide]));
  const impossible = clone(wide);
  impossible[1].tracks[0].position_m = [-1, 0];
  failure(
    moonground_gates(
      JSON.stringify({
        source: line(vertical),
        measurements: ndjson(impossible),
      }),
    ),
  );
  closeNumeric(browser(vertical, ndjson(wide)), balanced);
});
