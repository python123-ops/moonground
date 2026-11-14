#!/usr/bin/env python3
"""Offline integer reference for explicit-footprint confirmed sample runs.

Each current mathematical evidence frame must equal the existing stateless v25
path exactly. The reference then scans finite history backwards to derive the
maximal available same-identity/shape/decision suffix, independently of the
production incremental monitor. Sample spans do not assert continuous presence.
"""
import argparse
import copy
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import sys
import time

import assigned_zone_verify as assigned
import gates_verify as gates
import verify as reference

ROOT=Path(__file__).resolve().parents[1]
MODE="--footprint-runs"
CHECKPOINT="--footprint-runs-checkpoint"
SCOPE="current_target_footprint_confirmed_sample_runs"
encode,native,execute=gates.encode,gates.native,gates.execute
MAX=9223372036854775807
DEFAULT={"max_gap_us":"500000","confirmation_us":"1000000","min_samples":"2"}


def source(position,options=None):return {"position":encode(position),"options":encode(options or {})}
def configuration(name="footprint-runs",zones=None,capacity=32):
    return assigned.position_reference.configuration(name,zones or [assigned.position_reference.zone(multiplier=0)],capacity)
def sample(position,t,kind="inside",shape=None,segment="1",identity=1,closed=()):
    statuses={"initializing":"initializing","uncertain":"uncertain","rejected":"rejected_innovation","numerical":"numerical_failure","projection":"rejected_projection"}
    if kind=="absent":frame=gates.measurement(t,[],closed,name=position["session_id"])
    else:
        point=(2,.5) if kind=="outside" else (1,.5) if kind=="indeterminate" else (.5,.5)
        frame=assigned.position_reference.measured(position,t,point,identity=identity,segment=segment,status=statuses.get(kind,"ready"));frame["closed_segment_ids"]=list(closed)
    entries=[] if kind in ("missing","absent","projection") else [assigned.assignment(frame["tracks"][0],shape or assigned.disk())]
    return assigned.wrap(frame,assigned.bundle(frame,entries))
def parts(wrapped):return json.loads(wrapped["measurement"]),json.loads(wrapped["assignments"])
def options(raw):return dict(DEFAULT,**raw)
def shape_of(document,identity):return next((v["shape"] for v in document["footprints"] if v["track_id"]==identity),None)
def reported(frame,identity):return next((v for v in frame["tracks"] if v["track_id"]==identity and v["status"]!="rejected_projection"),None)
def row_of(evidence,identity,zone):return next((v for v in evidence["evidence"] if v["track_id"]==identity and v["zone_id"]==zone),None)


