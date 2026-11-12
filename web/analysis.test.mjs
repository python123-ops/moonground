import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_analysis,
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
assert.ok(binary, "Build the native release CLI before analysis verification.");
const clone = (value) => JSON.parse(JSON.stringify(value));
const line = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
const ndjson = (records) =>
  records.map(line).join("\n") + (records.length ? "\n" : "");
const source = (measurement, counting) => ({
  measurement: line(measurement),
  counting: line(counting),
});

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
    "failed batch exposed partial frames/checkpoint",
  );
  return value.error;
}

function closeNumeric(actual, expected, location = "$") {
  if (typeof expected === "number") {
    assert.equal(typeof actual, "number", location);
    assert.ok(Number.isFinite(actual), location);
    if (
      /\.(track_id|accepted_count|max_tracks|min_observations)$/.test(location)
    )
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

function native(mode, records, status = 0, extra = []) {
  const run = spawnSync(binary, [mode, ...extra], {
    input: ndjson(records),
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    timeout: 120000,
  });
  assert.equal(run.status, status, run.stderr || run.error?.message);
  if (!status) assert.equal(run.stderr, "");
  if (run.stdout)
    assert.ok(run.stdout.endsWith("\n"), "partial native output line");
  if (status && mode === "--analyze-checkpoint") assert.equal(run.stdout, "");
  return run.stdout ? run.stdout.trimEnd().split("\n").map(JSON.parse) : [];
}

function invoke(head, observations) {
  return moonground_analysis(
    JSON.stringify({ source: line(head), observations }),
  );
}

const browser = (head, frames) =>
  unpack(invoke(head, typeof frames === "string" ? frames : ndjson(frames)));
const observation = (track_id, point) => ({
  track_id,
  point,
  covariance: [0.01, 0.002, 0.02],
});
const frame = (time, observations = [], lost = [], removed = []) => ({
  timestamp_us: String(time),
  observations,
  lost,
  removed,
});
const gate = (gate_id = "entrance", start_m = [-10, 0], end_m = [10, 0]) => ({
  gate_id,
  start_m,
  end_m,
  deadband_m: 0.005,
});
const counting = (session_id, gates = [gate()]) => ({
  session_id,
  gates,
  max_gap_us: "500000",
  max_tracks: 100,
});

function groundFixture() {
  const measurement = {
    session_id: "analysis-parity",
    mode: "ground",
    diagnostics: true,
    motion: {
      max_gap_us: "500000",
      min_observations: 2,
      min_span_us: "100000",
      gate: 1e9,
      q: 5,
      initial_velocity_std: 5,
      max_tracks: 100,
    },
  };
  const start = 9007199254740993n;
  const points = [-1, -0.5, 0, 0.5, 1, 0, -1];
  const frames = points.map((y, index) =>
    frame(start + BigInt(index) * 100000n, [
      observation(3, [0, y]),
      observation(1, [y, 0.5]),
    ]),
  );
  frames.push(frame(start + 700000n, [], [3]));
  frames.push(frame(start + 800000n, [observation(1, [0.5, 0.5])], [], [3]));
  frames.push(frame(start + 1300000n, [observation(3, [0, -1])]));
  frames.push(frame(start + 1400000n, [observation(3, [0, 1])]));
  return {
    measurement,
    counting: counting(measurement.session_id, [
      gate(),
      gate("vertical", [0, -10], [0, 10]),
    ]),
    frames,
  };
}

function fixtures() {
  const values = [groundFixture()];
  for (const name of ["warehouse", "distorted-camera", "reframe"]) {
    const replay = readFileSync(
      path.join(root, `examples/${name}.ndjson`),
      "utf8",
    )
      .trimEnd()
      .split("\n")
      .map(JSON.parse);
    replay[0].diagnostics = true;
    values.push({
      measurement: replay[0],
      frames: replay.slice(1),
      counting: counting(replay[0].session_id, [
        gate("vertical", [1.2, -100], [1.2, 100]),
        gate("horizontal", [-100, 3.8], [100, 3.8]),
      ]),
    });
  }
  return values;
}

function separatePaths(measurement, count, frames) {
  const measured = native("--stream", [measurement, ...frames]);
  const counted = native("--count", [count, ...measured]);
  return {
    frames: measured.map((measurement, index) => ({
      schema_version: "0.1.0",
      kind: "analysis_frame",
      measurement,
      counting: counted[index],
    })),
    checkpoint: {
      format: "moonground.analysis",
      checkpoint_version: "1",
      measurement: native("--checkpoint", [measurement, ...frames])[0],
      counting: native("--count-checkpoint", [count, ...measured])[0],
    },
  };
}

test("analysis matches separate measurement and gate pipelines, including diagnostics and Brown camera", (context) => {
  let frames = 0,
    crossings = 0;
  for (const fixture of fixtures()) {
    const head = source(fixture.measurement, fixture.counting);
    const actual = browser(head, fixture.frames);
    closeNumeric(
      actual,
      separatePaths(fixture.measurement, fixture.counting, fixture.frames),
    );
    closeNumeric(actual.frames, native("--analyze", [head, ...fixture.frames]));
    closeNumeric(
      actual.checkpoint,
      native("--analyze-checkpoint", [head, ...fixture.frames])[0],
    );
    frames += actual.frames.length;
    crossings += actual.frames.reduce(
      (total, value) => total + value.counting.crossings.length,
      0,
    );
    assert.equal(
      actual.checkpoint.measurement.motion.last_timestamp_us,
      actual.checkpoint.counting.state.last_timestamp_us,
    );
  }
  assert.ok(crossings > 0);
  context.diagnostic(
    `${frames} frames and ${crossings} crossings through independent native paths and JavaScript`,
  );
});

test("every cut point preserves full motion/covariance and gate anchors across four runtime directions", (context) => {
  let cutPoints = 0,
    continuations = 0;
  for (const fixture of fixtures()) {
    const { measurement, counting: count, frames } = fixture;
    const head = source(measurement, count);
    const complete = browser(head, frames);
    for (let cut = 0; cut <= frames.length; cut++) {
      const nativeSaved = native("--analyze-checkpoint", [
        head,
        ...frames.slice(0, cut),
      ])[0];
      const webSaved = browser(head, frames.slice(0, cut)).checkpoint;
      closeNumeric(webSaved, nativeSaved);
      for (const saved of [nativeSaved, webSaved]) {
        const resumed = { resume: saved };
        const web = browser(resumed, frames.slice(cut));
        closeNumeric(web.frames, complete.frames.slice(cut));
        closeNumeric(web.checkpoint, complete.checkpoint);
        closeNumeric(
          native("--analyze", [resumed, ...frames.slice(cut)]),
          complete.frames.slice(cut),
        );
        closeNumeric(
          native("--analyze-checkpoint", [resumed, ...frames.slice(cut)])[0],
          complete.checkpoint,
        );
        continuations += 2;
      }
      // Both nested old formats can still be imported, preserving the same state.
      closeNumeric(
        browser(
          source(
            { resume: nativeSaved.measurement },
            { resume: nativeSaved.counting },
          ),
          frames.slice(cut),
        ),
        { frames: complete.frames.slice(cut), checkpoint: complete.checkpoint },
      );
      cutPoints++;
    }
  }
  assert.equal(continuations, cutPoints * 4);
  context.diagnostic(
    JSON.stringify({
      cut_points: cutPoints,
      continuations,
      directions: [
        "native-native",
        "native-javascript",
        "javascript-native",
        "javascript-javascript",
      ],
    }),
  );
});

test("joint restore rejects mismatched watermarks, accepted identities, quality and latest anchors", () => {
  const fixture = groundFixture();
  const head = source(fixture.measurement, fixture.counting);
  const saved = browser(head, fixture.frames.slice(0, 1)).checkpoint;
  const mutations = [
    (v) => {
      v.counting.configuration.session_id = "other";
    },
    (v) => {
      v.counting.state.last_timestamp_us = String(
        BigInt(v.counting.state.last_timestamp_us) + 1n,
      );
    },
    (v) => {
      v.counting.state.tracks.pop();
    },
    (v) => {
      v.counting.state.tracks[0].segment_id = "123";
    },
    (v) => {
      v.counting.state.tracks[0].anchors[0] = null;
    },
    (v) => {
      v.counting.state.tracks[0].anchors[0].point_m[0] += 0.1;
    },
    (v) => {
      v.counting.state.tracks[0].anchors[0].timestamp_us = String(
        BigInt(v.counting.state.last_timestamp_us) - 1n,
      );
    },
    (v) => {
      v.counting.configuration.max_position_std_m = 0.001;
    },
  ];
  for (const mutate of mutations) {
    const invalid = clone(saved);
    mutate(invalid);
    failure(invoke({ resume: invalid }, ""));
    native("--analyze-checkpoint", [{ resume: invalid }], 2);
  }
  failure(invoke(source({ resume: saved.measurement }, fixture.counting), ""));
  failure(invoke(source(fixture.measurement, { resume: saved.counting }), ""));
  closeNumeric(browser({ resume: saved }, fixture.frames.slice(1)), {
    frames: browser(head, fixture.frames).frames.slice(1),
    checkpoint: browser(head, fixture.frames).checkpoint,
  });
});

test("raw tokens, duplicate keys and late failures return only an error and never partial batches", () => {
  const fixture = groundFixture();
  const head = source(fixture.measurement, fixture.counting);
  failure(
    invoke(
      source(
        line(fixture.measurement).replace(
          '"max_tracks":100',
          '"max_tracks":100.0000000000000001',
        ),
        fixture.counting,
      ),
      "",
    ),
  );
  failure(
    invoke(
      source(
        fixture.measurement,
        line(fixture.counting).replace(
          '"max_tracks":100',
          '"max_tracks":100.0000000000000001',
        ),
      ),
      "",
    ),
  );
  failure(
    invoke(
      source(
        '{"mode":"ground",' + line(fixture.measurement).slice(1),
        fixture.counting,
      ),
      "",
    ),
  );
  failure(invoke('{"measurement":"bad",' + line(head).slice(1), ""));
  failure(
    invoke(
      head,
      ndjson(fixture.frames).replace(
        '"track_id":3',
        '"track_id":3.0000000000000001',
      ),
    ),
  );
  failure(
    invoke(
      head,
      ndjson([
        fixture.frames[0],
        '{"timestamp_us":"1",' + line(fixture.frames[1]).slice(1),
      ]),
    ),
  );
  failure(
    invoke(
      head,
      ndjson([...fixture.frames, { ...fixture.frames.at(-1), extra: true }]),
    ),
  );
  failure(invoke(head, ndjson([fixture.frames[0], ""])));
  failure(
    moonground_analysis(JSON.stringify({ source: head, observations: "" })),
  );
  failure(
    moonground_analysis(
      JSON.stringify({ source: line(head), observations: "", extra: true }),
    ),
  );
  const integral = ndjson(fixture.frames).replace(
    '"track_id":3',
    '"track_id":30e-1',
  );
  closeNumeric(browser(head, integral), browser(head, fixture.frames));
  closeNumeric(
    browser(head, fixture.frames.map(line).join("\r\n")),
    browser(head, fixture.frames),
  );
  closeNumeric(
    browser(head, fixture.frames.map(line).join("\n")),
    browser(head, fixture.frames),
  );
  assert.deepEqual(browser(head, []).frames, []);
});

test("saturated counters and a gate numerical failure expose no partial checkpoint and keep saved inputs reusable", () => {
  const measurement = {
    session_id: "analysis-overflow",
    mode: "ground",
    diagnostics: true,
    motion: { gate: 1e9, initial_velocity_std: 5, max_tracks: 10 },
  };
  const head = source(measurement, counting(measurement.session_id));
  const first = frame(100000, [observation(1, [0, -1])]);
  const later = frame(200000, [observation(1, [0, 1])]);
  const saved = browser(head, [first]).checkpoint;
  saved.counting.state.counts[0].negative_to_positive = "9223372036854775807";
  const before = clone(saved);
  failure(invoke({ resume: saved }, ndjson([later])));
  native("--analyze-checkpoint", [{ resume: saved }, later], 2);
  assert.deepEqual(saved, before);
  const correction = frame(200000, [observation(1, [0, -0.5])]);
  const corrected = browser({ resume: saved }, [correction]);
  assert.equal(
    corrected.checkpoint.measurement.motion.last_timestamp_us,
    "200000",
  );
  assert.equal(corrected.checkpoint.counting.state.last_timestamp_us, "200000");
  assert.deepEqual(
    corrected.checkpoint.counting.state.counts,
    saved.counting.state.counts,
  );
  const numericalHead = source(
    { session_id: "analysis-numerical", mode: "ground" },
    counting("analysis-numerical", [
      { ...gate("far", [1e308, 0], [1e308, 1]), deadband_m: 0 },
    ]),
  );
  const bad = frame(0, [
    { track_id: 1, point: [-1e308, 0], covariance: [1, 0, 1] },
  ]);
  failure(invoke(numericalHead, ndjson([bad])));
  native("--analyze-checkpoint", [numericalHead, bad], 2);
  assert.equal(
    browser(numericalHead, []).checkpoint.measurement.motion.last_timestamp_us,
    null,
  );
});

test("pure analysis remains available while all 64 legacy browser handles are occupied", () => {
  const handles = [];
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(
            JSON.stringify({ session_id: `occupied-${i}`, mode: "ground" }),
          ),
        ).handle,
      );
    failure(
      moonground_create('{"session_id":"over-capacity","mode":"ground"}'),
    );
    const fixture = groundFixture();
    assert.equal(
      browser(source(fixture.measurement, fixture.counting), fixture.frames)
        .frames.length,
      fixture.frames.length,
    );
    assert.equal(handles.length, 64);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
});

