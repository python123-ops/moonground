import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_evidence_transit_analysis,
  moonground_evidence_transit,
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
  if (status && mode === "--analyze-transit-evidence-checkpoint")
    assert.equal(run.stdout, "");
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

test("atomic outputs and complete state equal the existing measurement and evidence transit owners", () => {
  const samples = [fixture()];
  for (const name of ["warehouse", "distorted-camera", "reframe"]) {
    const records = readFileSync(
      path.join(root, `examples/${name}.ndjson`),
      "utf8",
    )
      .trimEnd()
      .split("\n")
      .map(JSON.parse);
    const measurement = records[0];
    measurement.diagnostics = true;
    const transit = policy(measurement.session_id, [
      gate("entry", 3.8),
      gate("exit", 4.3),
    ]);
    samples.push({
      measurement,
      transit,
      frames: records.slice(1),
      header: pair(measurement, transit),
    });
  }
  let passages = 0;
  for (const { measurement, transit, frames, header } of samples) {
    const actual = browser(header, frames);
    close(actual, separate(measurement, transit, frames));
    close(
      actual.frames,
      native("--analyze-transit-evidence", [header, ...frames]),
    );
    close(
      actual.checkpoint,
      native("--analyze-transit-evidence-checkpoint", [header, ...frames])[0],
    );
    passages += actual.frames.reduce(
      (count, value) => count + value.transit.passages.length,
      0,
    );
  }
  assert.ok(passages > 0);
});

