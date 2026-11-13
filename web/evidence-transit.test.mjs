import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_evidence_transit,
  moonground_gate_evidence,
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

function native(mode, values, status = 0) {
  const run = spawnSync(binary, [mode], {
    input: ndjson(values),
    encoding: "utf8",
    maxBuffer: 40 * 1024 * 1024,
    timeout: 120000,
  });
  assert.equal(run.status, status, run.stderr || run.error?.message);
  if (!status) assert.equal(run.stderr, "");
  if (run.stdout)
    assert.ok(run.stdout.endsWith("\n"), "partial native output line");
  if (status && mode === "--transit-evidence-checkpoint")
    assert.equal(run.stdout, "");
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

test("transit timing preserves existing native and pure gate results exactly", () => {
  const { source, frames } = fixture();
  const actual = browser(source, frames);
  closeNumeric(
    actual.frames,
    native("--transit-evidence", [source, ...frames]),
  );
  closeNumeric(
    actual.checkpoint,
    native("--transit-evidence-checkpoint", [source, ...frames])[0],
  );
  const old = unpack(
    moonground_gate_evidence(
      JSON.stringify({ source: source.counting, measurements: ndjson(frames) }),
    ),
  );
  closeNumeric(
    actual.frames.map((v) => v.counting),
    old.frames,
  );
  closeNumeric(actual.checkpoint.counting, old.checkpoint);
  assert.ok(actual.frames.some((v) => v.passages.length));
  for (const value of actual.frames)
    for (const passage of value.passages) {
      assert.ok(passage.estimated_elapsed_us > 0);
      assert.ok(
        passage.estimated_elapsed_us >= Number(passage.elapsed_lower_us),
      );
      assert.ok(
        passage.estimated_elapsed_us <= Number(passage.elapsed_upper_us),
      );
      assert.equal(passage.entry.segment_id, passage.exit.segment_id);
    }
});

test("one-microsecond brackets above 2^53 and at Int64 maximum keep exact differences", () => {
  for (const start of [9007199254740993n, 9223372036854775804n]) {
    const source = config();
    const separate = [-1, 1, 2, 4].map((y, i) =>
      frame(start + BigInt(i), [track(1, [0, y], start + BigInt(i))]),
    );
    const passage = browser(source, separate).frames.at(-1).passages[0];
    assert.equal(passage.elapsed_lower_us, "1");
    assert.equal(passage.elapsed_upper_us, "3");
    assert.equal(passage.estimated_elapsed_us, 2);
    const same = [-1, 4].map((y, i) =>
      frame(start + BigInt(i), [track(1, [0, y], start + BigInt(i))]),
    );
    const actual = browser(source, same);
    const small = actual.frames[1].passages[0];
    assert.equal(small.elapsed_lower_us, "0");
    assert.equal(small.elapsed_upper_us, "1");
    assert.ok(Math.abs(small.estimated_elapsed_us - 0.6) < 1e-12);
    assert.deepEqual(
      actual.frames[1].counting.counting.crossings.map((v) => v.gate_id),
      ["exit", "entry"],
    );
    closeNumeric(
      actual.frames,
      native("--transit-evidence", [source, ...same]),
    );
  }
});

test("every cut point resumes both gate anchors and section entries across four runtime directions", (context) => {
  const delayed = [-1, 1, 4].map((y, i) => {
    const value = track(1, [0, y], BigInt(i) * 100000n);
    value.position_covariance = i === 1 ? [0.36, 0, 0.36] : [0.01, 0, 0.01];
    return frame(BigInt(i) * 100000n, [value]);
  });
  let cuts = 0,
    continuations = 0;
  for (const { source, frames } of [
    fixture(),
    { source: config(), frames: delayed },
  ]) {
    const complete = browser(source, frames);
    for (let cut = 0; cut <= frames.length; cut++) {
      const nativeSaved = native("--transit-evidence-checkpoint", [
        source,
        ...frames.slice(0, cut),
      ])[0];
      const webSaved = browser(source, frames.slice(0, cut)).checkpoint;
      closeNumeric(nativeSaved, webSaved);
      for (const saved of [nativeSaved, webSaved]) {
        closeNumeric(browser({ resume: saved }, frames.slice(cut)), {
          frames: complete.frames.slice(cut),
          checkpoint: complete.checkpoint,
        });
        closeNumeric(
          native("--transit-evidence", [
            { resume: saved },
            ...frames.slice(cut),
          ]),
          complete.frames.slice(cut),
        );
        closeNumeric(
          native("--transit-evidence-checkpoint", [
            { resume: saved },
            ...frames.slice(cut),
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
        "native-native",
        "native-javascript",
        "javascript-native",
        "javascript-javascript",
      ],
    }),
  );
});

test("missing and interrupted segments cancel pending journeys without completing a gap", () => {
  const source = config();
  const frames = [
    frame(0n, [track(1, [0, -1], 0n)]),
    frame(100000n, [track(1, [0, 1], 100000n)]),
    frame(200000n, [], "transit-parity", ["1"]),
    frame(300000n, [track(1, [0, 4], 300000n, "2")]),
  ];
  const actual = browser(source, frames);
  assert.equal(actual.frames[1].pending_count, 1);
  assert.equal(actual.frames[2].cancellations[0].reason, "discontinuity");
  assert.equal(actual.frames[2].pending_count, 0);
  assert.deepEqual(
    actual.frames.flatMap((v) => v.passages),
    [],
  );
  closeNumeric(
    actual.frames,
    native("--transit-evidence", [source, ...frames]),
  );
});

test("raw tokens and malformed checkpoints fail atomically without partial outputs", () => {
  const { source, frames } = fixture();
  const saved = browser(source, frames.slice(0, 2)).checkpoint;
  const invalidSource = clone(source);
  const inner = JSON.parse(invalidSource.counting);
  inner.counting = inner.counting.replace(
    '"max_tracks":16',
    '"max_tracks":16.0000000000000001',
  );
  invalidSource.counting = line(inner);
  failure(invoke(invalidSource, ""));
  failure(invoke('{"counting":"bad",' + line(source).slice(1), ""));
  failure(
    invoke(
      source,
      ndjson(frames).replace('"track_id":1', '"track_id":1.0000000000000001'),
    ),
  );
  failure(invoke(source, ndjson([frames[0], { ...frames[1], extra: true }])));
  failure(invoke(source, ndjson([frames[0], ""])));
  for (const mutate of [
    (v) => {
      v.pending[0].entry.segment_id = "2";
    },
    (v) => {
      v.pending[0].entry.direction = "positive_to_negative";
    },
    (v) => {
      v.pending[0].entry.crossing_fraction = 0.25;
    },
    (v) => {
      v.pending[0].entry.position_m = [0.1, 0];
    },
    (v) => {
      v.counts[0].completed = "2";
    },
    (v) => {
      v.counting.state.tracks = [];
    },
    (v) => {
      delete v.pending[0].from_covariance;
    },
    (v) => {
      delete v.pending[0].to_covariance;
    },
    (v) => {
      v.pending[0].from_covariance = [1, 2, 1];
    },
    (v) => {
      v.pending[0].to_covariance = [1, 0, 1];
    },
  ]) {
    const invalid = clone(saved);
    mutate(invalid);
    failure(invoke({ resume: invalid }, ""));
    native("--transit-evidence-checkpoint", [{ resume: invalid }], 2);
  }
  failure(invoke({ resume: saved, sections: source.sections }, ""));
  closeNumeric(browser({ resume: saved }, frames.slice(2)), {
    frames: browser(source, frames).frames.slice(2),
    checkpoint: browser(source, frames).checkpoint,
  });
  closeNumeric(
    browser(source, frames.map(line).join("\r\n")),
    browser(source, frames),
  );
  closeNumeric(
    browser(source, frames.map(line).join("\n")),
    browser(source, frames),
  );
});

test("delayed confirmation on different anchors remains ambiguous even in one frame", () => {
  const source = config();
  const frames = [-1, 1, 4].map((y, i) => {
    const value = track(1, [0, y], BigInt(i) * 100000n);
    value.position_covariance = i === 1 ? [0.36, 0, 0.36] : [0.01, 0, 0.01];
    return frame(BigInt(i) * 100000n, [value]);
  });
  const actual = browser(source, frames);
  const last = actual.frames[2];
  assert.equal(last.counting.counting.crossings.length, 2);
  assert.notEqual(
    last.counting.counting.crossings[0].from_timestamp_us,
    last.counting.counting.crossings[1].from_timestamp_us,
  );
  assert.deepEqual(last.passages, []);
  assert.equal(last.cancellations[0].reason, "ambiguous_order");
  assert.equal(last.pending_count, 0);
  closeNumeric(
    actual.frames,
    native("--transit-evidence", [source, ...frames]),
  );
});

test("pending stores the actual endpoint covariances while newer anchors advance", () => {
  const source = config();
  const covariances = [
    [0.04, 0.01, 0.01],
    [0.01, -0.002, 0.04],
    [0.02, 0.003, 0.01],
  ];
  const frames = [-1, 1, 2].map((y, i) => {
    const value = track(1, [0, y], BigInt(i) * 100000n);
    value.position_covariance = covariances[i];
    return frame(BigInt(i) * 100000n, [value]);
  });
  const saved = browser(source, frames).checkpoint;
  assert.deepEqual(saved.pending[0].from_covariance, covariances[0]);
  assert.deepEqual(saved.pending[0].to_covariance, covariances[1]);
  const entryIndex = saved.counting.configuration.counting.gates.findIndex(
    (v) => v.gate_id === "entry",
  );
  assert.deepEqual(
    saved.counting.state.tracks[0].anchors[entryIndex].covariance,
    covariances[2],
  );
  closeNumeric(browser({ resume: saved }).checkpoint, saved);
  closeNumeric(
    saved,
    native("--transit-evidence-checkpoint", [source, ...frames])[0],
  );
});

test("pure transit uses no legacy handles and respects exact UTF-16 transport limits", () => {
  const handles = [];
  const { source } = fixture();
  try {
    for (let i = 0; i < 64; i++)
      handles.push(
        unpack(
          moonground_create(
            JSON.stringify({
              session_id: `transit-occupied-${i}`,
              mode: "ground",
            }),
          ),
        ).handle,
      );
    failure(moonground_create('{"session_id":"full","mode":"ground"}'));
    assert.equal(browser(source).frames.length, 0);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
  const saved = browser(source).checkpoint;
  const exactSource = line({ resume: saved }).padEnd(8388619, " ");
  closeNumeric(browser(exactSource).checkpoint, saved);
  failure(invoke(exactSource + " ", ""));
  const exactLine = line(frame(0n)).padEnd(1048576, " ");
  assert.equal(browser(source, exactLine).frames.length, 1);
  failure(invoke(source, exactLine + " "));
  const exactInput = Array.from(
    { length: 8 },
    (_, i) => line(frame(BigInt(i))).padEnd(1048575, " ") + "\n",
  ).join("");
  assert.equal(exactInput.length, 8388608);
  assert.equal(browser(source, exactInput).frames.length, 8);
  failure(invoke(source, exactInput + " "));
  const frames = Array.from({ length: 5000 }, (_, i) => frame(BigInt(i)));
  assert.equal(browser(source, frames).frames.length, 5000);
  failure(invoke(source, ndjson([...frames, frame(5000n)])));
  const request = JSON.stringify({
    source: line(source),
    measurements: "",
  }).padEnd(16777216, " ");
  unpack(moonground_evidence_transit(request));
  failure(moonground_evidence_transit(request + " "));
  failure(
    moonground_evidence_transit(
      JSON.stringify({ source: line(source), measurements: "", extra: true }),
    ),
  );
  failure(
    moonground_evidence_transit(
      '{"source":"bad",' +
        JSON.stringify({ source: line(source), measurements: "" }).slice(1),
    ),
  );
  failure(
    moonground_evidence_transit(JSON.stringify({ source, measurements: "" })),
  );
  failure(
    moonground_evidence_transit(
      JSON.stringify({ source: line(source), measurements: [] }),
    ),
  );
});

test("a started gate source preserves totals without inferring an earlier entry", () => {
  const source = config();
  const history = [
    frame(0n, [track(1, [0, -1], 0n)]),
    frame(100000n, [track(1, [0, 1], 100000n)]),
  ];
  const prior = native("--evidence-checkpoint", [
    JSON.parse(source.counting),
    ...history,
  ])[0];
  source.counting = line({ resume: prior });
  const future = [
    frame(200000n, [track(1, [0, 4], 200000n)]),
    frame(300000n, [track(1, [0, -1], 300000n)]),
  ];
  const actual = browser(source, future);
  assert.deepEqual(actual.frames[0].passages, []);
  assert.equal(actual.frames[0].pending_count, 0);
  assert.equal(actual.frames[1].passages[0].section_id, "backward");
  closeNumeric(
    actual.frames,
    native("--transit-evidence", [source, ...future]),
  );
});

test("bounded section state supports a measured pending load and native large frames while pure output stays bounded", (context) => {
  const source = config();
  source.sections = Array.from({ length: 16 }, (_, i) =>
    section(`section-${i}`, "entry", "exit", "negative_to_positive"),
  );
  const envelope = JSON.parse(source.counting);
  const counting = JSON.parse(envelope.counting);
  counting.max_tracks = 4096;
  source.counting = line({ ...envelope, counting: line(counting) });
  assert.equal(
    browser(source).checkpoint.sections.length,
    16,
    "exact constructor capacity was rejected",
  );
  counting.max_tracks = 4097;
  failure(
    invoke(
      { ...source, counting: line({ ...envelope, counting: line(counting) }) },
      "",
    ),
  );
  counting.max_tracks = 800;
  source.counting = line({ ...envelope, counting: line(counting) });
  const frames = [-1, 1, 4].map((y, index) =>
    frame(
      BigInt(index) * 100000n,
      Array.from({ length: 800 }, (_, i) =>
        track(i + 1, [0, y], BigInt(index) * 100000n, String(i + 1)),
      ),
    ),
  );
  const pending = browser(source, frames.slice(0, 2));
  assert.equal(pending.frames[1].pending_count, 12800);
  assert.equal(pending.checkpoint.pending.length, 12800);
  closeNumeric(
    pending.checkpoint,
    native("--transit-evidence-checkpoint", [source, ...frames.slice(0, 2)])[0],
  );
  const completed = native("--transit-evidence", [source, ...frames]);
  assert.equal(completed[2].passages.length, 12800);
  assert.ok(line(completed[2]).length > 1048576);
  assert.match(failure(invoke(source, ndjson(frames))), /output.*8388608/);
  context.diagnostic(
    JSON.stringify({
      pending_load: 12800,
      completed_passages: completed[2].passages.length,
      native_complete_frame_utf16_units: line(completed[2]).length,
      constructor_capacity_tested: 65536,
      pending_checkpoint_utf16_units: line(pending.checkpoint).length,
    }),
  );
});
