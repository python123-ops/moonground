import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { moonground_measurement_evaluation_checkpoint as evaluate,
  moonground_measurement_acceptance_checkpoint as accept } from "../_build/site/moonground.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.env.MOONGROUND_CLI || path.join(root,"_build/native/release/build/cmd/main/main.exe");
const measured = readFileSync(path.join(root,"examples/measurement-evaluation-measurements.ndjson"),"utf8").trim().split("\n").map(JSON.parse);
const refs = readFileSync(path.join(root,"examples/measurement-evaluation-reference.ndjson"),"utf8").trim().split("\n").map(JSON.parse);
const rows = refs.filter(r=>measured.some(m=>m.timestamp_us===r.timestamp_us)).map(reference=>({
  measurement:measured.find(m=>m.timestamp_us===reference.timestamp_us),reference }));
const source = {session_id:"evaluation-example"};
function bridge(config,frames=rows,acceptance=false) {
  return JSON.parse((acceptance?accept:evaluate)(JSON.stringify({source:JSON.stringify(config),frames:frames.map(JSON.stringify).join("\n")})));
}
function native(config,frames=rows,acceptance=false) {
  const process=spawnSync(binary,[acceptance?"--accept-measurements-checkpoint":"--evaluate-measurements-checkpoint"],{
    input:[JSON.stringify(config),...frames.map(JSON.stringify)].join("\n"),encoding:"utf8"});
  assert.equal(process.stderr,"");
  const value=JSON.parse(process.stdout);
  assert.equal(process.status,acceptance&&!value.report.accepted?3:0);
  return value;
}

test("every cut continues in all four native/JavaScript directions",()=>{
  const baseline=native(source);
  assert.deepEqual(bridge(source),baseline);
  for(let cut=0;cut<=rows.length;cut++) {
    for(const first of [native,bridge]) for(const next of [native,bridge]) {
      const prefix=first(source,rows.slice(0,cut));
      assert.deepEqual(next({resume:prefix.resume},rows.slice(cut)),baseline);
      assert.ok(JSON.stringify(prefix.resume).length<4096);
    }
  }
});

test("new explicit acceptance requirements apply to the cumulative population",()=>{
  const prefix=native(source,rows.slice(0,1));
  const config={resume:prefix.resume,requirements:{position_m:{min_samples:3,min_coverage:1,max_error:0.25}}};
  assert.equal(bridge(config,[],true).report.accepted,false);
  const result=bridge(config,rows.slice(1),true);
  assert.equal(result.report.accepted,true);
  assert.deepEqual(result,native(config,rows.slice(1),true));
});

test("checkpoint timestamps stay exact beyond the JavaScript integer range",()=>{
  const frames=structuredClone(rows);
  for(let i=0;i<frames.length;i++) {
    const clock=(9007199254740993n+BigInt(i)).toString();
    frames[i].measurement.timestamp_us=frames[i].reference.timestamp_us=clock;
    for(const track of frames[i].measurement.tracks) track.last_accepted_timestamp_us=clock;
  }
  const prefix=bridge(source,frames.slice(0,1));
  assert.equal(prefix.resume.last_timestamp_us,"9007199254740993");
  assert.deepEqual(native({resume:prefix.resume},frames.slice(1)),bridge(source,frames));
});

test("invalid populations and attempted configuration overrides are rejected",()=>{
  const prefix=bridge(source,rows.slice(0,1));
  for(const checkpoint of [
    {...prefix.resume,version:2},
    {...prefix.resume,counts:{...prefix.resume.counts,references:999}},
    {...prefix.resume,last_timestamp_us:0},
    {...prefix.resume,position:{...prefix.resume.position,scale:-1}},
  ]) assert.ok(bridge({resume:checkpoint},[]).error);
  assert.ok(bridge({resume:prefix.resume,max_tracks:4096},[]).error);
  const process=spawnSync(binary,["--evaluate-measurements-checkpoint"],{
    input:[JSON.stringify({resume:prefix.resume}),JSON.stringify(rows[0])].join("\n"),encoding:"utf8"});
  assert.equal(process.status,2);
  assert.equal(process.stdout,"");
  assert.ok(bridge({resume:prefix.resume},[rows[0]]).error);
});

test("extreme finite moments retain their scaled accumulator across runtimes",()=>{
  const frames=structuredClone(rows);
  for(const frame of frames) for(const track of frame.measurement.tracks) track.position_m=[1e200,0];
  const prefix=native(source,frames.slice(0,1));
  assert.ok(prefix.resume.position.scale>1e199);
  assert.deepEqual(bridge({resume:prefix.resume},frames.slice(1)),native(source,frames));
});

test("pure checkpoint batches retain the 5000-line limit",()=>{
  assert.ok(bridge(source,Array(5001).fill(rows[0])).error);
});
