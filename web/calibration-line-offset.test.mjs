import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { moonground_calibration_line_offset } from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.env.MOONGROUND_CLI
  ? path.resolve(root, process.env.MOONGROUND_CLI)
  : ["main.exe", "main"]
      .map((name) =>
        path.join(root, "_build/native/release/build/cmd/main", name),
      )
      .find(existsSync);
assert.ok(binary, "Build the native release before line offset verification.");
const example = JSON.parse(
  readFileSync(
    path.join(root, "examples/calibration-line-offset.json"),
    "utf8",
  ),
);
const clone = (value) => JSON.parse(JSON.stringify(value));
const raw = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
function native(input, status = 0, extra = []) {
  const result = spawnSync(binary, ["--calibration-line-offset", ...extra], {
    input,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    timeout: 30000,
  });
  assert.equal(result.status, status, result.stderr || result.error?.message);
  if (!status) assert.equal(result.stderr, "");
  return result;
}
function browser(value) {
  const report = JSON.parse(moonground_calibration_line_offset(raw(value)));
  assert.equal(report.error, undefined, JSON.stringify(report));
  return report;
}
function failure(value) {
  const report = JSON.parse(moonground_calibration_line_offset(raw(value)));
  assert.deepEqual(Object.keys(report), ["error"]);
  assert.equal(typeof report.error, "string");
  assert.equal(native(raw(value), 2).stdout, "");
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

test("common line and point modes retain signed offsets and negative cross contribution", () => {
  const report = browser(example),
    row = report.comparisons[0];
  assert.equal(report.kind, "calibration_line_offset_comparison");
  assert.equal(
    report.evidence_scope,
    "first_order_shared_homography_line_offsets",
  );
  assert.equal(row.first.signed_offset_m, 3);
  assert.equal(row.second.signed_offset_m, -2);
  assert.deepEqual(row.first.mode_responses_m, [0, 0.375]);
  assert.equal(row.cross_contribution_m2, -0.09375);
  assert.equal(row.difference_m, 5);
  assert.equal(row.difference_std_m, 0.625);
  assert.equal(report.comparisons[1].first.signed_offset_m, 0);
  assert.equal(report.comparisons[1].difference_std_m, 0);
  for (const ending of ["", "\n", "\r\n"])
    close(JSON.parse(native(raw(example) + ending).stdout), report);
});

test("reversing the line changes signed means and responses and keeps covariance", () => {
  const request = clone(example),
    original = browser(request).comparisons[0];
  for (const row of request.comparisons)
    [row.line_start, row.line_end] = [row.line_end, row.line_start];
  const reversed = browser(request).comparisons[0];
  assert.equal(reversed.first.signed_offset_m, -original.first.signed_offset_m);
  assert.deepEqual(
    reversed.difference_mode_responses_m,
    original.difference_mode_responses_m.map((x) => (x === 0 ? 0 : -x)),
  );
  assert.equal(reversed.cross_contribution_m2, original.cross_contribution_m2);
  close(JSON.parse(native(raw(request)).stdout), browser(request));
});

test("strict raw numbers keys and all reference and probe pixels reject atomically", () => {
  const text = raw(example);
  for (const bad of [
    '{"comparisons":[],"comparisons":[]}',
    text.replace('"comparisons":', '"camera":'),
    text.replace("0.125", "1e400"),
    text.replace("0.125", "1e-400"),
    text.replace("0.125", '"0.125"'),
  ])
    failure(bad);
  for (const key of ["line_start", "line_end", "first_pixel", "second_pixel"]) {
    const request = clone(example);
    request.comparisons[1][key] = [-1, 0];
    failure(request);
  }
  for (const mutate of [
    (r) => {
      r.comparisons[1].line_end = r.comparisons[1].line_start;
    },
    (r) => {
      r.comparisons[1].probe_id = r.comparisons[0].probe_id;
    },
    (r) => {
      r.comparisons[1].probe_id = "";
    },
    (r) => {
      r.comparisons[1].line_start = [1, 2, 3];
    },
    (r) => {
      r.comparisons[1].unknown = 2;
    },
  ]) {
    const request = clone(example);
    mutate(request);
    failure(request);
  }
  close(JSON.parse(native(text).stdout), browser(example));
});

test("maximum ordered modes and comparisons retain response order across runtimes", () => {
  const request = clone(example);
  request.modes = Array.from({ length: 32 }, (_, i) => example.modes[i % 2]);
  request.comparisons = Array.from({ length: 256 }, (_, i) => ({
    ...example.comparisons[0],
    probe_id: `probe-${i}`,
  }));
  const report = browser(request);
  assert.equal(report.comparisons.length, 256);
  assert.equal(report.comparisons[0].first.mode_responses_m.length, 32);
  close(JSON.parse(native(raw(request)).stdout), report);
  const tooMany = clone(request);
  tooMany.comparisons.push({ ...tooMany.comparisons[0], probe_id: "extra" });
  failure(tooMany);
  request.modes.push(example.modes[0]);
  failure(request);
  const empty = clone(example);
  empty.modes = [];
  empty.comparisons = [];
  assert.deepEqual(browser(empty).comparisons, []);
});

test("one-shot line offset command preserves successful line before extra-input rejection", () => {
  const text = raw(example),
    expected = browser(example);
  const extra = native(text + "\n{}\n", 2);
  close(JSON.parse(extra.stdout), expected);
  native(text, 2, ["--max-line-bytes", "2097152"]);
  failure(" ".repeat(1048576) + text);
  failure("\ufeff" + text);
});