def offline(position,raw_options,wrapped,evidence):
    config=options(raw_options);gap=int(config["max_gap_us"]);need=int(config["min_samples"]);span=int(config["confirmation_us"])
    history=[parts(v) for v in wrapped];result=[];previous=[]
    order={zone["zone_id"]:i for i,zone in enumerate(position["zones"])}
    for index,((frame,document),current) in enumerate(zip(history,evidence)):
        t=int(frame["timestamp_us"]);active=[]
        for row in current["evidence"]:
            if row["decision"]=="indeterminate":continue
            start=index;identity=row["track_id"];zone=row["zone_id"];segment=row["segment_id"];shape=shape_of(document,identity)
            while start>0:
                old_frame,old_doc=history[start-1];new_frame,new_doc=history[start]
                old_row=row_of(evidence[start-1],identity,zone)
                if (int(new_frame["timestamp_us"])-int(old_frame["timestamp_us"])>=gap or segment in new_frame["closed_segment_ids"] or
                    not old_row or old_row["segment_id"]!=segment or old_row["decision"]!=row["decision"] or shape_of(old_doc,identity)!=shape):break
                start-=1
            first=int(history[start][0]["timestamp_us"]);count=index-start+1
            active.append({"zone_id":zone,"track_id":identity,"segment_id":segment,"decision":row["decision"],"first_timestamp_us":str(first),"last_timestamp_us":str(t),
                "sample_count":str(count),"sample_span_us":str(t-first),"confirmed":count>=need and t-first>=span})
        active.sort(key=lambda v:(v["track_id"],order[v["zone_id"]]))
        closed=[]
        for run in previous:
            identity=run["track_id"];zone=run["zone_id"];track=reported(frame,identity);row=row_of(current,identity,zone)
            prior_doc=history[index-1][1]
            reason=("gap_exceeded" if t-int(run["last_timestamp_us"])>=gap else "segment_closed" if run["segment_id"] in frame["closed_segment_ids"] else
                "segment_changed" if track and track["segment_id"]!=run["segment_id"] else "missing_target" if not track else
                "unavailable_evidence" if not row else "shape_changed" if shape_of(document,identity)!=shape_of(prior_doc,identity) else
                "indeterminate_evidence" if row["decision"]=="indeterminate" else "decision_changed" if row["decision"]!=run["decision"] else None)
            if reason:closed.append({"run":copy.deepcopy(run),"closed_at_timestamp_us":str(t),"reason":reason})
        newly=[]
        for run in active:
            old=next((v for v in previous if v["track_id"]==run["track_id"] and v["zone_id"]==run["zone_id"] and v["first_timestamp_us"]==run["first_timestamp_us"] and v["segment_id"]==run["segment_id"]),None)
            if run["confirmed"] and (old is None or not old["confirmed"]):newly.append(copy.deepcopy(run))
        result.append({"schema_version":"0.1.0","kind":"footprint_run_frame","evidence_scope":SCOPE,"evidence":current,"active":active,"confirmed":newly,"closed":closed});previous=active
    states=[]
    if history:
        frame,document=history[-1]
        for run in previous:
            track=reported(frame,run["track_id"])
            states.append({"run":copy.deepcopy(run),"shape":copy.deepcopy(shape_of(document,run["track_id"])),"last_position_m":track["position_m"],"last_position_covariance":track["position_covariance"]})
    saved={"schema_version":"0.1.0","kind":"footprint_run_checkpoint","version":1,"session_id":position["session_id"],
        "zones":[dict(zone,sigma_multiplier=zone.get("sigma_multiplier",2)) for zone in position["zones"]],"max_tracks":position.get("max_tracks",1000),"config":config,
        "last_timestamp_us":history[-1][0]["timestamp_us"] if history else None,"states":states}
    return result,saved


def fixtures():
    position=configuration();cases=[];base={"max_gap_us":"10","confirmation_us":"2","min_samples":"2"}
    paths=[("and_confirmation",[(0,"inside"),(1,"inside"),(2,"inside"),(3,"inside"),(4,"outside"),(5,"outside"),(6,"outside")],{}),
        ("instant_first",[(0,"inside"),(1,"inside"),(2,"outside")],{"min_samples":"1","confirmation_us":"0"}),
        ("samples_only",[(0,"inside"),(1,"inside"),(2,"inside")],{"min_samples":"3","confirmation_us":"0"}),
        ("span_only",[(0,"inside"),(1,"inside"),(3,"inside")],{"min_samples":"1","confirmation_us":"3"})]
    for name,path,change in paths:cases.append((name,position,dict(base,**change),[sample(position,t,k) for t,k in path]))
    for kind in ["indeterminate","missing","initializing","uncertain","rejected","numerical","projection","absent","outside"]:
        cases.append(("break_"+kind,position,base,[sample(position,0),sample(position,1),sample(position,2,kind),sample(position,3)]))
    for name,last in [("shape_radius",sample(position,2,shape=assigned.disk(.25))),("shape_kind",sample(position,2,shape=assigned.convex())),
        ("shape_vertex_order",sample(position,2,shape=assigned.convex(assigned.DEFAULT[1:]+assigned.DEFAULT[:1]))),
        ("segment",sample(position,2,segment="2")),("closed",sample(position,2,"rejected",closed=["1"])),
        ("gap_priority",sample(position,11,"rejected",segment="2",closed=["1"]))]:
        shape=assigned.convex() if name=="shape_vertex_order" else assigned.disk()
        cases.append((name,position,base,[sample(position,0,shape=shape),sample(position,1,shape=shape),last]))
    for name,start,gap in [("beyond_double",9007199254740993,2),("near_max",MAX-3,2)]:
        cases.append((name,position,dict(base,max_gap_us=str(gap)),[sample(position,start),sample(position,start+1),sample(position,start+3)]))
    two=configuration("multi-zone",[assigned.position_reference.zone("narrow",multiplier=0),assigned.position_reference.zone("wide",[[-10,-10],[10,-10],[10,10],[-10,10]],0)])
    multi=[]
    for t in range(5):
        a,b=parts(sample(two,t,"inside" if t<3 else "outside"));other=assigned.position_reference.measured(two,t,(.5,.5),identity=9,segment="9")["tracks"][0];a["tracks"].insert(0,other);b["footprints"].append(assigned.assignment(other,assigned.convex()))
        multi.append(assigned.wrap(a,b))
    cases.append(("multi_target_zone_mixed",two,base,multi))
    return cases


