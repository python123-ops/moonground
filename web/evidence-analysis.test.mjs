import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_evidence_analysis,
  moonground_gate_evidence,
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
  "Build the native CLI before evidence-analysis verification.",
);
const clone = (v) => JSON.parse(JSON.stringify(v)),
  line = (v) => (typeof v === "string" ? v : JSON.stringify(v));
const ndjson = (records) =>
  records.map(line).join("\n") + (records.length ? "\n" : "");
const pair = (measurement, counting) => ({
  measurement: line(measurement),
  counting: line(counting),
});
const combine = (measurement, counting) => ({
  format: "moonground.evidence-analysis",
  checkpoint_version: "1",
  measurement,
  counting,
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
  moonground_evidence_analysis(
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
  if (status && mode === "--analyze-evidence-checkpoint")
    assert.equal(run.stdout, "");
  return run.stdout ? run.stdout.trimEnd().split("\n").map(JSON.parse) : [];
}
const observation = (id, point, covariance = [0.01, 0.002, 0.02]) => ({
  track_id: id,
  point,
  covariance,
});
const frame = (time, observations = [], lost = [], removed = []) => ({
  timestamp_us: String(time),
  observations,
  lost,
  removed,
});
const gate = (id = "horizontal", start = [-10, 0], end = [10, 0]) => ({
  gate_id: id,
  start_m: start,
  end_m: end,
  deadband_m: 0.005,
});
const policy = (name, gates = [gate()], k = 2) => ({
  counting: line({
    session_id: name,
    gates,
    max_gap_us: "500000",
    max_tracks: 1000,
  }),
  sigma_multiplier: k,
});
function fixture(start = 9007199254740993n) {
  const measurement = {
    session_id: "evidence-analysis-browser",
    mode: "ground",
    diagnostics: true,
    motion: {
      max_tracks: 10,
      max_gap_us: "500000",
      min_observations: 2,
      min_span_us: "100000",
      initial_velocity_std: 5,
      gate: 1e9,
      q: 5,
    },
  };
  const counting = policy(measurement.session_id, [
    gate(),
    gate("vertical", [0, -10], [0, 10]),
  ]);
  const frames = [-1, -0.5, 0, 0.5, 1, 0, -1].map((y, i) =>
    frame(start + BigInt(i) * 100000n, [
      observation(3, [0, y]),
      observation(1, [y, 0.5]),
    ]),
  );
  frames.push(frame(start + 700000n, [], [3]));
  frames.push(frame(start + 800000n, [observation(1, [0.5, 0.5])], [], [3]));
  frames.push(frame(start + 1300000n, [observation(3, [0, -1])]));
  frames.push(frame(start + 1400000n, [observation(3, [0, 1])]));
  return { measurement, counting, frames, header: pair(measurement, counting) };
}
function separate(measurement, counting, frames) {
  const measured = native("--stream", [measurement, ...frames]);
  const counted = unpack(
    moonground_gate_evidence(
      JSON.stringify({
        source: line(counting),
        measurements: ndjson(measured),
      }),
    ),
  );
  return {
    frames: measured.map((measurement, i) => ({
      schema_version: "0.1.0",
      kind: "evidence_analysis_frame",
      measurement,
      counting: counted.frames[i],
    })),
    checkpoint: combine(
      native("--checkpoint", [measurement, ...frames])[0],
      counted.checkpoint,
    ),
  };
}

test("combined analysis equals the existing measurement and pure covariance counter paths", () => {
  const fixtures = [fixture()];
  for (const name of ["warehouse", "distorted-camera", "reframe"]) {
    const records = readFileSync(
        path.join(root, `examples/${name}.ndjson`),
        "utf8",
      )
        .trimEnd()
        .split("\n")
        .map(JSON.parse),
      measurement = records[0];
    measurement.diagnostics = true;
    const counting = policy(measurement.session_id, [
      gate("horizontal", [-100, 3.8], [100, 3.8]),
      gate("vertical", [1.2, -100], [1.2, 100]),
    ]);
    fixtures.push({
      measurement,
      counting,
      frames: records.slice(1),
      header: pair(measurement, counting),
    });
  }
  let crossings = 0;
  for (const { measurement, counting, frames, header } of fixtures) {
    const actual = browser(header, frames);
    close(actual, separate(measurement, counting, frames));
    close(actual.frames, native("--analyze-evidence", [header, ...frames]));
    close(
      actual.checkpoint,
      native("--analyze-evidence-checkpoint", [header, ...frames])[0],
    );
    crossings += actual.frames.reduce(
      (s, v) => s + v.counting.counting.crossings.length,
      0,
    );
  }
  assert.ok(crossings > 0);
});

test("all saved cuts continue in the four native/browser directions and both source forms", (t) => {
  const brown = readFileSync(
    path.join(root, "examples/distorted-camera.ndjson"),
    "utf8",
  )
    .trimEnd()
    .split("\n")
    .map(JSON.parse);
  brown[0].diagnostics = true;
  const samples = [
    fixture(),
    {
      header: pair(brown[0], policy(brown[0].session_id)),
      frames: brown.slice(1),
    },
  ];
  let continuations = 0,
    cutPoints = 0;
  for (const { header, frames } of samples) {
    const expected = browser(header, frames);
    for (let cut = 0; cut <= frames.length; cut++) {
      const before = frames.slice(0, cut),
        after = frames.slice(cut),
        saves = [
          native("--analyze-evidence-checkpoint", [header, ...before])[0],
          browser(header, before).checkpoint,
        ];
      close(saves[0], saves[1]);
      for (const saved of saves) {
        const resume = { resume: saved },
          result = browser(resume, after);
        close(result.frames, expected.frames.slice(cut));
        close(result.checkpoint, expected.checkpoint);
        continuations++;
        close(
          native("--analyze-evidence", [resume, ...after]),
          expected.frames.slice(cut),
        );
        close(
          native("--analyze-evidence-checkpoint", [resume, ...after])[0],
          expected.checkpoint,
        );
        continuations++;
        close(
          browser(
            pair({ resume: saved.measurement }, { resume: saved.counting }),
            after,
          ),
          result,
        );
      }
      cutPoints++;
    }
  }
  t.diagnostic(
    JSON.stringify({
      cut_points: cutPoints,
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

test("a historical stable anchor remains valid when the current mean is outside the old deadband but unconfirmed", () => {
  const { measurement } = fixture(0n);
  measurement.motion.initial_velocity_std = 1000;
  const counting = policy(measurement.session_id),
    header = pair(measurement, counting);
  const frames = [
    frame(0, [observation(1, [0, -1], [0.01, 0, 0.01])]),
    frame(100000, [observation(1, [0, 0.1], [1, 0, 1])]),
    frame(200000, [observation(1, [0, 3], [0.01, 0, 0.01])]),
  ];
  const prefix = browser(header, frames.slice(0, 2)),
    saved = prefix.checkpoint,
    anchor = saved.counting.state.tracks[0].anchors[0];
  assert.ok(prefix.frames[1].measurement.tracks[0].position_m[1] > 0.05);
  assert.equal(prefix.frames[1].counting.evidence[0].side, "unconfirmed");
  assert.equal(anchor.timestamp_us, "0");
  close(
    browser({ resume: saved }, frames.slice(2)).checkpoint,
    browser(header, frames).checkpoint,
  );
  for (const mutate of [
    (v) => (v.counting.state.tracks[0].anchors[0].point_m = [0.25, -1]),
    (v) => (v.counting.state.tracks[0].anchors[0].timestamp_us = "100000"),
  ]) {
    const invalid = clone(saved);
    mutate(invalid);
    unpack(
      moonground_gate_evidence(
        JSON.stringify({
          source: line({ resume: invalid.counting }),
          measurements: "",
        }),
      ),
    );
    failure(invoke({ resume: invalid }, ""));
  }
});

test("raw token, canonical checkpoint, and cross-engine relationship errors are rejected without partial results", () => {
  const { header, frames } = fixture(),
    saved = browser(header, frames.slice(0, 1)).checkpoint;
  const invalidSource = [
    { measurement: header.measurement },
    { ...header, counting: JSON.parse(header.counting) },
    '{"measurement":"bad",' + line(header).slice(1),
    pair({ resume: saved.measurement }, JSON.parse(header.counting)),
    pair(JSON.parse(header.measurement), { resume: saved.counting }),
  ];
  for (const value of invalidSource) failure(invoke(value, ""));
  for (const mutate of [
    (v) => (v.counting.state.last_timestamp_us = "9007199254740994"),
    (v) => (v.counting.state.tracks = []),
    (v) => (v.counting.state.tracks[0].segment_id = "2"),
    (v) => delete v.counting.configuration.counting.max_gap_us,
    (v) => delete v.counting.configuration.counting.max_tracks,
    (v) => delete v.counting.configuration.counting.gates[0].deadband_m,
    (v) => delete v.counting.configuration.sigma_multiplier,
  ]) {
    const invalid = clone(saved);
    mutate(invalid);
    failure(invoke({ resume: invalid }, ""));
  }
  const invalid = line(frames[1]).replace(
    '"track_id":3',
    '"track_id":3.0000000000000001',
  );
  failure(invoke(header, ndjson([frames[0], invalid])));
  native("--analyze-evidence-checkpoint", [header, frames[0], invalid], 2);
});

test("downstream numeric failure leaves saved motion time and segment allocation reusable", () => {
  const measurement = {
      session_id: "evidence-analysis-numeric",
      mode: "ground",
    },
    counting = policy(measurement.session_id),
    header = pair(measurement, counting),
    empty = frame(0);
  const saved = browser(header, [empty]).checkpoint,
    bad = frame(1, [observation(1, [0, 1e200], [1, 0, 1])]);
  native("--checkpoint", [measurement, empty, bad]);
  failure(invoke({ resume: saved }, ndjson([bad])));
  assert.equal(native("--analyze-evidence", [header, empty, bad], 2).length, 1);
  native("--analyze-evidence-checkpoint", [header, empty, bad], 2);
  const corrected = browser({ resume: saved }, [
    frame(1, [observation(1, [0, 3], [1, 0, 1])]),
  ]);
  assert.equal(corrected.frames[0].measurement.tracks[0].segment_id, "1");
  assert.equal(corrected.checkpoint.measurement.motion.next_segment_id, "2");
  assert.equal(corrected.checkpoint.counting.state.last_timestamp_us, "1");
});

test("saturated counts fail atomically and an empty same-time correction clears evidence anchors", () => {
  const { measurement } = fixture(0n),
    counting = policy(measurement.session_id),
    header = pair(measurement, counting);
  const first = frame(0, [observation(1, [0, -1])]),
    later = frame(100000, [observation(1, [0, 1])]),
    saved = browser(header, [first]).checkpoint;
  saved.counting.state.counts[0].negative_to_positive = "9223372036854775807";
  failure(invoke({ resume: saved }, ndjson([later])));
  native("--analyze-evidence-checkpoint", [{ resume: saved }, later], 2);
  const corrected = browser({ resume: saved }, [frame(100000)]).checkpoint;
  assert.deepEqual(
    corrected.counting.state.counts,
    saved.counting.state.counts,
  );
  assert.deepEqual(corrected.counting.state.tracks, []);
  assert.equal(corrected.measurement.motion.last_timestamp_us, "100000");
  assert.equal(corrected.counting.state.last_timestamp_us, "100000");
});

test("inherited raw source, frame, total input, frame count, wrapper and complete output budgets are enforced", () => {
  const { header } = fixture(0n),
    saved = browser(header).checkpoint,
    empty = (i) => frame(i);
  const resume = line({ resume: saved }).padEnd(8388619, " ");
  close(browser(resume).checkpoint, saved);
  failure(invoke(resume + " ", ""));
  const exact = line(empty(0)).padEnd(1048576, " ");
  assert.equal(browser(header, exact + "\n").frames.length, 1);
  failure(invoke(header, exact + " \n"));
  const input = Array.from(
    { length: 8 },
    (_, i) => line(empty(i)).padEnd(1048575, " ") + "\n",
  ).join("");
  assert.equal(input.length, 8388608);
  assert.equal(browser(header, input).frames.length, 8);
  failure(invoke(header, input + " "));
  const frames = Array.from({ length: 5000 }, (_, i) => empty(i));
  assert.equal(browser(header, frames).frames.length, 5000);
  failure(invoke(header, ndjson([...frames, empty(5000)])));
  const request = JSON.stringify({
    source: line(header),
    observations: "",
  }).padEnd(16777216, " ");
  unpack(moonground_evidence_analysis(request));
  failure(moonground_evidence_analysis(request + " "));
  let selected, selectedHeader;
  for (let width = 1; width <= 128 && !selected; width++) {
    const measurement = {
        session_id: "evidence-analysis-output",
        mode: "ground",
      },
      counting = policy(
        measurement.session_id,
        Array.from({ length: 16 }, (_, i) =>
          gate(String(i).padEnd(width, "x")),
        ),
      );
    selectedHeader = pair(measurement, counting);
    const proto = browser(selectedHeader, [frame(0)]),
      frameLength = line(proto.frames[0]).length;
    let sum = 0;
    for (let count = 1; count <= 5000; count++) {
      const timestamp = String(count - 1);
      sum += frameLength + 2 * (timestamp.length - 1);
      proto.checkpoint.measurement.motion.last_timestamp_us = timestamp;
      proto.checkpoint.counting.state.last_timestamp_us = timestamp;
      const totalLength =
        '{"frames":['.length +
        sum +
        count -
        1 +
        '],"checkpoint":'.length +
        line(proto.checkpoint).length +
        1;
      if (totalLength > 8388608) {
        if (sum + count <= 8388608) selected = { count, totalLength };
        break;
      }
    }
  }
  assert.ok(selected);
  const bundle = Array.from({ length: selected.count }, (_, i) => frame(i));
  assert.equal(
    browser(selectedHeader, bundle.slice(0, -1)).frames.length,
    bundle.length - 1,
  );
  assert.match(
    failure(invoke(selectedHeader, ndjson(bundle))),
    /output.*8388608/,
  );
});

test("pure combined analysis does not reserve handles and supports the exact Int64 maximum watermark", () => {
  const { header, frames } = fixture(9223372036854775807n - 1400000n),
    expected = browser(header, frames),
    handles = [];
  assert.equal(
    expected.checkpoint.measurement.motion.last_timestamp_us,
    "9223372036854775807",
  );
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(line({ session_id: "held-" + i, mode: "ground" })),
        ).handle,
      );
    close(browser(header, frames), expected);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
});
