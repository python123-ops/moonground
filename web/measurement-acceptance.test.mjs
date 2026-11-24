import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { moonground_measurement_acceptance, moonground_measurement_evaluation } from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.env.MOONGROUND_CLI || path.join(root, "_build/native/release/build/cmd/main/main.exe");
const measured = readFileSync(path.join(root, "examples/measurement-evaluation-measurements.ndjson"), "utf8").trim().split("\n").map(JSON.parse);
const references = readFileSync(path.join(root, "examples/measurement-evaluation-reference.ndjson"), "utf8").trim().split("\n").map(JSON.parse);
const frames = references.filter(r => measured.some(m => m.timestamp_us === r.timestamp_us)).map(reference => JSON.stringify({ measurement: measured.find(m => m.timestamp_us === reference.timestamp_us), reference })).join("\n");
const source = requirements => JSON.stringify({ session_id: "evaluation-example", requirements });
const position = { min_samples: 3, min_coverage: 1, max_error: 0.25 };
const speed = { min_samples: 1, min_coverage: 0.3, max_mae: 0.05 };
function bridge(config, rows = frames) {
  return JSON.parse(moonground_measurement_acceptance(JSON.stringify({ source: config, frames: rows })));
}
function native(config, rows = frames) {
  const process = spawnSync(binary, ["--accept-measurements"], { input: config + "\n" + rows + "\n", encoding: "utf8" });
  assert.equal(process.stderr, "");
  const output = JSON.parse(process.stdout);
  assert.equal(process.status, output.accepted ? 0 : 3);
  return output;
}

test("native and JavaScript agree on passing position and speed requirements", () => {
  const config = source({ position_m: position, speed_mps: speed });
  const result = bridge(config);
  assert.equal(result.accepted, true);
  assert.deepEqual(result, native(config));
  const old = JSON.parse(moonground_measurement_evaluation(JSON.stringify({ source: JSON.stringify({ session_id: "evaluation-example" }), frames })));
  assert.deepEqual(result.evaluation, old);
});

test("accurate speed with low availability fails a stronger requirement", () => {
  const config = source({ speed_mps: { ...speed, min_coverage: 0.95 } });
  const result = bridge(config);
  assert.equal(result.accepted, false);
  assert.equal(result.checks.find(c => c.metric === "speed_coverage").passed, false);
  assert.deepEqual(result, native(config));
});

test("empty data has unavailable metrics and cannot pass", () => {
  const config = source({ position_m: { ...position, min_coverage: 0 } });
  const result = bridge(config, "");
  assert.equal(result.accepted, false);
  assert.equal(result.checks[1].actual, null);
  assert.equal(result.checks[2].actual, null);
  const process = spawnSync(binary, ["--accept-measurements"], { input: config, encoding: "utf8" });
  assert.equal(process.status, 3);
  assert.deepEqual(result, JSON.parse(process.stdout));
});

test("requirements reject duplicates unknown fields and underflow tokens", () => {
  for (const config of [source({}), source({ position_m: { ...position, max_error: null } }), source({ position_m: { ...position, unknown: 0 } }), source({ position_m: position }).replace('"max_error":0.25', '"max_error":1e-1000'), source({ position_m: position }).replace('"min_samples":3', '"min_samples":3,"min_samples":4')]) {
    assert.equal(typeof bridge(config).error, "string");
    const process = spawnSync(binary, ["--accept-measurements"], { input: config + "\n", encoding: "utf8" });
    assert.equal(process.status, 2);
    assert.equal(process.stdout, "");
  }
});

test("a late frame failure returns no acceptance prefix and does not poison later requests", () => {
  const config = source({ position_m: position });
  assert.equal(typeof bridge(config, frames + "\n{bad}").error, "string");
  assert.equal(bridge(config).accepted, true);
});

test("one-shot acceptance keeps the established batch size boundary", () => {
  const config = source({ position_m: position });
  assert.equal(typeof bridge(config, Array(5001).fill("{}").join("\n")).error, "string");
});