def replay_checks(binary):
    records=[];reasons=set();cuts=0
    for name,position,config,wrapped in fixtures():
        frames=[parts(v)[0] for v in wrapped];documents=[parts(v)[1] for v in wrapped]
        current=native(binary,"--assigned-zone-evidence",[position]+wrapped)
        expected,saved=offline(position,config,wrapped,current);actual=native(binary,MODE,[source(position,config)]+wrapped)
        assert actual==expected,name
        assert native(binary,CHECKPOINT,[source(position,config)]+wrapped,count=1)[0]==saved,name
        for cut in range(len(wrapped)+1):
            checkpoint=native(binary,CHECKPOINT,[source(position,config)]+wrapped[:cut],count=1)[0]
            assert native(binary,MODE,[{"resume":checkpoint}]+wrapped[cut:])==actual[cut:],(name,cut)
            assert native(binary,CHECKPOINT,[{"resume":checkpoint}]+wrapped[cut:],count=1)[0]==saved;cuts+=1
        reasons.update(v["reason"] for frame in actual for v in frame["closed"])
        records.append({"name":name,"frames":len(wrapped),"active_rows":sum(len(v["active"]) for v in actual),"newly_confirmed":sum(len(v["confirmed"]) for v in actual),"closed_rows":sum(len(v["closed"]) for v in actual)})
    assert reasons=={"gap_exceeded","segment_closed","segment_changed","missing_target","unavailable_evidence","shape_changed","indeterminate_evidence","decision_changed"}
    return {"cases":len(records),"frames":sum(v["frames"] for v in records),"cut_points":cuts,"break_reasons":sorted(reasons),"newly_confirmed":sum(v["newly_confirmed"] for v in records),"closed_rows":sum(v["closed_rows"] for v in records),"current_v25_evidence_exact":True,"all_frame_and_checkpoint_fields_exact":True,"records":records}


def exhaustive_checks(binary):
    position=configuration("exhaustive");config={"max_gap_us":"10","confirmation_us":"2","min_samples":"2"};cases=list(itertools.product(["inside","outside","indeterminate"],repeat=4))
    flattened=[sample(position,i,kind) for sequence in cases for i,kind in enumerate(sequence)]
    evidence=native(binary,"--assigned-zone-evidence",[position]+flattened)
    for index,sequence in enumerate(cases):
        wrapped=flattened[index*4:index*4+4];expected,_=offline(position,config,wrapped,evidence[index*4:index*4+4]);assert native(binary,MODE,[source(position,config)]+wrapped)==expected,sequence
    return {"sequences":len(cases),"samples_per_sequence":4,"frames":len(flattened),"alphabet":["inside","outside","indeterminate"],"offline_suffix_reference":"passed"}


