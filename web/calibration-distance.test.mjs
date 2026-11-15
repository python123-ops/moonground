import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  moonground_calibration_distance,
  moonground_calibration_sensitivity,
} from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.env.MOONGROUND_CLI
  ? path.resolve(root, process.env.MOONGROUND_CLI)
  : ["main.exe", "main"]
      .map((name) =>
        path.join(root, "_build/native/release/build/cmd/main", name),
      )
      .find(existsSync);
assert.ok(binary, "Build the native release before distance verification.");
const example = JSON.parse(
  readFileSync(path.join(root, "examples/calibration-distance.json"), "utf8"),
);
const clone = (value) => JSON.parse(JSON.stringify(value));
const raw = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
function browser(value) {
  const result = JSON.parse(moonground_calibration_distance(raw(value)));
  assert.equal(result.error, undefined, JSON.stringify(result));
  return result;
}
function failure(value) {
  const result = JSON.parse(moonground_calibration_distance(raw(value)));
  assert.deepEqual(Object.keys(result), ["error"]);
  assert.equal(typeof result.error, "string");
}
function native(input, status = 0, extra = []) {
  const result = spawnSync(binary, ["--calibration-distance", ...extra], {
    input,
    encoding: "utf8",
    timeout: 30000,
    maxBuffer: 16 * 1024 * 1024,
  });
  assert.equal(result.status, status, result.stderr || result.error?.message);
  if (!status) assert.equal(result.stderr, "");
  return result;
}
function close(actual, expected) {
  if (typeof expected === "number") {
    assert.ok(Number.isFinite(actual));
    assert.ok(
      Math.abs(actual - expected) <= 3e-12 * Math.max(1, Math.abs(expected)),
      `${actual} != ${expected}`,
    );
  } else if (Array.isArray(expected)) {
    assert.equal(actual.length, expected.length);
    expected.forEach((value, i) => close(actual[i], value));
  } else if (expected && typeof expected === "object") {
    assert.deepEqual(Object.keys(actual).sort(), Object.keys(expected).sort());
    for (const key of Object.keys(expected)) close(actual[key], expected[key]);
  } else assert.equal(actual, expected);
}

test("shared calibration lengths differences and ratios agree across runtimes", () => {
  const result = browser(example),
    pair = result.comparisons[0];
  assert.equal(result.kind, "calibration_distance_comparison");
  assert.equal(
    result.evidence_scope,
    "first_order_shared_homography_distance_contrasts",
  );
  assert.equal(pair.first.distance_m, 5);
  assert.equal(pair.second.distance_m, 10);
  assert.equal(pair.cross_contribution_m2, 0.78125);
  assert.equal(pair.difference_contribution_m2, 0.390625);
  assert.equal(pair.ratio, 0.5);
  assert.equal(pair.ratio_std, 0);
  assert.equal(result.comparisons[1].difference_std_m, 0);
  assert.equal(result.comparisons[1].ratio, 1);
  close(JSON.parse(native(raw(example) + "\n").stdout), result);
});

test("negative cross contribution and endpoint reversal retain the shared mode dependence", () => {
  const value = clone(example);
  value.calibration.matrix = [1, 0, 0, 0, 1, 0, 0, 0, 1];
  value.calibration.max_meters_per_pixel = 2;
  value.modes = [[0.25, 0, 0, 0, -0.125, 0, 0, 0, 0]];
  value.comparisons = [
    {
      probe_id: "opposite",
      first_segment: [
        [0, 0],
        [4, 0],
      ],
      second_segment: [
        [0, 0],
        [0, 8],
      ],
    },
  ];
  const result = browser(value).comparisons[0];
  assert.equal(result.cross_contribution_m2, -1);
  assert.equal(result.difference_contribution_m2, 4);
  assert.equal(result.ratio_contribution, 0.03515625);
  close(JSON.parse(native(raw(value)).stdout), browser(value));
  value.comparisons[0].first_segment.reverse();
  assert.deepEqual(
    browser(value).comparisons[0].first.mode_responses_m,
    result.first.mode_responses_m,
  );
  const first = value.comparisons[0].first_segment;
  value.comparisons[0].first_segment = value.comparisons[0].second_segment;
  value.comparisons[0].second_segment = first;
  const reverse = browser(value).comparisons[0];
  assert.equal(reverse.difference_m, -result.difference_m);
  assert.equal(reverse.ratio, 1 / result.ratio);
});

test("LF CRLF EOF and original UTF-8 request chunk boundaries stay strict", () => {
  const value = clone(example);
  value.comparisons[0].probe_id = "长度比较🌙";
  const text = raw(value);
  for (const ending of ["\n", "\r\n", ""])
    close(JSON.parse(native(text + ending).stdout), browser(value));
  close(
    JSON.parse(native(" ".repeat(8191) + text + " ".repeat(8193)).stdout),
    browser(value),
  );
});

