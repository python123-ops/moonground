import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  moonground_reframe,
  moonground_create,
  moonground_update,
  moonground_checkpoint,
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
  "Build the native release CLI before reframing verification.",
);

const clone = (value) => JSON.parse(JSON.stringify(value));
const line = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
const ndjson = (records) => records.map(line).join("\n") + "\n";
const parseLines = (source) => source.trimEnd().split("\n").map(JSON.parse);
const unpack = (source) => {
  const value = JSON.parse(source);
  assert.equal(value.error, undefined, source);
  return value;
};
const failure = (source) => {
  const value = JSON.parse(source);
  assert.equal(typeof value.error, "string", source.slice(0, 500));
  assert.deepEqual(
    Object.keys(value),
    ["error"],
    "failed bundle exposed output",
  );
  return value.error;
};

function closeNumeric(actual, expected, location = "$", tolerance = 3e-8) {
  if (typeof expected === "number") {
    assert.equal(typeof actual, "number", location);
    assert.ok(Number.isFinite(actual), location);
    if (
      /\.(track_id|accepted_count|frame_count|max_tracks|min_observations)$/.test(
        location,
      )
    ) {
      assert.equal(actual, expected, location);
    } else {
      assert.ok(
        Math.abs(actual - expected) <=
          tolerance * Math.max(1, Math.abs(expected)),
        `${location}: ${actual} != ${expected}`,
      );
    }
  } else if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual), location);
    assert.equal(actual.length, expected.length, location);
    expected.forEach((value, index) =>
      closeNumeric(actual[index], value, `${location}[${index}]`, tolerance),
    );
  } else if (expected && typeof expected === "object") {
    assert.deepEqual(
      Object.keys(actual).sort(),
      Object.keys(expected).sort(),
      location,
    );
    for (const key of Object.keys(expected))
      closeNumeric(actual[key], expected[key], `${location}.${key}`, tolerance);
  } else assert.equal(actual, expected, location);
}

function native(mode, records, status = 0, extra = []) {
  const output = spawnSync(binary, [mode, ...extra], {
    input: ndjson(records),
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    timeout: 120000,
  });
  assert.equal(output.status, status, output.stderr || output.error?.message);
  if (!status) assert.equal(output.stderr, "");
  if (output.stdout)
    assert.ok(output.stdout.endsWith("\n"), "incomplete native output line");
  return output.stdout ? parseLines(output.stdout) : [];
}

function browserReframe(records, transform) {
  const result = unpack(
    moonground_reframe(JSON.stringify({ ndjson: ndjson(records), transform })),
  );
  assert.equal(result.frame_count, records.length - 1);
  assert.ok(result.ndjson.endsWith("\n"));
  return parseLines(result.ndjson);
}

function nativeReframe(records, transform) {
  return native("--reframe", [
    { source: records[0], transform },
    ...records.slice(1),
  ]);
}

function browserReplay(records) {
  const { handle } = unpack(moonground_create(line(records[0])));
  try {
    return {
      measurements: records
        .slice(1)
        .map((frame) => unpack(moonground_update(handle, line(frame)))),
      checkpoint: unpack(moonground_checkpoint(handle)),
    };
  } finally {
    assert.equal(moonground_close(handle), true);
  }
}

function fixture(camera = true) {
  const records = readFileSync(
    path.join(root, "examples/distorted-camera.ndjson"),
    "utf8",
  )
    .trim()
    .split("\n")
    .map(JSON.parse);
  records[0].diagnostics = true;
  records[0].session_id = camera ? "reframe-camera" : "reframe-no-camera";
  if (!camera) delete records[0].camera;
  records.slice(1).forEach((item, index) => {
    // Both covariance paths must preserve the same ground uncertainty.
    if (index % 2 === 0) delete item.observations[0].covariance;
    item.timestamp_us = String(9007199254740993n + BigInt(index) * 100000n);
  });
  records[6].observations[0].point = [3000, 3000];
  records[9].observations = [];
  return records;
}

const transforms = [
  {},
  { scale_x: 0.5, scale_y: 0.75, offset_x: -40, offset_y: 16 },
  { scale_x: 2, scale_y: 0.4, offset_x: 231.25, offset_y: -81.5 },
  { scale_x: 0.125, scale_y: 3.25, offset_x: -73.2, offset_y: 19.75 },
];

test("native and JavaScript converters preserve full measurements in all four runtime directions", (context) => {
  let convertedStreams = 0;
  let measurementDirections = 0;
  for (const source of [fixture(false), fixture(true)]) {
    const baseline = native("--stream", source);
    const originalMotion = native("--checkpoint", source)[0].motion;
    for (const transform of transforms) {
      const nativeConverted = nativeReframe(source, transform);
      const browserConverted = browserReframe(source, transform);
      closeNumeric(browserConverted, nativeConverted);
      for (const converted of [nativeConverted, browserConverted]) {
        closeNumeric(native("--stream", converted), baseline);
        closeNumeric(browserReplay(converted).measurements, baseline);
        closeNumeric(
          native("--checkpoint", converted)[0].motion,
          originalMotion,
        );
        closeNumeric(
          browserReplay(converted).checkpoint.motion,
          originalMotion,
        );
        measurementDirections += 2;
      }
      convertedStreams += 2;
    }
  }
  context.diagnostic(
    `${convertedStreams} converted streams; ${measurementDirections} native/JavaScript measurement directions`,
  );
});