def strict_checks(binary):
    position=configuration();config={"max_gap_us":"10","confirmation_us":"2","min_samples":"2"};wrapped=[sample(position,t) for t in range(3)];head=source(position,config)
    saved=native(binary,CHECKPOINT,[head]+wrapped,count=1)[0];records=[]
    def bad_source(name,value):
        output,meta=execute(binary,MODE,[value],status=2);assert not output;records.append(dict(name=name,**meta))
    for name,value in [("unknown_header",dict(head,extra=1)),("position_not_raw",dict(head,position=position)),("options_not_raw",dict(head,options={})),
        ("missing_position",{"options":"{}"}),("duplicate_source",'{"position":"x",'+encode(head)[1:])]:bad_source(name,value)
    for key,value in [("min_samples","0"),("min_samples",2),("confirmation_us","-1"),("max_gap_us","0"),("max_gap_us","01")]:bad_source(key+str(value),source(position,dict(config,**{key:value})))
    mutations=[("version",lambda v:v.update(version=2)),("schema",lambda v:v.update(schema_version="1")),("empty_session",lambda v:v.update(session_id="")),
        ("missing_config",lambda v:v["config"].pop("min_samples")),("missing_sigma",lambda v:v["zones"][0].pop("sigma_multiplier")),
        ("wrong_last",lambda v:v.update(last_timestamp_us="3")),("unstarted_states",lambda v:v.update(last_timestamp_us=None)),
        ("negative_count",lambda v:v["states"][0]["run"].update(sample_count="-1")),("zero_count",lambda v:v["states"][0]["run"].update(sample_count="0")),
        ("count_exceeds_timeslots",lambda v:v["states"][0]["run"].update(sample_count="4")),("span_mismatch",lambda v:v["states"][0]["run"].update(sample_span_us="1")),
        ("first_after_last",lambda v:v["states"][0]["run"].update(first_timestamp_us="3")),("qualification_false",lambda v:v["states"][0]["run"].update(confirmed=False)),
        ("indeterminate",lambda v:v["states"][0]["run"].update(decision="indeterminate")),("rescore_outside",lambda v:v["states"][0].update(last_position_m=[2,.5])),
        ("non_spd",lambda v:v["states"][0].update(last_position_covariance=[1,2,1])),("changed_shape_indeterminate",lambda v:v["states"][0].update(shape=assigned.disk(1))),
        ("unknown_zone",lambda v:v["states"][0]["run"].update(zone_id="unknown")),("duplicate_state",lambda v:v["states"].append(copy.deepcopy(v["states"][0]))),
        ("gap_impossible",lambda v:v["config"].update(max_gap_us="1")),("unknown_checkpoint",lambda v:v.update(extra=True))]
    for name,mutate in mutations:
        changed=copy.deepcopy(saved);mutate(changed);bad_source(name,{"resume":changed})
    multi=configuration("cp-two",[assigned.position_reference.zone("one",multiplier=0),assigned.position_reference.zone("two",multiplier=0)])
    cp=native(binary,CHECKPOINT,[source(multi,config)]+[sample(multi,t) for t in range(3)],count=1)[0]
    for name,mutate in [("missing_definite_zone",lambda v:v["states"].pop()),("cross_zone_point",lambda v:v["states"][1].update(last_position_m=[.6,.5])),
        ("cross_zone_covariance",lambda v:v["states"][1].update(last_position_covariance=[.04,0,.04])),("cross_zone_shape",lambda v:v["states"][1].update(shape=assigned.disk(.25))),
        ("cross_zone_segment",lambda v:v["states"][1]["run"].update(segment_id="2"))]:
        changed=copy.deepcopy(cp);mutate(changed);bad_source(name,{"resume":changed})
    # These are complete CLI prefixes, not partially serialized failed frames.
    good=wrapped[0];prefix=native(binary,MODE,[head,good])
    frame,document=parts(sample(position,1));invalid=copy.deepcopy(document);invalid["footprints"][0]["shape"]=assigned.disk(1e-30)
    bad_values=[good,assigned.wrap(frame,invalid),dict(good,extra=True),assigned.wrap(frame,encode(document).replace('"track_id":1','"track_id":1.0000000000000001'))]
    for i,value in enumerate(bad_values):
        output,meta=execute(binary,MODE,[head,good,value],status=2);assert output==prefix;records.append(dict(name="failed_frame_{}".format(i),**meta))
        assert not execute(binary,CHECKPOINT,[head,good,value],status=2)[0]
    return {"rejected_cases":len(records),"records":records,"complete_native_prefix_preserved":True,"failed_checkpoint_mode_emits_no_checkpoint":True}


def overflow_checks(binary):
    position=configuration();head=source(position,{"max_gap_us":"2","confirmation_us":"0","min_samples":"1"})
    saved=native(binary,CHECKPOINT,[head,sample(position,0)],count=1)[0];state=saved["states"][0]
    state["run"].update(first_timestamp_us="0",last_timestamp_us=str(MAX-1),sample_span_us=str(MAX-1),sample_count=str(MAX),confirmed=True);saved["last_timestamp_us"]=str(MAX-1)
    # This count/span is feasible: exactly one sample at every representable
    # integer timestamp from zero through MAX-1, all gaps one microsecond.
    assert native(binary,CHECKPOINT,[{"resume":saved}],count=1)[0]==saved
    failed,metadata=execute(binary,MODE,[{"resume":saved},sample(position,MAX)],status=2);assert failed==[]
    corrected=native(binary,MODE,[{"resume":saved},sample(position,MAX,"outside")])[0]
    assert corrected["active"][0]["sample_count"]=="1" and corrected["closed"][0]["reason"]=="decision_changed"
    assert corrected["closed"][0]["run"]["sample_count"]==str(MAX)
    return {"status":"passed","saved_count":str(MAX),"same_timestamp_retry":str(MAX),"failed_update":metadata,"corrected_sample_count":"1","live_atomic_rollback_tested_by_core":True}


