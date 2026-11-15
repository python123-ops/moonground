import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  moonground_calibration_area,
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
assert.ok(binary, "Build the native release before area verification.");
const example = JSON.parse(
  readFileSync(path.join(root, "examples/calibration-area.json"), "utf8"),
);
const clone = (value) => JSON.parse(JSON.stringify(value));
const raw = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
function browser(value) {
  const result = JSON.parse(moonground_calibration_area(raw(value)));
  assert.equal(result.error, undefined, JSON.stringify(result));
  return result;
}
function failure(value) {
  const result = JSON.parse(moonground_calibration_area(raw(value)));
  assert.deepEqual(Object.keys(result), ["error"]);
  assert.equal(typeof result.error, "string");
  assert.equal(native(raw(value), 2).stdout, "");
}
function native(input, status = 0, extra = []) {
  const result = spawnSync(binary, ["--calibration-area", ...extra], {
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
const square = (x, y, s) => [
  [x, y],
  [x + s, y],
  [x + s, y + s],
  [x, y + s],
];
function perspectiveRequest() {
  const value = clone(example);
  value.calibration.matrix = [1, 0, 0, 0, 1, 0, 0, 0, 1];
  value.calibration.max_meters_per_pixel = 2;
  value.modes = [[0.125, 0, 0, 0, 0.125, 0, 0.015625, 0, 0]];
  value.comparisons = [
    {
      probe_id: "opposite-responses",
      first_polygon: square(0, 0, 4),
      second_polygon: square(8, 0, 4),
    },
  ];
  return value;
}

test("shared polygon areas and correlated contrasts agree across runtimes", () => {
  const result = browser(example),
    row = result.comparisons[0];
  assert.equal(result.kind, "calibration_area_comparison");
  assert.equal(
    result.evidence_scope,
    "first_order_shared_homography_area_contrasts",
  );
  assert.equal(row.first.area_m2, 8);
  assert.equal(row.second.area_m2, 32);
  assert.deepEqual(row.first.mode_responses_m2, [0, 2]);
  assert.equal(row.cross_contribution_m4, 16);
  assert.equal(row.difference_m2, -24);
  assert.equal(row.difference_std_m2, 6);
  assert.equal(row.ratio, 0.25);
  assert.equal(row.ratio_std, 0);
  assert.equal(result.comparisons[1].second.signed_area_m2, -16);
  for (const ending of ["", "\n", "\r\n"])
    close(JSON.parse(native(raw(example) + ending).stdout), result);
});

test("negative area covariance swap winding and reflection keep their units and meaning", () => {
  const value = perspectiveRequest(),
    row = browser(value).comparisons[0];
  assert.equal(row.first.mode_responses_m2[0], 2.5);
  assert.equal(row.second.mode_responses_m2[0], -3.5);
  assert.equal(row.cross_contribution_m4, -8.75);
  assert.equal(row.difference_contribution_m4, 36);
  assert.equal(row.ratio_mode_responses[0], 0.375);
  close(JSON.parse(native(raw(value)).stdout), browser(value));
  const probe = value.comparisons[0];
  [probe.first_polygon, probe.second_polygon] = [
    probe.second_polygon,
    probe.first_polygon,
  ];
  assert.equal(browser(value).comparisons[0].ratio_mode_responses[0], -0.375);
  probe.first_polygon.reverse();
  assert.equal(browser(value).comparisons[0].first.signed_area_m2, -16);
  assert.equal(browser(value).comparisons[0].first.mode_responses_m2[0], -3.5);
  value.calibration.matrix[0] = -1;
  value.modes = [];
  assert.equal(browser(value).comparisons[0].first.signed_area_m2, 16);
  close(JSON.parse(native(raw(value)).stdout), browser(value));
});

test("zero rank empty requests gauge translation rotation and large origins remain explicit", () => {
  const value = perspectiveRequest();
  value.modes = [
    [0, 0, 1e100, 0, 0, -1e100, 0, 0, 0],
    [0, -0.125, 0, 0.125, 0, 0, 0, 0, 0],
    [0.125, 0, 0, 0, 0.125, 0, 0, 0, 0.125],
  ];
  const row = browser(value).comparisons[0];
  assert.deepEqual(row.first.mode_responses_m2, [0, 0, 0]);
  value.calibration.roi = square(0, 0, 1e12 + 16);
  value.comparisons[0].first_polygon = square(1e12, 1e12, 4);
  value.comparisons[0].second_polygon = square(1e12, 1e12, 8);
  value.modes = [[0, 0, 1, 0, 0, 2, 0, 0, 0]];
  assert.equal(browser(value).comparisons[0].first.area_m2, 16);
  close(JSON.parse(native(raw(value)).stdout), browser(value));
  value.modes = [];
  assert.deepEqual(browser(value).comparisons[0].ratio_mode_responses, []);
  value.comparisons = [];
  assert.deepEqual(browser(value).comparisons, []);
});

test("strict parser rejects unknown duplicate deeply nested and unrepresentable tokens", () => {
  const text = raw(example);
  for (const bad of [
    '{"calibration":{},"calibration":{}}',
    text.replace('"comparisons"', '"camera"'),
    text.replace('"first_polygon"', '"first_segment"'),
    text.replace("0.015625", "1e400"),
    text.replace("0.015625", "1e-400"),
    text.replace("0.015625", '"0.015625"'),
    "[".repeat(33) + "0" + "]".repeat(33),
    " ".repeat(1048577),
  ])
    failure(bad);
  assert.equal(browser(example).comparisons[0].ratio, 0.25);
});

test("maximum 32 modes 64 comparisons and 64 vertices have complete bounded results", (t) => {
  const value = clone(example);
  const polygon = Array.from({ length: 64 }, (_, i) => [
    50 + 30 * Math.cos((i * Math.PI) / 32),
    50 + 30 * Math.sin((i * Math.PI) / 32),
  ]);
  value.modes = Array(32).fill(example.modes[1]);
  value.comparisons = Array.from({ length: 64 }, (_, i) => ({
    probe_id: `area-${i}`,
    first_polygon: polygon,
    second_polygon: polygon,
  }));
  const result = browser(value);
  assert.equal(result.comparisons.length, 64);
  assert.equal(result.comparisons[63].first.positions_m.length, 64);
  assert.equal(result.comparisons[63].ratio_mode_responses.length, 32);
  assert.equal(result.comparisons[63].ratio_contribution, 0);
  close(JSON.parse(native(raw(value)).stdout), result);
  t.diagnostic(
    JSON.stringify({
      maximum_modes: 32,
      maximum_comparisons: 64,
      maximum_vertices: 64,
      mode_vertex_evaluations: 262144,
      output_utf16: moonground_calibration_area(raw(value)).length,
    }),
  );
  for (const mutate of [
    (x) => x.modes.push(example.modes[0]),
    (x) => x.comparisons.push({ ...x.comparisons[0], probe_id: "65" }),
    (x) => (x.comparisons[63].probe_id = "area-0"),
    (x) => (x.comparisons[63].probe_id = ""),
    (x) => (x.comparisons[63].probe_id = "x".repeat(129)),
    (x) => x.comparisons[63].first_polygon.push([50, 50]),
  ]) {
    const bad = clone(value);
    mutate(bad);
    failure(bad);
  }
});

test("late invalid topology ROI and represented ground collapse reject the whole request", () => {
  for (const polygon of [
    [],
    [
      [0, 0],
      [1, 0],
    ],
    [
      [0, 0],
      [4, 0],
      [0, 4],
      [0, 0],
    ],
    [
      [0, 0],
      [4, 4],
      [0, 4],
      [4, 0],
    ],
    [
      [0, 0],
      [4, 0],
      [1, 1],
      [0, 4],
    ],
    [
      [0, 0],
      [1, 0],
      [2, 0],
    ],
    [
      [0, 0],
      [101, 0],
      [0, 4],
    ],
    [
      [0, 0],
      [1, 0],
      [0, 1e-12],
    ],
  ]) {
    const value = clone(example);
    value.comparisons[1].second_polygon = polygon;
    failure(value);
  }
  const rounded = perspectiveRequest();
  rounded.modes = [];
  rounded.calibration.matrix = [1, 0, 1e16, 0, 1, 1e16, 0, 0, 1];
  rounded.comparisons[0].first_polygon = [
    [0, 0],
    [1, 0],
    [0, 1],
  ];
  failure(rounded);
});

test("finite half area survives doubled overflow and unrepresentable ratios and moments reject", () => {
  const value = perspectiveRequest();
  value.modes = [];
  value.calibration.roi = square(0, 0, 1.5e154);
  const huge = [
      [0, 0],
      [1.5e154, 0],
      [0, 1.5e154],
    ],
    tiny = [
      [0, 0],
      [1e-150, 0],
      [0, 1e-150],
    ];
  value.comparisons[0].first_polygon = huge;
  value.comparisons[0].second_polygon = huge;
  close(browser(value).comparisons[0].first.area_m2 / 1.125e308, 1);
  close(JSON.parse(native(raw(value)).stdout), browser(value));
  value.comparisons[0].second_polygon = tiny;
  failure(value);
  value.comparisons[0].first_polygon = tiny;
  value.comparisons[0].second_polygon = huge;
  failure(value);
  const late = perspectiveRequest();
  late.modes[0] = late.modes[0].map((x) => x * 3.2e153);
  failure(late);
});

test("one-shot framing and existing position distance and angle bridges retain their behavior", () => {
  const text = raw(example);
  assert.equal(native(text + "\n{}\n", 2).stdout, native(text).stdout);
  assert.equal(native("", 2).stdout, "");
  assert.equal(native(text, 2, ["--max-line-bytes", "16777216"]).stdout, "");
  for (const [name, fn, kind] of [
    [
      "calibration-sensitivity",
      moonground_calibration_sensitivity,
      "calibration_sensitivity",
    ],
    [
      "calibration-distance",
      moonground_calibration_distance,
      "calibration_distance_comparison",
    ],
    [
      "calibration-angle",
      moonground_calibration_angle,
      "calibration_angle_comparison",
    ],
  ])
    assert.equal(
      JSON.parse(
        fn(readFileSync(path.join(root, `examples/${name}.json`), "utf8")),
      ).kind,
      kind,
    );
});
