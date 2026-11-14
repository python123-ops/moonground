#!/usr/bin/env python3
"""Offline integer outcome windows over independently checked footprint runs.

Old v25 current evidence and the v26 backward suffix reference determine source
runs. Python unbounded integers regroup their genuine outcomes by quotient.
Window counts describe supplied sample outcomes, not visits or physical dwell.
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

import footprint_run_verify as runs
import gates_verify as gates
import verify as reference

ROOT=Path(__file__).resolve().parents[1]
STREAM="--footprint-run-windows"
CHECKPOINT="--footprint-run-windows-checkpoint"
MAX=9223372036854775807
REASONS=["gap_exceeded","segment_closed","segment_changed","missing_target","unavailable_evidence","shape_changed","indeterminate_evidence","decision_changed"]
encode,native,execute=gates.encode,gates.native,gates.execute


def source(run_source,width=3,origin=0):return {"runs":encode(run_source),"window":encode({"window_us":str(width),"origin_us":str(origin)})}
def checkpoint(old,width,origin,baseline,current):return {"format":"moonground.footprint-run-windows","checkpoint_version":"1","runs":old,"window_us":str(width),"origin_us":str(origin),"baseline_timestamp_us":baseline,"current_window":current}
def stamp(frame):return int(frame["evidence"]["timestamp_us"])
def bucket(frames,opening,zones,width,origin):
    first,last=stamp(frames[0]),stamp(frames[-1]);index=(first-origin)//width;start=origin+index*width;end=start+width;values=[]
    for zone in zones:
        identity=zone["zone_id"];confirmed=[v for frame in frames for v in frame["confirmed"] if v["zone_id"]==identity];closed=[v for frame in frames for v in frame["closed"] if v["run"]["zone_id"]==identity];initial=[v for v in opening if v["zone_id"]==identity]
        values.append({"zone_id":identity,"opening_active":str(len(initial)),"opening_confirmed":str(sum(v["confirmed"] for v in initial)),"started":str(sum(v["zone_id"]==identity and int(v["first_timestamp_us"])==stamp(frame) for frame in frames for v in frame["active"])),"confirmed_inside":str(sum(v["decision"]=="inside" for v in confirmed)),"confirmed_outside":str(sum(v["decision"]=="outside" for v in confirmed)),"endings":[{"reason":reason,"confirmed":str(sum(v["reason"]==reason and v["run"]["confirmed"] for v in closed)),"unconfirmed":str(sum(v["reason"]==reason and not v["run"]["confirmed"] for v in closed))} for reason in REASONS]})
    return {"start_us":str(start),"end_exclusive_us":str(end) if end<=MAX else None,"first_timestamp_us":str(first),"last_timestamp_us":str(last),"input_frames":str(len(frames)),"zones":values}

def oracle(initial,width,origin,frames):
    groups={};openings={};order=[];outputs=[];previous=[s["run"] for s in initial["states"]];current=None
    for frame in frames:
        t=stamp(frame);index=(t-origin)//width;closed=None;skipped=0
        if index not in groups:
            if order:closed=copy.deepcopy(current);skipped=index-order[-1]-1
            groups[index]=[];openings[index]=copy.deepcopy(previous);order.append(index)
        groups[index].append(frame);current=bucket(groups[index],openings[index],initial["zones"],width,origin)
        outputs.append({"schema_version":"0.1.0","kind":"footprint_run_window_frame","runs":frame,"statistics":{"session_id":initial["session_id"],"timestamp_us":str(t),"closed_window":closed,"current_window":copy.deepcopy(current),"unobserved_windows":str(skipped)}});previous=frame["active"]
    return outputs,current


def fixtures():
    values=[(name,position,config,wrapped,0,3,0) for name,position,config,wrapped in runs.fixtures()]
    position=runs.configuration("window-baseline");config={"max_gap_us":"10","min_samples":"2","confirmation_us":"2"};wrapped=[runs.sample(position,t,"outside" if t>=4 else "inside") for t in range(6)]
    values.extend([("started_confirmed_no_backfill",position,config,wrapped,3,10,0),("started_unconfirmed_later_confirms",position,config,wrapped,1,10,0)])
    terminal=runs.configuration("window-terminal");config={"max_gap_us":str(MAX),"min_samples":"2","confirmation_us":"1"};wrapped=[runs.sample(terminal,t) for t in [0,1,MAX-1,MAX]]
    values.append(("end_equal_MAX_then_terminal",terminal,config,wrapped,0,MAX,0))
    config={"max_gap_us":str(MAX),"min_samples":"1","confirmation_us":"0"};values.append(("width_one_huge_unobserved",terminal,config,[runs.sample(terminal,0),runs.sample(terminal,MAX,"outside")],0,1,0))
    values.append(("nonzero_origin",position,{"max_gap_us":"10","min_samples":"1","confirmation_us":"0"},[runs.sample(position,t,"outside" if t==103 else "inside") for t in [99,100,102,103,109]],0,3,99))
    return values

def component(binary,position,config,wrapped):
    actual=native(binary,runs.MODE,[runs.source(position,config)]+wrapped)
    evidence=native(binary,"--assigned-zone-evidence",[position]+wrapped);expected,old=runs.offline(position,config,wrapped,evidence);assert actual==expected
    assert native(binary,runs.CHECKPOINT,[runs.source(position,config)]+wrapped,count=1)[0]==old
    return expected,old

def replay_checks(binary):
    records=[];cuts=0;reasons=set();confirmations=0
    for name,position,config,wrapped,cut,width,origin in fixtures():
        allframes,old=component(binary,position,config,wrapped);initial=native(binary,runs.CHECKPOINT,[runs.source(position,config)]+wrapped[:cut],count=1)[0]
        head=source({"resume":initial} if cut else runs.source(position,config),width,origin);frames=wrapped[cut:];expected,current=oracle(initial,width,origin,allframes[cut:]);saved=checkpoint(old,width,origin,initial["last_timestamp_us"],current)
        assert native(binary,STREAM,[head]+frames)==expected,name
        assert native(binary,CHECKPOINT,[head]+frames,count=1)[0]==saved,name
        for split in range(len(frames)+1):
            cp=native(binary,CHECKPOINT,[head]+frames[:split],count=1)[0]
            assert native(binary,STREAM,[{"resume":cp}]+frames[split:])==expected[split:],(name,split)
            assert native(binary,CHECKPOINT,[{"resume":cp}]+frames[split:],count=1)[0]==saved;cuts+=1
        for value in expected:reasons.update(v["reason"] for v in value["runs"]["closed"]);confirmations+=len(value["runs"]["confirmed"])
        records.append({"name":name,"frames":len(frames),"source_baseline":initial["last_timestamp_us"],"buckets":len({v["statistics"]["current_window"]["start_us"] for v in expected}),"first_confirmations":sum(len(v["runs"]["confirmed"]) for v in expected),"endings":sum(len(v["runs"]["closed"]) for v in expected)})
    assert reasons==set(REASONS)
    return {"cases":len(records),"frames":sum(v["frames"] for v in records),"cut_points":cuts,"first_confirmations":confirmations,"all_eight_end_reasons":sorted(reasons),"v25_plus_independent_suffix_runs_and_bigint_quotient_windows_exact":True,"records":records}


def seed(binary,name="window-strict",capacity=2):
    position=runs.configuration(name,capacity=capacity);config={"max_gap_us":"100","confirmation_us":"0","min_samples":"1"};head=source(runs.source(position,config),10);wrapped=[runs.sample(position,t) for t in [0,1,2]];cp=native(binary,CHECKPOINT,[head]+wrapped,count=1)[0]
    return position,config,head,wrapped,cp

def strict_checks(binary):
    position,config,head,wrapped,saved=seed(binary);records=[]
    def bad(name,values,mode=CHECKPOINT,prefix=()):
        out,meta=execute(binary,mode,values,status=2);assert out==list(prefix),name;records.append(dict(name=name,**meta))
    for name,value in [("unknown_source",dict(head,extra=True)),("runs_not_raw",dict(head,runs=json.loads(head["runs"]))),("window_not_raw",dict(head,window={})),("bad_number_window",dict(head,window='{"window_us":10}')),("noncanonical_window",dict(head,window='{"window_us":"01"}')),("zero_width",source(runs.source(position,config),0))]:bad(name,[value])
    def damage(name,mutate,old_valid=True):
        cp=copy.deepcopy(saved);mutate(cp)
        if old_valid:native(binary,runs.CHECKPOINT,[{"resume":cp["runs"]}],count=1)
        bad(name,[{"resume":cp}])
    damage("version",lambda c:c.update(checkpoint_version="2"))
    damage("missing_observed_bucket",lambda c:c.update(current_window=None))
    damage("wrong_start",lambda c:c["current_window"].update(start_us="1"))
    damage("wrong_end",lambda c:c["current_window"].update(end_exclusive_us=None))
    damage("wrong_watermark",lambda c:c["current_window"].update(last_timestamp_us="3"))
    damage("frame_slots",lambda c:c["current_window"].update(input_frames="4"))
    damage("opening_fresh",lambda c:c["current_window"]["zones"][0].update(opening_active="1"))
    damage("active_flow",lambda c:c["current_window"]["zones"][0].update(started="0"))
    damage("confirmed_flow",lambda c:c["current_window"]["zones"][0].update(confirmed_inside="0"))
    damage("matching_decision_confirmation_minimum",lambda c:c["current_window"]["zones"][0].update(confirmed_inside="0",confirmed_outside="1"))
    damage("reason_order",lambda c:c["current_window"]["zones"][0]["endings"].reverse())
    damage("zone_identity",lambda c:c["current_window"]["zones"][0].update(zone_id="other"))
    damage("negative_count",lambda c:c["current_window"]["zones"][0].update(started="-1"))
    damage("aggregate_capacity",lambda c:c["current_window"]["zones"][0].update(confirmed_inside="4",confirmed_outside="4"))
    damage("instant_unconfirmed_end",lambda c:c["current_window"]["zones"][0]["endings"][0].update(unconfirmed="1"))
    damage("suffix_frame_count",lambda c:c["current_window"].update(input_frames="2"))
    damage("suffix_run_count",lambda c:c["runs"]["states"][0]["run"].update(sample_count="2"))
    # All component run histories are feasible individually; only their sparse
    # global suffix anchors prove that six-to-three samples cannot elapse in 1us.
    two=runs.configuration("window-sparse-anchors",[runs.assigned.position_reference.zone("a",multiplier=0),runs.assigned.position_reference.zone("b",multiplier=0)],2)
    sparse=native(binary,CHECKPOINT,[source(runs.source(two,config),100),runs.sample(two,10)],count=1)[0]
    sparse["current_window"].update(first_timestamp_us="0",input_frames="8")
    for state,first,count in zip(sparse["runs"]["states"],[4,5],[6,3]):state["run"].update(first_timestamp_us=str(first),sample_span_us=str(10-first),sample_count=str(count))
    native(binary,runs.CHECKPOINT,[{"resume":sparse["runs"]}],count=1)
    bad("cross_zone_suffix_count_time_difference",[{"resume":sparse}])
    # Below-origin rejection occurs after the old monitor candidate succeeds.
    late=source(runs.source(position,config),10,99);assert not execute(binary,CHECKPOINT,[late,runs.sample(position,98)],status=2)[0]
    assert native(binary,STREAM,[late,runs.sample(position,99)],count=1)[0]["runs"]["active"][0]["sample_count"]=="1"
    prefix=native(binary,STREAM,[head,wrapped[0]])
    invalid=runs.sample(position,1);doc=json.loads(invalid["assignments"]);doc["footprints"][0]["segment_id"]="9";invalid["assignments"]=encode(doc)
    for name,value in [("wrong_assignment_segment",invalid),("duplicate_raw_wrapper",'{"measurement":"bad",'+encode(wrapped[1])[1:]),("fractional_raw_id",dict(wrapped[1],assignments=wrapped[1]["assignments"].replace('"track_id":1','"track_id":1.0000000000000001'))),("unknown_frame",dict(wrapped[1],extra=True))]:bad(name,[head,wrapped[0],value],STREAM,prefix)
    assert not execute(binary,CHECKPOINT,[head,wrapped[0],invalid],status=2)[0]
    return {"rejected_cases":len(records),"records":records,"old_component_valid_CP_corruptions_checked":True,"origin_failure_requires_corrected_time_not_same_time":True}


def overflow_checks(binary):
    position=runs.configuration("window-overflow",capacity=2);config={"max_gap_us":str(MAX),"confirmation_us":"0","min_samples":"1"};head=source(runs.source(position,config),MAX)
    first=runs.sample(position,MAX-2);frame,doc=runs.parts(first);other=copy.deepcopy(frame["tracks"][0]);other.update(track_id=2,segment_id="2");frame["tracks"].append(other);doc["footprints"].append(runs.assigned.assignment(other,runs.assigned.disk()));first=runs.assigned.wrap(frame,doc)
    cp=native(binary,CHECKPOINT,[head,first],count=1)[0];window=cp["current_window"];window.update(first_timestamp_us="0",input_frames=str(MAX//2+1));row=window["zones"][0];row.update(started=str(MAX),confirmed_inside=str(MAX));row["endings"][5]["confirmed"]=str(MAX-2)
    assert native(binary,CHECKPOINT,[{"resume":cp}],count=1)[0]==cp
    def next_frame(outside):
        f=copy.deepcopy(frame);f["timestamp_us"]=str(MAX-1)
        for track in f["tracks"]:
            track["last_accepted_timestamp_us"]=str(MAX-1)
            if outside:track["position_m"]=[2,.5]
        d=copy.deepcopy(doc);d["timestamp_us"]=str(MAX-1);return runs.assigned.wrap(f,d)
    bad,meta=execute(binary,STREAM,[{"resume":cp},next_frame(True)],status=2);assert not bad
    assert not execute(binary,CHECKPOINT,[{"resume":cp},next_frame(True)],status=2)[0]
    corrected=native(binary,STREAM,[{"resume":cp},next_frame(False)],count=1)[0]
    assert corrected["statistics"]["current_window"]["zones"][0]["started"]==str(MAX)
    assert all(v["sample_count"]=="2" for v in corrected["runs"]["active"])
    assert native(binary,CHECKPOINT,[{"resume":cp}],count=1)[0]==cp
    return {"status":"passed","saved_started_and_confirmed":str(MAX),"observed_frames":str(MAX//2+1),"capacity":2,"failure":meta,"same_timestamp_retry":str(MAX-1),"pool_balances_and_multiword_capacity_valid":True,"live_rollback_tested_by_core_consumer":True}


def transport_checks(binary):
    _,_,head,frames,_=seed(binary,"window-transport");expected=native(binary,STREAM,[head,frames[0]])
    for ending in (b"\n",b"\r\n"):assert execute(binary,STREAM,payload=ending.join(encode(v).encode() for v in [head,frames[0]]))[0]==expected
    assert native(binary,STREAM,[head,encode(frames[0]).ljust(1048576)])==expected
    assert not execute(binary,CHECKPOINT,[head,encode(frames[0]).ljust(1048577)],status=2,extra=["--max-line-bytes","16777216"])[0]
    assert native(binary,CHECKPOINT,[encode(head).ljust(8388619)],extra=["--max-line-bytes","16777216"],count=1)
    assert not execute(binary,CHECKPOINT,[encode(head).ljust(8388620)],extra=["--max-line-bytes","16777216"],status=2)[0]
    assert not execute(binary,STREAM,payload=b"",status=2)[0]
    return {"frame_utf16":1048576,"source_utf16":8388619,"LF_CRLF_unterminated_EOF":"passed","failed_checkpoint_no_output":True}


def web_checks(binary):
    command=["node","--test","--test-reporter=tap","web/footprint-run-windows.test.mjs"];result=subprocess.run(command,cwd=str(ROOT),env=dict(os.environ,MOONGROUND_CLI=str(binary)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8",timeout=600)
    if result.returncode:raise AssertionError(result.stdout[-24000:]+result.stderr[-2000:])
    summary={};details={}
    for value in result.stdout.splitlines():
        match=re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$",value)
        if match:summary[match.group(1)]=int(match.group(2))
        for prefix,key in [("cut_points","cross_runtime"),("empty_frame_count","actual_budgets"),("maximum_actual_face_expansions","maximum_work")]:
            if value.startswith('# {"'+prefix+'":'):details[key]=json.loads(value[2:])
    assert summary.get("tests")==summary.get("pass") and not summary.get("fail") and len(details)==3
    return {"status":"passed","summary":summary,"details":details,"command":" ".join(command),"node":subprocess.check_output(["node","--version"],text=True).strip(),"source_sha256":hashlib.sha256((ROOT/"web/footprint-run-windows.test.mjs").read_bytes()).hexdigest(),"bridge_sha256":hashlib.sha256((ROOT/"_build/site/moonground.mjs").read_bytes()).hexdigest(),"stdout_sha256":hashlib.sha256(result.stdout.encode()).hexdigest()}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--binary",type=Path,required=True);parser.add_argument("--web",action="store_true");parser.add_argument("--output",type=Path,default=ROOT/"validation/footprint-run-windows-results.json");args=parser.parse_args();binary=args.binary.resolve();started=time.perf_counter();version=reference.toolchain_version();assert "0.10.18" in str(version)
    result={"format_version":"1","fixtures":"deterministic","command":" ".join(shlex.quote(v) for v in [sys.executable]+sys.argv),"python":platform.python_version(),"toolchain":version,"inherited_moon_home":os.environ.get("MOON_HOME"),"source_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"suffix_reference_sha256":hashlib.sha256(Path(runs.__file__).read_bytes()).hexdigest(),"assigned_reference_sha256":hashlib.sha256(Path(runs.assigned.__file__).read_bytes()).hexdigest(),"binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),"scope":"observed_footprint_run_outcome_windows_not_occupancy_or_dwell","independent_reference":"v25 assigned evidence plus backward suffix v26 oracle, then Python bigint quotient offline groups of genuine report-time outcomes and opening pools"}
    result["offline_component_reference"]=replay_checks(binary);result["strict_restore_and_raw"]=strict_checks(binary);result["late_window_overflow"]=overflow_checks(binary);result["transport"]=transport_checks(binary)
    if args.web:result["web_interchange"]=web_checks(binary)
    result.update(status="passed",elapsed_seconds=time.perf_counter()-started)
    with args.output.open("w",encoding="utf-8",newline="\n") as f:f.write(json.dumps(result,indent=2,ensure_ascii=True)+"\n")
    print(encode({"status":"passed","cases":result["offline_component_reference"]["cases"],"frames":result["offline_component_reference"]["frames"],"cuts":result["offline_component_reference"]["cut_points"],"strict_rejects":result["strict_restore_and_raw"]["rejected_cases"],"output":str(args.output)}))

if __name__=="__main__":main()