def transport_checks(binary):
    position=configuration();head=source(position);wrapped=sample(position,0);expected=native(binary,MODE,[head,wrapped])
    for ending in (b"\n",b"\r\n"):assert execute(binary,MODE,payload=ending.join(encode(v).encode() for v in [head,wrapped]))[0]==expected
    assert native(binary,MODE,[encode(head).ljust(1048576),encode(wrapped).ljust(1048576)])==expected
    actual,meta=execute(binary,MODE,[head,wrapped,encode(sample(position,1)).ljust(1048577)],status=2,extra=["--max-line-bytes","16777216"]);assert actual==expected
    _,missing=execute(binary,MODE,payload=b"",status=2)
    return {"exact_source_and_frame_utf16":1048576,"lf_crlf_unterminated_eof":"passed","overflow_prefix":meta,"missing_header":missing}


def web_checks(binary):
    command=["node","--test","--test-reporter=tap","web/footprint-run.test.mjs"]
    result=subprocess.run(command,cwd=str(ROOT),env=dict(os.environ,MOONGROUND_CLI=str(binary)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8",timeout=420)
    if result.returncode:raise AssertionError("Node footprint runs failed:\n"+result.stdout[-18000:]+result.stderr[-2000:])
    summary,cross,batch,maximum={},None,None,None
    for line in result.stdout.splitlines():
        match=re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$",line)
        if match:summary[match.group(1)]=int(match.group(2))
        if line.startswith('# {"cut_points":'):cross=json.loads(line[2:])
        if line.startswith('# {"successful_empty_frames":'):batch=json.loads(line[2:])
        if line.startswith('# {"maximum_actual_face_expansions":'):maximum=json.loads(line[2:])
    assert summary.get("tests")==summary.get("pass") and not summary.get("fail") and cross and batch and maximum
    return {"status":"passed","node":subprocess.check_output(["node","--version"],text=True).strip(),"command":" ".join(command),"summary":summary,"cross_runtime":cross,"actual_budgets":batch,"maximum_work_and_retained_state":maximum,
        "test_script_sha256":hashlib.sha256((ROOT/"web/footprint-run.test.mjs").read_bytes()).hexdigest(),"bridge_sha256":hashlib.sha256((ROOT/"_build/site/moonground.mjs").read_bytes()).hexdigest(),"stdout_sha256":hashlib.sha256(result.stdout.encode()).hexdigest()}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--binary",type=Path,required=True);parser.add_argument("--web",action="store_true");parser.add_argument("--output",type=Path,default=ROOT/"validation/footprint-run-results.json");args=parser.parse_args();binary=args.binary.resolve();started=time.perf_counter()
    result={"format_version":"1","fixtures":"deterministic","command":" ".join(shlex.quote(v) for v in [sys.executable]+sys.argv),"python":platform.python_version(),"toolchain":reference.toolchain_version(),"source_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "assigned_reference_sha256":hashlib.sha256(Path(assigned.__file__).read_bytes()).hexdigest(),"binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),"scope":SCOPE,"independent_reference":"Offline longest eligible suffix of actual v25 current evidence; Python integer sample counts/spans/qualification and closure priority; no physical dwell inference"}
    result["integer_run_reference"]=replay_checks(binary);result["bounded_exhaustive"]=exhaustive_checks(binary);result["strict_restore_and_raw"]=strict_checks(binary);result["int64_counter_overflow"]=overflow_checks(binary);result["transport"]=transport_checks(binary)
    if args.web:result["web_interchange"]=web_checks(binary)
    result.update(status="passed",elapsed_seconds=time.perf_counter()-started)
    with args.output.open("w",encoding="utf-8",newline="\n") as f:f.write(json.dumps(result,indent=2,ensure_ascii=True)+"\n")
    print(encode({"status":"passed","cases":result["integer_run_reference"]["cases"],"frames":result["integer_run_reference"]["frames"],"exhaustive_sequences":result["bounded_exhaustive"]["sequences"],"rejected":result["strict_restore_and_raw"]["rejected_cases"],"output":str(args.output)}))


if __name__=="__main__":main()