test("a retained stable anchor crosses after an in-band sample with exact counts above 2^53", () => {
  const measurement = {
    session_id: "analysis-band",
    mode: "ground",
    diagnostics: true,
    motion: { gate: 1e9, initial_velocity_std: 1000 },
  };
  const count = counting(measurement.session_id, [
    { ...gate(), deadband_m: 0.3 },
  ]);
  const head = source(measurement, count);
  const sample = (time, y) =>
    frame(time, [{ track_id: 1, point: [0, y], covariance: [1e-8, 0, 1e-8] }]);
  const first = sample(100000, -1);
  const middle = sample(200000, 0);
  const last = sample(300000, 1);
  const saved = browser(head, [first, middle]).checkpoint;
  assert.equal(
    saved.counting.state.tracks[0].anchors[0].timestamp_us,
    "100000",
  );
  assert.equal(saved.measurement.motion.last_timestamp_us, "200000");
  saved.counting.state.counts[0].negative_to_positive = "9007199254740993";
  const actual = browser({ resume: saved }, [last]);
  assert.equal(
    actual.frames[0].counting.counts[0].negative_to_positive,
    "9007199254740994",
  );
  assert.equal(
    actual.frames[0].counting.crossings[0].from_timestamp_us,
    "100000",
  );
  closeNumeric(actual.frames, native("--analyze", [{ resume: saved }, last]));
  closeNumeric(
    actual.checkpoint,
    native("--analyze-checkpoint", [{ resume: saved }, last])[0],
  );
});

