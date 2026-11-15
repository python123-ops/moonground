import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  moonground_calibration_angle,
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
assert.ok(binary, "Build the native release before angle verification.");
const example = JSON.parse(
  readFileSync(path.join(root, "examples/calibration-angle.json"), "utf8"),
);
const clone = (value) => JSON.parse(JSON.stringify(value));
const raw = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
function browser(value) {
  const result = JSON.parse(moonground_calibration_angle(raw(value)));
  assert.equal(result.error, undefined, JSON.stringify(result));
  return result;
}
function failure(value) {
  const result = JSON.parse(moonground_calibration_angle(raw(value)));
  assert.deepEqual(Object.keys(result), ["error"]);
  assert.equal(typeof result.error, "string");
  assert.equal(native(raw(value), 2).stdout, "");
}
function native(input, status = 0, extra = []) {
  const result = spawnSync(binary, ["--calibration-angle", ...extra], {
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
    expected.forEach((value, index) => close(actual[index], value));
  } else if (expected && typeof expected === "object") {
    assert.deepEqual(Object.keys(actual).sort(), Object.keys(expected).sort());
    for (const key of Object.keys(expected)) close(actual[key], expected[key]);
  } else assert.equal(actual, expected);
}
function shearRequest() {
  const value = clone(example);
  value.calibration.matrix = [1, 0, 0, 0, 1, 0, 0, 0, 1];
  value.calibration.max_meters_per_pixel = 2;
  value.modes = [[0, 0.125, 0, 0.125, 0, 0, 0, 0, 0]];
  value.comparisons = [
    {
      probe_id: "opposite-responses",
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
  return value;
}

test("shared ground directions and angle tangents agree across runtimes", () => {
  const result = browser(example),
    pair = result.comparisons[0];
  assert.equal(result.kind, "calibration_angle_comparison");
  assert.equal(
    result.evidence_scope,
    "first_order_shared_homography_angular_tangents",
  );
  assert.equal(result.angle_convention, "second_relative_to_first_ccw");
  assert.deepEqual(pair.first.mode_responses_rad, [0.125, 0, 0]);
  assert.equal(pair.first.std_rad, 0.125);
  assert.equal(pair.cross_contribution_rad2, 0.015625);
  assert.equal(pair.std_rad, 0);
  close(pair.angle_rad, Math.atan2(3, 4));
  assert.equal(result.comparisons[1].angle_rad, Math.PI);
  close(JSON.parse(native(raw(example)).stdout), result);
});

test("negative correlation swap and endpoint reversal retain directed angle semantics", () => {
  const value = shearRequest(),
    row = browser(value).comparisons[0];
  assert.equal(row.cross_contribution_rad2, -0.015625);
  assert.deepEqual(row.mode_responses_rad, [-0.25]);
  assert.equal(row.contribution_rad2, 0.0625);
  assert.equal(row.angle_rad, Math.PI / 2);
  close(JSON.parse(native(raw(value)).stdout), browser(value));
  const probe = value.comparisons[0];
  [probe.first_segment, probe.second_segment] = [
    probe.second_segment,
    probe.first_segment,
  ];
  const swapped = browser(value).comparisons[0];
  assert.equal(swapped.angle_rad, -row.angle_rad);
  assert.equal(swapped.mode_responses_rad[0], -row.mode_responses_rad[0]);
  probe.first_segment.reverse();
  const reversed = browser(value).comparisons[0];
  assert.equal(reversed.angle_rad, row.angle_rad);
  assert.deepEqual(
    reversed.first.mode_responses_rad,
    swapped.first.mode_responses_rad,
  );
});

test("canonical branch cut uses circular local responses and retains a tiny relative angle", () => {
  const value = shearRequest();
  value.modes = [[0, 0, 0, 0, 0, 0, 0.001, 0, 0]];
  value.comparisons = [
    {
      probe_id: "cut",
      first_segment: [
        [0, 0],
        [4, 0],
      ],
      second_segment: [
        [10, 10],
        [6, 10],
      ],
    },
  ];
  const cut = browser(value).comparisons[0];
  assert.equal(cut.angle_rad, Math.PI);
  close(cut.mode_responses_rad[0], -0.01);
  assert.ok(cut.std_rad > 0);
  close(JSON.parse(native(raw(value)).stdout), browser(value));
  value.modes = [];
  value.comparisons[0] = {
    probe_id: "near-parallel",
    first_segment: [
      [0, 0],
      [4, 3],
    ],
    second_segment: [
      [0, 0],
      [8, 6.000000000000001],
    ],
  };
  const small = browser(value).comparisons[0];
  assert.ok(small.angle_rad > 0 && small.angle_rad < 1e-15);
  assert.equal(small.std_rad, 0);
  close(JSON.parse(native(raw(value)).stdout), browser(value));
});

test("LF CRLF EOF and UTF-8 chunk boundaries preserve the strict single request", () => {
  const value = clone(example);
  value.comparisons[0].probe_id = "道路夹角🌙";
  for (const ending of ["\n", "\r\n", ""])
    close(JSON.parse(native(raw(value) + ending).stdout), browser(value));
  close(
    JSON.parse(native(" ".repeat(8191) + raw(value) + " ".repeat(8193)).stdout),
    browser(value),
  );
});

test("raw duplicates unknown tokens numeric underflow and resource limits reject atomically", () => {
  const text = raw(example);
  for (const bad of [
    '{"comparisons":[],"comparisons":[]}',
    text.replace('"comparisons":', '"camera":'),
    text.replace('"first_segment":', '"first_pixel":'),
    text.replace(
      '"probe_id":"common-rotation"',
      '"probe_id":"common-rotation","probe_id":"duplicate"',
    ),
    text.replace("0.015625", "1e400"),
    text.replace("0.015625", "1e-400"),
    text.replace("0.015625", '"0.015625"'),
    '{"nested":' + "[".repeat(33) + "0" + "]".repeat(33) + "}",
    " ".repeat(1048577) + text,
  ])
    failure(bad);
});

test("32 modes and 256 comparisons work and late segment failures return no prefix", (t) => {
  const value = clone(example);
  value.modes = Array.from({ length: 32 }, () => example.modes[0]);
  value.comparisons = Array.from({ length: 256 }, (_, i) => ({
    ...example.comparisons[0],
    probe_id: `angle-${i}`,
  }));
  const result = browser(value);
  assert.equal(result.comparisons.length, 256);
  assert.equal(result.comparisons[255].mode_responses_rad.length, 32);
  close(JSON.parse(native(raw(value)).stdout), result);
  t.diagnostic(
    JSON.stringify({
      maximum_modes: 32,
      maximum_comparisons: 256,
      scalar_mode_responses: 24576,
      output_utf16: moonground_calibration_angle(raw(value)).length,
    }),
  );
  for (const mutate of [
    (x) => x.modes.push(example.modes[0]),
    (x) => x.comparisons.push({ ...example.comparisons[0], probe_id: "257" }),
    (x) => (x.comparisons[255].probe_id = "angle-0"),
    (x) => (x.comparisons[255].probe_id = ""),
    (x) => (x.comparisons[255].probe_id = "x".repeat(129)),
    (x) =>
      (x.comparisons[255].second_segment = [
        [0, 0],
        [0, 0],
      ]),
    (x) =>
      (x.comparisons[255].second_segment = [
        [0, 0],
        [101, 0],
      ]),
    (x) => (x.comparisons[255].first_segment = [[0, 0]]),
  ]) {
    const bad = clone(value);
    mutate(bad);
    failure(bad);
  }
});

test("degenerate represented endpoints and unsupported angular arithmetic reject explicitly", () => {
  const rounded = shearRequest();
  rounded.modes = [];
  rounded.calibration.matrix = [1, 0, 1e16, 0, 1, 1e16, 0, 0, 1];
  rounded.comparisons[0].first_segment = [
    [0, 0],
    [1, 0],
  ];
  failure(rounded);
  const late = shearRequest();
  late.modes = [[0, 1e154, 0, 1e154, 0, 0, 0, 0, 0]];
  late.comparisons[0].first_segment = [
    [0, 0],
    [1, 0],
  ];
  late.comparisons[0].second_segment = [
    [0, 0],
    [0, 1],
  ];
  failure(late);
  const overflow = shearRequest();
  overflow.modes = [[0, 0, 0, 1e200, 0, 0, 0, 0, 0]];
  overflow.comparisons[0].first_segment = [
    [0, 0],
    [1e-200, 0],
  ];
  failure(overflow);
  assert.equal(browser(example).comparisons[0].std_rad, 0);
});

test("single request CLI framing and the prior point and distance APIs retain their behavior", () => {
  const text = raw(example);
  assert.equal(native(text + "\n{}\n", 2).stdout, native(text).stdout);
  assert.equal(native("", 2).stdout, "");
  assert.equal(native(text, 2, ["--max-line-bytes", "16777216"]).stdout, "");
  const points = readFileSync(
    path.join(root, "examples/calibration-sensitivity.json"),
    "utf8",
  );
  const lengths = readFileSync(
    path.join(root, "examples/calibration-distance.json"),
    "utf8",
  );
  assert.equal(
    JSON.parse(moonground_calibration_sensitivity(points)).kind,
    "calibration_sensitivity",
  );
  assert.equal(
    JSON.parse(moonground_calibration_distance(lengths)).comparisons[0].ratio,
    0.5,
  );
});