test("native and JavaScript checkpoints keep exact metric state while future pixels change", (context) => {
  let preservedCheckpoints = 0;
  let continuedStreams = 0;
  for (const source of [fixture(false), fixture(true)]) {
    const baseline = native("--stream", source);
    for (const cut of [0, 3, 9, source.length - 1]) {
      const prefix = source.slice(0, cut + 1);
      const checkpoints = [
        native("--checkpoint", prefix)[0],
        browserReplay(prefix).checkpoint,
      ];
      for (const saved of checkpoints) {
        const records = [{ resume: saved }, ...source.slice(cut + 1)];
        for (const converted of [
          nativeReframe(records, transforms[1]),
          browserReframe(records, transforms[1]),
        ]) {
          assert.deepEqual(converted[0].resume.motion, saved.motion);
          assert.equal(
            converted[0].resume.configuration.session_id,
            source[0].session_id,
          );
          closeNumeric(native("--stream", converted), baseline.slice(cut));
          closeNumeric(
            browserReplay(converted).measurements,
            baseline.slice(cut),
          );
          preservedCheckpoints++;
          continuedStreams += 2;
        }
      }
    }
  }
  context.diagnostic(
    `${preservedCheckpoints} exactly preserved checkpoint headers; ${continuedStreams} resumed measurement streams`,
  );
});

test("inverse and composed pixel transforms retain correlated and implicit uncertainty", () => {
  const source = fixture(true);
  const baseline = native("--stream", source);
  const first = transforms[1];
  const second = transforms[2];
  const inverse = {
    scale_x: 1 / first.scale_x,
    scale_y: 1 / first.scale_y,
    offset_x: -first.offset_x / first.scale_x,
    offset_y: -first.offset_y / first.scale_y,
  };
  const combined = {
    scale_x: second.scale_x * first.scale_x,
    scale_y: second.scale_y * first.scale_y,
    offset_x: second.scale_x * first.offset_x + second.offset_x,
    offset_y: second.scale_y * first.offset_y + second.offset_y,
  };
  for (const convert of [nativeReframe, browserReframe]) {
    const firstResult = convert(source, first);
    assert.deepEqual(firstResult[1].observations[0].covariance, [1, 0, 2.25]);
    const old = source[2].observations[0].covariance;
    closeNumeric(firstResult[2].observations[0].covariance, [
      old[0] * first.scale_x ** 2,
      old[1] * first.scale_x * first.scale_y,
      old[2] * first.scale_y ** 2,
    ]);
    closeNumeric(native("--stream", convert(firstResult, inverse)), baseline);
    closeNumeric(
      native("--stream", convert(firstResult, second)),
      native("--stream", convert(source, combined)),
    );
  }
});

test("raw tokens and late malformed frames fail atomically without exposing converted prefixes", (context) => {
  const source = fixture(true).slice(0, 4);
  const text = ndjson(source);
  const failures = [
    {},
    { ndjson: text },
    { ndjson: text, transform: {}, ignored: true },
    { ndjson: "", transform: {} },
    { ndjson: "\n", transform: {} },
    { ndjson: text, transform: { rotation: 90 } },
    ...[0, -1, null, "1"].map((scale_x) => ({
      ndjson: text,
      transform: { scale_x },
    })),
    { ndjson: text, transform: { scale_y: 0 } },
    { ndjson: text, transform: { offset_x: "0" } },
    {
      ndjson: ndjson([{ session_id: "metres", mode: "ground" }]),
      transform: {},
    },
    { ndjson: text + "{\n", transform: {} },
    { ndjson: text + "\n", transform: {} },
    { ndjson: ndjson([source[0], source[1], source[1]]), transform: {} },
    {
      ndjson: text.replace('"track_id":7', '"track_id":7.0000000000000000001'),
      transform: {},
    },
    {
      ndjson: text.replace('"point":', '"point":[1,2],"point":'),
      transform: {},
    },
    {
      ndjson: text.replace('"session_id":', '"mode":"pixel","session_id":'),
      transform: {},
    },
    {
      ndjson: ndjson([{ ...source[0], ignored: true }, ...source.slice(1)]),
      transform: {},
    },
    {
      ndjson: ndjson([
        source[0],
        source[1],
        {
          timestamp_us: "9007199254840993",
          observations: [
            { track_id: 7, point: [200, 200] },
            { track_id: 8, point: [1e308, 1e308] },
          ],
        },
      ]),
      transform: { scale_x: 2 },
    },
  ];
  for (const request of failures)
    failure(moonground_reframe(JSON.stringify(request)));
  const raw = JSON.stringify({ ndjson: text, transform: { scale_x: 1 } });
  failure(
    moonground_reframe(raw.replace('"scale_x":1', '"scale_x":1,"scale_x":2')),
  );
  failure(moonground_reframe(raw.replace('"scale_x":1', '"scale_x":1e999')));
  failure(moonground_reframe(raw.replace('"scale_x":1', '"offset_x":1e999')));
  failure(moonground_reframe('{"ndjson":"",' + raw.slice(1)));
  closeNumeric(
    browserReframe(source, transforms[1]),
    nativeReframe(source, transforms[1]),
  );
  context.diagnostic(
    `${failures.length + 4} atomic raw-token/schema/frame rejections`,
  );
});