test("every native and JavaScript checkpoint cut continues in four directions and both source forms", (t) => {
  const records = readFileSync(
    path.join(root, "examples/distorted-camera.ndjson"),
    "utf8",
  )
    .trimEnd()
    .split("\n")
    .map(JSON.parse);
  records[0].diagnostics = true;
  const samples = [
    fixture(),
    {
      header: pair(
        records[0],
        policy(records[0].session_id, [gate("entry", 3.8), gate("exit", 4.3)]),
      ),
      frames: records.slice(1),
    },
  ];
  let cutPoints = 0,
    continuations = 0;
  for (const { header, frames } of samples) {
    const expected = browser(header, frames);
    for (let cut = 0; cut <= frames.length; cut++) {
      const before = frames.slice(0, cut),
        after = frames.slice(cut);
      const saves = [
        native("--analyze-transit-evidence-checkpoint", [header, ...before])[0],
        browser(header, before).checkpoint,
      ];
      close(saves[0], saves[1]);
      for (const saved of saves) {
        const result = browser({ resume: saved }, after);
        close(result, {
          frames: expected.frames.slice(cut),
          checkpoint: expected.checkpoint,
        });
        close(
          native("--analyze-transit-evidence", [{ resume: saved }, ...after]),
          expected.frames.slice(cut),
        );
        close(
          native("--analyze-transit-evidence-checkpoint", [
            { resume: saved },
            ...after,
          ])[0],
          expected.checkpoint,
        );
        close(
          browser(
            pair({ resume: saved.measurement }, { resume: saved.transit }),
            after,
          ),
          result,
        );
        continuations += 2;
      }
      cutPoints++;
    }
  }
  t.diagnostic(
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

test("pending covariances remain the original accepted endpoint values after anchors advance", () => {
  const { header, frames } = fixture(0n);
  const prefix = browser(header, frames.slice(0, 2));
  const pending = prefix.checkpoint.transit.pending[0];
  assert.deepEqual(
    pending.from_covariance,
    prefix.frames[0].measurement.tracks[0].position_covariance,
  );
  assert.deepEqual(
    pending.to_covariance,
    prefix.frames[1].measurement.tracks[0].position_covariance,
  );
  const advanced = browser(header, frames.slice(0, 3));
  assert.deepEqual(advanced.checkpoint.transit.pending[0], pending);
  assert.equal(
    advanced.checkpoint.transit.counting.state.tracks[0].anchors[0]
      .timestamp_us,
    "200000",
  );
  close(browser({ resume: advanced.checkpoint }, frames.slice(3)), {
    frames: browser(header, frames).frames.slice(3),
    checkpoint: browser(header, frames).checkpoint,
  });
});

test("raw fields, original integer tokens and impossible cross-checkpoint relationships fail without partial results", () => {
  const { header, frames } = fixture(0n);
  const saved = browser(header, frames.slice(0, 3)).checkpoint;
  for (const source of [
    { measurement: header.measurement },
    { ...header, transit: JSON.parse(header.transit) },
    '{"measurement":"bad",' + line(header).slice(1),
    pair({ resume: saved.measurement }, JSON.parse(header.transit)),
    pair(JSON.parse(header.measurement), { resume: saved.transit }),
  ])
    failure(invoke(source, ""));
  for (const mutate of [
    (v) => (v.transit.counting.state.last_timestamp_us = "200001"),
    (v) => (v.transit.counting.state.tracks = []),
    (v) => (v.transit.counting.state.tracks[0].segment_id = "2"),
    (v) =>
      (v.transit.counting.state.tracks[0].anchors[0].covariance = [
        0.02, 0, 0.02,
      ]),
    (v) => delete v.transit.counting.configuration.sigma_multiplier,
    (v) => delete v.transit.pending[0].from_covariance,
    (v) => (v.measurement.motion.tracks[0].first_timestamp_us = "50000"),
    (v) => (v.measurement.motion.tracks[0].accepted_count = 2),
  ]) {
    const invalid = clone(saved);
    mutate(invalid);
    failure(invoke({ resume: invalid }, ""));
    native("--analyze-transit-evidence-checkpoint", [{ resume: invalid }], 2);
  }
  const invalid = line(frames[1]).replace(
    '"track_id":1',
    '"track_id":1.0000000000000001',
  );
  failure(invoke(header, ndjson([frames[0], invalid])));
  native(
    "--analyze-transit-evidence-checkpoint",
    [header, frames[0], invalid],
    2,
  );
  const raw = JSON.stringify({ source: line(header), observations: "" });
  failure(
    moonground_evidence_transit_analysis('{"source":"bad",' + raw.slice(1)),
  );
  failure(
    moonground_evidence_transit_analysis(
      JSON.stringify({ source: line(header), observations: "", extra: true }),
    ),
  );
});

test("historical witnesses at one accepted timestamp must agree across gates and pending entries", () => {
  const { header, frames } = fixture(0n);
  frames[2].observations[0].covariance = [0.36, 0, 0.36];
  const saved = browser(header, frames.slice(0, 3)).checkpoint;
  const pending = saved.transit.pending[0];
  assert.equal(
    saved.transit.counting.state.tracks[0].anchors[1].timestamp_us,
    pending.entry.to_timestamp_us,
  );
  pending.to_covariance = [0.04, 0, 0.04];
  unpack(
    moonground_evidence_transit(
      JSON.stringify({
        source: line({ resume: saved.transit }),
        measurements: "",
      }),
    ),
  );
  failure(invoke({ resume: saved }, ""));
  native("--analyze-transit-evidence-checkpoint", [{ resume: saved }], 2);
});

test("a downstream normal failure leaves the saved time and first segment reusable", () => {
  const { measurement, transit } = fixture(0n),
    header = pair(measurement, transit);
  const saved = browser(header, [frame(0)]).checkpoint;
  const bad = frame(1, [observation(1, [0, 1e200], [1, 0, 1])]);
  native("--checkpoint", [measurement, frame(0), bad]);
  failure(invoke({ resume: saved }, ndjson([bad])));
  assert.equal(
    native("--analyze-transit-evidence", [header, frame(0), bad], 2).length,
    1,
  );
  native("--analyze-transit-evidence-checkpoint", [header, frame(0), bad], 2);
  const good = browser({ resume: saved }, [
    frame(1, [observation(1, [0, 3], [1, 0, 1])]),
  ]);
  assert.equal(good.frames[0].measurement.tracks[0].segment_id, "1");
  assert.equal(good.checkpoint.measurement.motion.next_segment_id, "2");
  assert.equal(good.checkpoint.transit.counting.state.last_timestamp_us, "1");
});

test("gate overflow rolls back a new target allocation and permits a corrected same-time frame", () => {
  const { header, frames } = fixture(0n);
  const saved = browser(header, frames.slice(0, 1)).checkpoint;
  saved.transit.counting.state.counts[0].negative_to_positive =
    "9223372036854775807";
  const later = clone(frames[1]);
  later.observations.push(observation(2, [0, -1]));
  failure(invoke({ resume: saved }, ndjson([later])));
  native(
    "--analyze-transit-evidence-checkpoint",
    [{ resume: saved }, later],
    2,
  );
  later.observations[0].point = [0, -2];
  const good = browser({ resume: saved }, [later]);
  assert.equal(good.checkpoint.measurement.motion.next_segment_id, "3");
  assert.deepEqual(
    good.checkpoint.measurement.motion.tracks.map((v) => v.segment_id),
    ["1", "2"],
  );
  assert.deepEqual(
    good.checkpoint.transit.counting.state.counts,
    saved.transit.counting.state.counts,
  );
});

test("all transport budgets include the final joint checkpoint in the whole output", () => {
  const { header } = fixture(0n),
    saved = browser(header).checkpoint;
  const resume = line({ resume: saved }).padEnd(8388619, " ");
  close(browser(resume).checkpoint, saved);
  failure(invoke(resume + " ", ""));
  const exact = line(frame(0)).padEnd(1048576, " ");
  assert.equal(browser(header, exact).frames.length, 1);
  failure(invoke(header, exact + " "));
  const input = Array.from(
    { length: 8 },
    (_, i) => line(frame(i)).padEnd(1048575, " ") + "\n",
  ).join("");
  assert.equal(input.length, 8388608);
  assert.equal(browser(header, input).frames.length, 8);
  failure(invoke(header, input + " "));
  const frames = Array.from({ length: 5000 }, (_, i) => frame(i));
  assert.equal(browser(header, frames).frames.length, 5000);
  failure(invoke(header, ndjson([...frames, frame(5000)])));
  const request = JSON.stringify({
    source: line(header),
    observations: "",
  }).padEnd(16777216, " ");
  unpack(moonground_evidence_transit_analysis(request));
  failure(moonground_evidence_transit_analysis(request + " "));
  let selected, selectedHeader;
  for (let width = 1; width <= 128 && !selected; width++) {
    const measurement = {
      session_id: "transit-analysis-output",
      mode: "ground",
    };
    const transit = policy(
      measurement.session_id,
      Array.from({ length: 16 }, (_, i) =>
        gate(String(i).padEnd(width, "x"), i),
      ),
    );
    selectedHeader = pair(measurement, transit);
    const proto = browser(selectedHeader, [frame(0)]),
      length = line(proto.frames[0]).length;
    let sum = 0;
    for (let count = 1; count <= 5000; count++) {
      const timestamp = String(count - 1);
      sum += length + 2 * (timestamp.length - 1);
      proto.checkpoint.measurement.motion.last_timestamp_us = timestamp;
      proto.checkpoint.transit.counting.state.last_timestamp_us = timestamp;
      const total =
        '{"frames":['.length +
        sum +
        count -
        1 +
        '],"checkpoint":'.length +
        line(proto.checkpoint).length +
        1;
      if (total > 8388608) {
        if (sum + count <= 8388608) selected = { count, total };
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

test("pure replay uses no persistent handles and keeps the exact Int64 maximum watermark", () => {
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
          moonground_create(
            line({ session_id: "held-transit-" + i, mode: "ground" }),
          ),
        ).handle,
      );
    close(browser(header, frames), expected);
  } finally {
    for (const handle of handles) assert.equal(moonground_close(handle), true);
  }
});
