import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { moonground_calibration_sensitivity } from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.env.MOONGROUND_CLI
  ? path.resolve(root, process.env.MOONGROUND_CLI)
  : ["main.exe", "main"]
      .map((name) =>
        path.join(root, "_build/native/release/build/cmd/main", name),
      )
      .find(existsSync);
assert.ok(binary, "Build the native release before sensitivity verification.");
const example = JSON.parse(
  readFileSync(
    path.join(root, "examples/calibration-sensitivity.json"),
    "utf8",
  ),
);
const clone = (value) => JSON.parse(JSON.stringify(value));
const raw = (value) =>
  typeof value === "string" ? value : JSON.stringify(value);
function browser(value) {
  const result = JSON.parse(moonground_calibration_sensitivity(raw(value)));
  assert.equal(result.error, undefined, JSON.stringify(result));
  return result;
}
function failure(value) {
  const result = JSON.parse(moonground_calibration_sensitivity(raw(value)));
  assert.deepEqual(Object.keys(result), ["error"]);
  assert.equal(typeof result.error, "string");
}
function native(input, status = 0, extra = []) {
  const result = spawnSync(binary, ["--calibration-sensitivity", ...extra], {
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

test("shared homography modes preserve single-point and relative contributions across runtimes", () => {
  const result = browser(example);
  assert.equal(
    result.evidence_scope,
    "first_order_shared_homography_parameters",
  );
  assert.equal(result.mode_count, 2);
  close(
    result.probes[0].displacement_contribution_m2,
    [0.0036, 0.0024, 0.0016],
  );
  assert.deepEqual(result.probes[1].displacement_contribution_m2, [0, 0, 0]);
  close(JSON.parse(native(raw(example) + "\n").stdout), result);
  assert.deepEqual(browser(example), result);
});

test("LF CRLF EOF and multiple UTF-8 chunk boundaries use the same stateless request", () => {
  const value = clone(example);
  value.probes[0].probe_id = "共享误差🌙";
  const text = raw(value);
  for (const ending of ["\n", "\r\n", ""]) {
    close(JSON.parse(native(text + ending).stdout), browser(value));
  }
  const padded = " ".repeat(8191) + text + " ".repeat(8193);
  close(JSON.parse(native(padded).stdout), browser(value));
});

test("duplicate unknown nonfinite and underflowing raw fields fail before returning a batch", () => {
  const text = raw(example);
  const bad = [
    '{"modes":[],"modes":[]}',
    text.replace('"modes":', '"camera":'),
    text.replace('"first_pixel":', '"point":'),
    text.replace("0.25", "1e400"),
    text.replace("0.25", "1e-400"),
    text.replace("0.25", '"0.25"'),
    text.replace(
      '"first_pixel":[20,20]',
      '"first_pixel":[20,20],"first_pixel":[20,20]',
    ),
    '{"nested":' + "[".repeat(33) + "0" + "]".repeat(33) + "}",
    " ".repeat(1048577) + text,
  ];
  for (const source of bad) {
    failure(source);
    assert.equal(native(source, 2).stdout, "");
  }
  assert.deepEqual(browser(example), browser(example));
});

test("mode and probe capacities include their maximum and reject malformed pairs atomically", (t) => {
  const value = clone(example);
  value.modes = Array.from({ length: 32 }, () => example.modes[0]);
  value.probes = Array.from({ length: 256 }, (_, i) => ({
    ...example.probes[0],
    probe_id: `pair-${i}`,
  }));
  const result = browser(value);
  assert.equal(result.probes.length, 256);
  assert.equal(result.probes[255].first.mode_responses_m.length, 32);
  close(JSON.parse(native(raw(value)).stdout), result);
  t.diagnostic(
    JSON.stringify({
      maximum_modes: 32,
      maximum_probes: 256,
      mode_responses: 16384,
      output_utf16: JSON.stringify(result).length,
    }),
  );
  for (const mutate of [
    (x) => x.modes.push(example.modes[0]),
    (x) => x.probes.push({ ...example.probes[0], probe_id: "257" }),
    (x) => {
      x.probes[255].probe_id = "pair-0";
    },
    (x) => {
      x.probes[255].second_pixel = [101, 100];
    },
    (x) => {
      x.modes[0] = [1, 2];
    },
    (x) => {
      x.probes[255].probe_id = "x".repeat(129);
    },
    (x) => {
      x.probes[255].probe_id = "";
    },
  ]) {
    const bad = clone(value);
    mutate(bad);
    failure(bad);
    assert.equal(native(raw(bad), 2).stdout, "");
  }
});

test("zero rank singular repeated and huge shared translation do not invent relative variance", () => {
  for (const modes of [
    [],
    [[0, 0, 0, 0, 0, 0, 0, 0, 0]],
    [[0, 0, 1e100, 0, 0, 2e100, 0, 0, 0]],
  ]) {
    const value = clone(example);
    value.modes = modes;
    const result = browser(value);
    for (const probe of result.probes)
      assert.deepEqual(probe.displacement_contribution_m2, [0, 0, 0]);
    close(JSON.parse(native(raw(value)).stdout), result);
  }
  for (const amplitude of [1e200, 1e-200]) {
    const value = clone(example);
    value.modes = [[0, 0, amplitude, 0, 0, 0, 0, 0, 0]];
    failure(value);
    assert.equal(native(raw(value), 2).stdout, "");
  }
});

test("one-shot command rejects extra requests invalid UTF-8 and stream-only options", () => {
  const text = raw(example);
  const result = native(text + "\n" + text + "\n", 2);
  close(JSON.parse(result.stdout), browser(example));
  assert.match(result.stderr, /exactly one line/);
  assert.equal(native("", 2).stdout, "");
  assert.equal(native(Buffer.from([0xc3, 0x28]), 2).stdout, "");
  assert.equal(native(text, 2, ["--max-line-bytes", "2000000"]).stdout, "");
});

test("normalized gauge and common mode ordering are explicit in returned baseline and responses", () => {
  const value = clone(example);
  value.calibration.matrix = value.calibration.matrix.map((x) => 8 * x);
  close(browser(value), browser(example));
  value.modes.reverse();
  const a = browser(example),
    b = browser(value);
  for (let i = 0; i < a.probes.length; i++) {
    close(a.probes[i].first.contribution_m2, b.probes[i].first.contribution_m2);
    close(a.probes[i].cross_contribution_m2, b.probes[i].cross_contribution_m2);
    close(
      a.probes[i].displacement_contribution_m2,
      b.probes[i].displacement_contribution_m2,
    );
    assert.deepEqual(
      a.probes[i].first.mode_responses_m,
      b.probes[i].first.mode_responses_m.slice().reverse(),
    );
  }
});