test("UTF-16 source, observation, batch, frame count and wrapper bounds include exact limits", () => {
  const head = source(
    { session_id: "analysis-limits", mode: "ground" },
    counting("analysis-limits"),
  );
  const saved = browser(head, []).checkpoint;
  const exactSource = line({ resume: saved }).padEnd(8388619, " ");
  closeNumeric(browser(exactSource, []).checkpoint, saved);
  failure(invoke(exactSource + " ", ""));
  const exactLine = line(frame(0)).padEnd(1048576, " ");
  assert.equal(browser(head, exactLine).frames.length, 1);
  failure(invoke(head, exactLine + " "));
  const exactInput = Array.from(
    { length: 8 },
    (_, i) => line(frame(i)).padEnd(1048575, " ") + "\n",
  ).join("");
  assert.equal(exactInput.length, 8388608);
  assert.equal(browser(head, exactInput).frames.length, 8);
  failure(invoke(head, exactInput + " "));
  const maximum = Array.from({ length: 5000 }, (_, i) => frame(i));
  assert.equal(browser(head, maximum).frames.length, 5000);
  failure(invoke(head, ndjson([...maximum, frame(5000)])));
  const wrapper = JSON.stringify({
    source: line(head),
    observations: "",
  }).padEnd(16777216, " ");
  unpack(moonground_analysis(wrapper));
  failure(moonground_analysis(wrapper + " "));
});