test("raw duplicates unknown fields nonfinite underflowing and oversized documents fail as a whole", () => {
  const text = raw(example);
  for (const bad of [
    '{"comparisons":[],"comparisons":[]}',
    text.replace('"comparisons":', '"camera":'),
    text.replace('"first_segment":', '"first_pixel":'),
    text.replace("0.015625", "1e400"),
    text.replace("0.015625", "1e-400"),
    text.replace("0.015625", '"0.015625"'),
    text.replace(
      '"first_segment":[[0,0],[24,32]]',
      '"first_segment":[[0,0],[24,32]],"first_segment":[[0,0],[24,32]]',
    ),
    '{"nested":' + "[".repeat(33) + "0" + "]".repeat(33) + "}",
    " ".repeat(1048577) + text,
  ]) {
    failure(bad);
    assert.equal(native(bad, 2).stdout, "");
  }
});

test("32 modes and 256 comparisons are usable and malformed late segments are atomic", (t) => {
  const value = clone(example);
  value.modes = Array.from({ length: 32 }, () => example.modes[1]);
  value.comparisons = Array.from({ length: 256 }, (_, i) => ({
    ...example.comparisons[0],
    probe_id: `pair-${i}`,
  }));
  const result = browser(value);
  assert.equal(result.comparisons.length, 256);
  assert.equal(result.comparisons[255].ratio_mode_responses.length, 32);
  close(JSON.parse(native(raw(value)).stdout), result);
  t.diagnostic(
    JSON.stringify({
      maximum_modes: 32,
      maximum_comparisons: 256,
      scalar_mode_responses: 32768,
      output_utf16: moonground_calibration_distance(raw(value)).length,
    }),
  );
  for (const mutate of [
    (x) => x.modes.push(example.modes[0]),
    (x) => x.comparisons.push({ ...example.comparisons[0], probe_id: "257" }),
    (x) => {
      x.comparisons[255].probe_id = "pair-0";
    },
    (x) => {
      x.comparisons[255].second_segment = [
        [0, 0],
        [0, 0],
      ];
    },
    (x) => {
      x.comparisons[255].second_segment = [
        [0, 0],
        [101, 0],
      ];
    },
    (x) => {
      x.comparisons[255].first_segment = [[0, 0]];
    },
    (x) => {
      x.comparisons[255].first_segment = [
        [0, 0],
        [1, 0],
        [2, 0],
      ];
    },
    (x) => {
      x.modes[0] = [1, 2];
    },
    (x) => {
      x.comparisons[255].probe_id = "x".repeat(129);
    },
    (x) => {
      x.comparisons[255].probe_id = "";
    },
  ]) {
    const bad = clone(value);
    mutate(bad);
    failure(bad);
    assert.equal(native(raw(bad), 2).stdout, "");
  }
});

test("zero rank is valid but coincident anchors and unrepresentable ratios remain errors", () => {
  const empty = clone(example);
  empty.modes = [];
  assert.equal(browser(empty).comparisons[0].first.std_m, 0);
  assert.deepEqual(browser(empty).comparisons[0].ratio_mode_responses, []);
  empty.comparisons = [];
  assert.deepEqual(browser(empty).comparisons, []);
  const huge = clone(example);
  huge.calibration = {
    matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
    roi: [
      [0, 0],
      [1e200, 0],
      [1e200, 1e200],
      [0, 1e200],
    ],
    max_meters_per_pixel: 2,
  };
  huge.modes = [];
  for (const [a, b] of [
    [1e200, 1e-200],
    [1e-200, 1e200],
    [1, 0],
  ]) {
    huge.comparisons = [
      {
        probe_id: "invalid",
        first_segment: [
          [0, 0],
          [a, 0],
        ],
        second_segment: [
          [0, 0],
          [b, 0],
        ],
      },
    ];
    failure(huge);
    assert.equal(native(raw(huge), 2).stdout, "");
  }
  const stable = browser(example);
  assert.deepEqual(browser(example), stable);
});

test("one-shot CLI framing and original point sensitivity protocol retain their contracts", () => {
  const text = raw(example),
    result = native(text + "\n" + text + "\n", 2);
  close(JSON.parse(result.stdout), browser(example));
  assert.match(result.stderr, /exactly one line/);
  assert.equal(native("", 2).stdout, "");
  assert.equal(native(Buffer.from([0xc3, 0x28]), 2).stdout, "");
  assert.equal(native(text, 2, ["--max-line-bytes", "2000000"]).stdout, "");
  const old = readFileSync(
    path.join(root, "examples/calibration-sensitivity.json"),
    "utf8",
  );
  const before = moonground_calibration_sensitivity(old);
  browser(example);
  failure({});
  assert.equal(moonground_calibration_sensitivity(old), before);
});