test("reframing is pure and succeeds at full live-handle capacity", () => {
  const records = fixture(true).slice(0, 3);
  const handles = [];
  try {
    for (let index = 0; index < 64; index++)
      handles.push(unpack(moonground_create(line(records[0]))).handle);
    failure(moonground_create(line(records[0])));
    const before = handles.map((handle) =>
      unpack(moonground_checkpoint(handle)),
    );
    browserReframe(records, transforms[2]);
    failure(
      moonground_reframe(
        JSON.stringify({ ndjson: ndjson(records) + "{\n", transform: {} }),
      ),
    );
    handles.forEach((handle, index) => {
      assert.deepEqual(unpack(moonground_checkpoint(handle)), before[index]);
      unpack(moonground_update(handle, line(records[1])));
    });
    failure(moonground_create(line(records[0])));
  } finally {
    handles.forEach((handle) => assert.equal(moonground_close(handle), true));
  }
  const { handle } = unpack(moonground_create(line(records[0])));
  assert.equal(moonground_close(handle), true);
});

test("bounded bundles accept 5000 frames, CRLF and final EOF; reject input and output expansion limits", (context) => {
  const config = fixture(false)[0];
  const frames = Array.from({ length: 5000 }, (_, index) => ({
    timestamp_us: String(index),
    observations: [],
  }));
  const text = ndjson([config, ...frames]);
  const full = unpack(
    moonground_reframe(JSON.stringify({ ndjson: text, transform: {} })),
  );
  assert.equal(full.frame_count, 5000);
  failure(
    moonground_reframe(
      JSON.stringify({
        ndjson:
          text +
          JSON.stringify({ timestamp_us: "5000", observations: [] }) +
          "\n",
        transform: {},
      }),
    ),
  );
  failure(
    moonground_reframe(
      JSON.stringify({ ndjson: " ".repeat(8388609), transform: {} }),
    ),
  );
  failure(moonground_reframe(" ".repeat(16777217)));
  const short = fixture(true).slice(0, 4);
  const canonical = browserReframe(short, transforms[2]);
  for (const source of [
    ndjson(short).trimEnd(),
    ndjson(short).replaceAll("\n", "\r\n"),
  ]) {
    closeNumeric(
      parseLines(
        unpack(
          moonground_reframe(
            JSON.stringify({ ndjson: source, transform: transforms[2] }),
          ),
        ).ndjson,
      ),
      canonical,
    );
  }
  // Long transformed decimal coordinates expand a small input line past the
  // 1 Mi-code-unit frame ceiling. The bundle must still return only an error.
  config.motion.max_tracks = 10000;
  const points = Array.from({ length: 10000 }, (_, index) => ({
    track_id: index + 1,
    point: [0.12345678901234567, 0.23456789012345678],
  }));
  const oversized = ndjson([
    config,
    { timestamp_us: "0", observations: points },
  ]);
  assert.ok(oversized.length < 1048576);
  assert.match(
    failure(
      moonground_reframe(
        JSON.stringify({
          ndjson: oversized,
          transform: {
            scale_x: 1.2345678901234567,
            scale_y: 1.2345678901234567,
          },
        }),
      ),
    ),
    /transformed frame exceeds 1048576/,
  );
  config.motion.max_tracks = 100;
  const repeated = Array.from({ length: 100 }, (_, index) => ({
    track_id: index + 1,
    point: [300, 200],
  }));
  const expanding = ndjson([
    config,
    ...Array.from({ length: 1000 }, (_, index) => ({
      timestamp_us: String(index),
      observations: repeated,
    })),
  ]);
  assert.ok(expanding.length < 8388608);
  assert.match(
    failure(
      moonground_reframe(
        JSON.stringify({
          ndjson: expanding,
          transform: {
            scale_x: 1.2345678901234567,
            scale_y: 1.2345678901234567,
          },
        }),
      ),
    ),
    /transformed NDJSON exceeds 8388608/,
  );
  context.diagnostic(
    "5000-frame exact boundary, 8 Mi input/output, 16 Mi request, 1 Mi transformed-frame expansion, CRLF and EOF",
  );
});
