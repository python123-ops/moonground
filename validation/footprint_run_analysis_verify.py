#!/usr/bin/env python3
"""Independent atomic motion plus explicit-footprint run composition.

Old motion stream/checkpoint and old v26 run stream/checkpoint are separate
oracles. Every successful joint frame and both complete checkpoints must match.
No host code guesses new segment IDs or retains a shape history map.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import sys
import time

PINNED_HOME=os.environ.get("MOON_HOME")

import analysis_verify as analysis_reference
import checkpoint_verify as checkpoints
import footprint_run_verify as run_reference
import gates_verify as gates
import reframe_verify as reframe_reference
import camera_verify as camera_reference
import verify as reference

ROOT=Path(__file__).resolve().parents[1]
MODE="--analyze-footprint-runs"
CHECKPOINT="--analyze-footprint-runs-checkpoint"
PREVIEW="--preview-footprint-run"
encode,native,execute=gates.encode,gates.native,gates.execute
assigned=run_reference.assigned
MAX=9223372036854775807


def source(measurement,runs):return {"measurement":encode(measurement),"runs":encode(runs)}
def combined(measurement,runs):return {"format":"moonground.footprint-run-analysis","checkpoint_version":"1","measurement":measurement,"runs":runs}
def document(measurement,index=0):
    values=[]
    for track in measurement["tracks"]:
        if track["segment_id"] is None or (index%7==5 and track["track_id"]%2):continue
        shape=assigned.disk(.25 if index%6!=3 else .5) if track["track_id"]%2 else assigned.convex()
        values.append(assigned.assignment(track,shape))
    return assigned.bundle(measurement,values)
def component_chain(binary,measurement,runs,frames):
    measured=native(binary,"--stream",[measurement]+frames);documents=[document(v,i) for i,v in enumerate(measured)]
    wrapped=[assigned.wrap(raw,doc) for raw,doc in zip(frames,documents)]
    old=native(binary,"--footprint-runs",[runs]+[assigned.wrap(value,doc) for value,doc in zip(measured,documents)])
    result=[{"schema_version":"0.1.0","kind":"footprint_run_analysis_frame","measurement":m,"runs":r} for m,r in zip(measured,old)]
    saved=combined(native(binary,"--checkpoint",[measurement]+frames,count=1)[0],native(binary,"--footprint-runs-checkpoint",[runs]+[assigned.wrap(value,doc) for value,doc in zip(measured,documents)],count=1)[0])
    return result,saved,wrapped


def steady(name="joint-footprint-steady",start=0):
    measurement=checkpoints.config(name);measurement["motion"].update(min_observations=2,min_span_us="0",gate=1e12,max_tracks=32,max_velocity_std_mps=1e5,max_position_std_m=1e5)
    frames=[checkpoints.frame(start+i*100000,[checkpoints.observation(1,[.5,.5],[.01,0,.01])]) for i in range(6)]
    position=assigned.position_reference.configuration(name,[assigned.position_reference.zone("one",[[-10,-10],[10,-10],[10,10],[-10,10]],2),assigned.position_reference.zone("two",[[-20,-20],[20,-20],[20,20],[-20,20]],2)])
    return measurement,run_reference.source(position,{"min_samples":"2","confirmation_us":"100000"}),frames


def fixtures():
    result=[]
    for name,measurement,_,frames in analysis_reference.fixtures():
        position=assigned.position_reference.configuration(measurement["session_id"],[assigned.position_reference.zone("wide",[[-100,-100],[100,-100],[100,100],[-100,100]],0)])
        result.append((name,measurement,run_reference.source(position,{"min_samples":"2","confirmation_us":"100000"}),frames))
    for name,start in [("steady",0),("large_clock",9007199254740993)]:
        result.append((name,*steady("joint-"+name,start)))
    measurement,runs,_=steady("joint-max-clock",MAX-3);frames=[checkpoints.frame(MAX-3+i,[checkpoints.observation(1,[.5,.5],[.01,0,.01])]) for i in range(4)]
    result.append(("near_max",measurement,runs,frames))
    return result


def replay_checks(binary):
    records=[];cuts=0;statuses=set()
    for name,measurement,runs,frames in fixtures():
        expected,saved,wrapped=component_chain(binary,measurement,runs,frames);head=source(measurement,runs)
        assert native(binary,MODE,[head]+wrapped)==expected,name
        assert native(binary,CHECKPOINT,[head]+wrapped,count=1)[0]==saved,name
        for value in expected:statuses.update(v["status"] for v in value["measurement"]["tracks"])
        for cut in range(len(frames)+1):
            cp=native(binary,CHECKPOINT,[head]+wrapped[:cut],count=1)[0]
            assert native(binary,MODE,[{"resume":cp}]+wrapped[cut:])==expected[cut:],(name,cut)
            assert native(binary,CHECKPOINT,[{"resume":cp}]+wrapped[cut:],count=1)[0]==saved;cuts+=1
            if cut<len(frames):
                assert native(binary,PREVIEW,[{"resume":cp},frames[cut]],count=1)[0]=={"measurement":expected[cut]["measurement"]}
                assert native(binary,CHECKPOINT,[{"resume":cp}],count=1)[0]==cp
        records.append({"name":name,"frames":len(frames),"active_rows":sum(len(v["runs"]["active"]) for v in expected),"confirmed_rows":sum(len(v["runs"]["confirmed"]) for v in expected),"closed_rows":sum(len(v["runs"]["closed"]) for v in expected)})
    assert {"initializing","ready","uncertain","rejected_innovation","numerical_failure","rejected_projection"}.issubset(statuses)
    return {"cases":len(records),"frames":sum(v["frames"] for v in records),"cut_points":cuts,"statuses":sorted(statuses),"old_motion_plus_v26_full_frames_and_checkpoint_exact":True,"preview_every_nonterminal_cut_exact_and_noncommitting":True,"records":records}


def strict_checks(binary):
    measurement,runs,frames=steady();expected,saved,wrapped=component_chain(binary,measurement,runs,frames[:3]);head=source(measurement,runs);records=[]
    def reject(name,value):
        outputs,meta=execute(binary,CHECKPOINT,[value],status=2);assert not outputs;records.append(dict(name=name,**meta))
    for name,value in [("unknown_source",dict(head,extra=True)),("measurement_not_raw",dict(head,measurement=measurement)),("runs_not_raw",dict(head,runs=runs)),("fresh_run_with_started_motion",source({"resume":saved["measurement"]},runs))]:reject(name,value)
    def bad_cp(name,mutate,independent=False):
        changed=copy.deepcopy(saved);mutate(changed)
        if independent:
            native(binary,"--checkpoint",[{"resume":changed["measurement"]}],count=1)
            native(binary,"--footprint-runs-checkpoint",[{"resume":changed["runs"]}],count=1)
        reject(name,{"resume":changed})
    bad_cp("joint_version",lambda v:v.update(checkpoint_version="2"))
    bad_cp("watermark",lambda v:v["runs"].update(last_timestamp_us="200001"))
    bad_cp("session",lambda v:v["runs"].update(session_id="other"),True)
    bad_cp("current_anchor",lambda v:[s.update(last_position_m=[.6,.5]) for s in v["runs"]["states"]],True)
    bad_cp("upper_covariance",lambda v:[s.update(last_position_covariance=[s["last_position_covariance"][0]+1e-6,s["last_position_covariance"][1],s["last_position_covariance"][2]]) for s in v["runs"]["states"]],True)
    bad_cp("wrong_segment",lambda v:[s["run"].update(segment_id="2") for s in v["runs"]["states"]],True)
    bad_cp("hidden_motion",lambda v:v["measurement"]["motion"]["tracks"][0].update(last_timestamp_us="100000"),True)
    bad_cp("initializing_motion",lambda v:v["measurement"]["configuration"]["motion"].update(min_observations=5),True)
    bad_cp("velocity_quality",lambda v:v["measurement"]["configuration"]["motion"].update(max_velocity_std_mps=1e-12),True)
    bad_cp("position_quality",lambda v:v["measurement"]["configuration"]["motion"].update(max_position_std_m=1e-12),True)
    bad_cp("run_before_warmup",lambda v:[s["run"].update(first_timestamp_us="0",sample_span_us="200000") for s in v["runs"]["states"]],True)
    bad_cp("run_accepted_budget",lambda v:[s["run"].update(sample_count="3") for s in v["runs"]["states"]],True)
    # The two components can each describe feasible histories yet their union of
    # accepted witness timestamps requires more observations than motion saved.
    def witness(v):
        v["measurement"]["motion"]["tracks"][0]["accepted_count"]=3
        state=v["runs"]["states"][1];state["run"].update(first_timestamp_us="150000",sample_span_us="50000",sample_count="2",confirmed=False)
    bad_cp("joint_known_witness_union",witness,True)
    def suffix(v):
        witness(v);v["measurement"]["motion"]["tracks"][0]["accepted_count"]=4
    bad_cp("joint_known_suffix_lower_bound",suffix,True)
    prefix=native(binary,MODE,[head,wrapped[0]])
    for name,value in [("duplicate_wrapper",'{"measurement":"bad",'+encode(wrapped[1])[1:]),("unknown_frame",dict(wrapped[1],extra=True)),
        ("fractional_id",dict(wrapped[1],assignments=wrapped[1]["assignments"].replace('"track_id":1','"track_id":1.0000000000000001'))),
        ("wrong_candidate_segment",dict(wrapped[1],assignments=wrapped[1]["assignments"].replace('"segment_id":"1"','"segment_id":"2"')))]:
        actual,meta=execute(binary,MODE,[head,wrapped[0],value],status=2);assert actual==prefix;records.append(dict(name=name,**meta));assert not execute(binary,CHECKPOINT,[head,wrapped[0],value],status=2)[0]
    return {"rejected_cases":len(records),"cases":records,"independently_legal_component_cross_bindings_rejected":True,"cli_complete_prefix_and_no_failed_checkpoint":True}

def atomic_checks(binary):
    measurement,runs,frames=steady("joint-atomic");head=source(measurement,runs)
    expected,saved,wrapped=component_chain(binary,measurement,runs,frames[:2])
    preview=native(binary,PREVIEW,[head,frames[0]],count=1)[0]
    assert preview=={"measurement":expected[0]["measurement"]}
    wrong=copy.deepcopy(wrapped[0]);doc=json.loads(wrong["assignments"]);doc["footprints"][0]["segment_id"]="9";wrong["assignments"]=encode(doc)
    outputs,wrong_meta=execute(binary,MODE,[head,wrong],status=2);assert not outputs
    cp0=native(binary,CHECKPOINT,[head],count=1)[0]
    assert native(binary,CHECKPOINT,[head],count=1)[0]==cp0
    prefix=native(binary,MODE,[head,wrapped[0]])
    cp1=native(binary,CHECKPOINT,[head,wrapped[0]],count=1)[0]
    bad=copy.deepcopy(wrapped[1]);doc=json.loads(bad["assignments"]);doc["footprints"][0]["shape"]=assigned.disk(1e-30);bad["assignments"]=encode(doc)
    outputs,tiny_meta=execute(binary,MODE,[head,wrapped[0],bad],status=2);assert outputs==prefix
    assert not execute(binary,CHECKPOINT,[head,wrapped[0],bad],status=2)[0]
    retry=native(binary,MODE,[{"resume":cp1},wrapped[1]])
    assert retry==expected[1:]
    assert native(binary,CHECKPOINT,[{"resume":cp1},wrapped[1]],count=1)[0]==saved
    assert native(binary,CHECKPOINT,[{"resume":cp1}],count=1)[0]==cp1
    assert saved["measurement"]["motion"]["next_segment_id"]=="2"
    return {"status":"passed","first_wrong_segment":wrong_meta,"first_ready_late_numeric_failure":tiny_meta,"corrected_same_timestamp":frames[1]["timestamp_us"],"all_motion_state_P_path_next_segment_and_run_checkpoint_exact":True,"live_same_preparation_retry_covered_by_core_and_consumer":True}


def preview_transport(binary):
    measurement,runs,frames=steady("joint-transport");head=source(measurement,runs)
    expected,saved,wrapped=component_chain(binary,measurement,runs,frames[:1]);preview={"measurement":expected[0]["measurement"]}
    assert native(binary,PREVIEW,[head,frames[0]],count=1)[0]==preview
    assert native(binary,PREVIEW,[head,frames[0]],count=1)[0]==preview
    assert not execute(binary,PREVIEW,[head],status=2)[0]
    extra,meta=execute(binary,PREVIEW,[head,frames[0],frames[1]],status=2);assert extra==[preview]
    assert not execute(binary,PREVIEW,[head,expected[0]["measurement"]],status=2)[0]
    assert not execute(binary,MODE,payload=b"",status=2)[0]
    for ending in (b"\n",b"\r\n"):
        payload=ending.join(encode(v).encode() for v in [head,wrapped[0]])
        assert execute(binary,MODE,payload=payload)[0]==expected
    assert native(binary,MODE,[head,encode(wrapped[0]).ljust(1048576)])==expected
    actual,over=execute(binary,MODE,[head,wrapped[0],encode(wrapped[0]).ljust(1048577)],status=2,extra=["--max-line-bytes","16777216"]);assert actual==expected
    # The joint source envelope has its own 8Mi+11 cap, unlike each legacy raw source.
    assert native(binary,CHECKPOINT,[encode(head).ljust(8*1048576+11)],extra=["--max-line-bytes","16777216"],count=1)
    assert not execute(binary,CHECKPOINT,[encode(head).ljust(8*1048576+12)],status=2,extra=["--max-line-bytes","16777216"])[0]
    return {"preview_repeated_noncommitting":True,"preview_missing_or_measurement_output_rejected":True,"preview_extra_input_complete_prefix":meta,"frame_utf16_limit":1048576,"source_utf16_limit":8*1048576+11,"oversized_frame_complete_prefix":over,"lf_crlf_unterminated_eof":"passed"}


def web_checks(binary):
    command=["node","--test","--test-reporter=tap","web/footprint-run-analysis.test.mjs"]
    result=subprocess.run(command,cwd=str(ROOT),env=dict(os.environ,MOONGROUND_CLI=str(binary)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8",timeout=600)
    if result.returncode:raise AssertionError("Node joint footprint runs failed:\n"+result.stdout[-24000:]+result.stderr[-2000:])
    summary={};details={}
    for line in result.stdout.splitlines():
        match=re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$",line)
        if match:summary[match.group(1)]=int(match.group(2))
        for prefix,key in [('cut_points','cross_runtime'),('successful_empty_frames','actual_budgets'),('maximum_actual_face_expansions','maximum_work'),('warm_reframe_maximum_absolute_error','warm_reframe')]:
            if line.startswith('# {"'+prefix+'":'):details[key]=json.loads(line[2:])
    assert summary.get("tests")==summary.get("pass") and not summary.get("fail") and len(details)==4
    return dict(status="passed",node=subprocess.check_output(["node","--version"],text=True).strip(),command=" ".join(command),summary=summary,details=details,test_script_sha256=hashlib.sha256((ROOT/"web/footprint-run-analysis.test.mjs").read_bytes()).hexdigest(),bridge_sha256=hashlib.sha256((ROOT/"_build/site/moonground.mjs").read_bytes()).hexdigest(),stdout_sha256=hashlib.sha256(result.stdout.encode()).hexdigest())


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--binary",type=Path,required=True);parser.add_argument("--web",action="store_true");parser.add_argument("--output",type=Path,default=ROOT/"validation/footprint-run-analysis-results.json");args=parser.parse_args();binary=args.binary.resolve();started=time.perf_counter()
    version=reference.toolchain_version();assert "0.10.18" in str(version),version
    result={"format_version":"1","fixtures":"deterministic","command":" ".join(shlex.quote(v) for v in [sys.executable]+sys.argv),"python":platform.python_version(),"toolchain":version,"pinned_moon_home":PINNED_HOME,"source_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"run_reference_sha256":hashlib.sha256(Path(run_reference.__file__).read_bytes()).hexdigest(),"binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),"independent_reference":"Original measurement stream/checkpoint plus v26 footprint run stream/checkpoint; full frame and both component checkpoints exact; existing NumPy/Fraction geometric references remain separate","scope":"confirmed_sample_spans_under_explicit_current_footprints_not_physical_dwell"}
    result["component_reference"]=replay_checks(binary);result["strict_restore_and_raw"]=strict_checks(binary);result["atomic_failed_candidate"]=atomic_checks(binary);result["transport_and_preview"]=preview_transport(binary)
    if args.web:result["web_interchange"]=web_checks(binary)
    result.update(status="passed",elapsed_seconds=time.perf_counter()-started)
    with args.output.open("w",encoding="utf-8",newline="\n") as f:f.write(json.dumps(result,indent=2,ensure_ascii=True)+"\n")
    print(encode({"status":"passed","cases":result["component_reference"]["cases"],"frames":result["component_reference"]["frames"],"cuts":result["component_reference"]["cut_points"],"rejects":result["strict_restore_and_raw"]["rejected_cases"],"output":str(args.output)}))


if __name__=="__main__":main()