test("native large result lines are complete and the pure bridge includes the final checkpoint in its output budget", (context) => {
  const sessionId = "x".repeat(400000);
  const head = source(
    { session_id: sessionId, mode: "ground" },
    counting(sessionId),
  );
  const frames = Array.from({ length: 10 }, (_, i) => frame(i));
  const error = failure(invoke(head, ndjson(frames)));
  assert.match(error, /output.*8388608/);
  assert.equal(browser(head, frames.slice(0, 8)).frames.length, 8);
  const measurement = {
    session_id: "analysis-large-output",
    mode: "ground",
    motion: { gate: 1e9, q: 100, initial_velocity_std: 1000, max_tracks: 800 },
  };
  const count = {
    ...counting(
      measurement.session_id,
      Array.from({ length: 16 }, (_, i) => gate(`gate-${i}`)),
    ),
    max_tracks: 800,
  };
  const observations = [-1, 1, -1, 1].map((y, index) =>
    frame(
      index * 100000,
      Array.from({ length: 800 }, (_, i) => ({
        track_id: i + 1,
        point: [0, y],
        covariance: [1e-8, 0, 1e-8],
      })),
    ),
  );
  const actual = native("--analyze", [
    source(measurement, count),
    ...observations,
  ]);
  assert.equal(actual.length, observations.length);
  assert.equal(actual[1].counting.crossings.length, 12800);
  assert.ok(line(actual[1]).length > 1048576);
  assert.match(
    failure(invoke(source(measurement, count), ndjson(observations))),
    /output.*8388608/,
  );
  context.diagnostic(
    `${actual[1].counting.crossings.length} crossings; native analysis line ${line(actual[1]).length} UTF-16 units`,
  );
});
