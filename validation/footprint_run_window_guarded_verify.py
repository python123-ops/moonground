#!/usr/bin/env python3
"""Independent health controlled raw footprint runs and report-time windows.

Old guarded outputs and complete checkpoints are one component reference. The
separate old assigned-evidence/backward-run oracle and Python bigint grouping
check current shapes, sampled confirmations/endings and exact report buckets.
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

import footprint_run_guarded_verify as guarded_reference
import footprint_run_window_analysis_verify as joint_reference
import footprint_run_windows_verify as window_reference
import footprint_run_verify as run_reference
import gates_verify as gates
import verify as reference

ROOT=Path(__file__).resolve().parents[1]
MODE="--guarded-footprint-run-windows"
CHECKPOINT="--guarded-footprint-run-windows-checkpoint"
PREVIEW="--preview-guarded-footprint-run-window"
MAX=9223372036854775807
encode,native,execute=gates.encode,gates.native,gates.execute
assigned=run_reference.assigned


def source(guarded,width=300000,origin=0):
    return {"guarded":encode(guarded),"window":encode({"window_us":str(width),"origin_us":str(origin)})}


def combined(analysis,health):
    return {"format":"moonground.footprint-run-window-guarded","checkpoint_version":"1","analysis":analysis,"health":health}


def fixtures():
    values=[(name,head,frames,0,300000,0) for name,head,frames in guarded_reference.fixtures()]
    name,head,frames=guarded_reference.instant("window-started-health")
    values.append(("started_pending_run",head,frames,2,100,0))
    confirmed=copy.deepcopy(head);analysis=json.loads(confirmed["analysis"]);runs=json.loads(analysis["runs"])
    runs["options"]=encode({"min_samples":"1","confirmation_us":"0","max_gap_us":"100"})
    analysis["runs"]=encode(runs);confirmed["analysis"]=encode(analysis)
    values.append(("started_confirmed_run",confirmed,frames,3,100,0))
    return values


def component_chain(binary,head,raw,cut=0,width=300000,origin=0):
    old,snapshots,wrapped,previews,errors=guarded_reference.host_reference(binary,head,raw)
    # Full old guarded owner independently confirms each host-generated frame.
    assert native(binary,guarded_reference.MODE,[head]+wrapped)==old
    assert native(binary,guarded_reference.CHECKPOINT,[head]+wrapped,count=1)[0]==snapshots[-1]
    initial=snapshots[cut]["analysis"]["runs"]
    current_frames=[v["analysis"]["runs"] for v in old]
    run_head=json.loads(json.loads(head["analysis"])["runs"])
    position,options=json.loads(run_head["position"]),json.loads(run_head["options"])
    measured_wrapped=[]
    for value,original in zip(old,wrapped):
        measured=value["analysis"]["measurement"]
        doc=json.loads(original["assignments"]) if "assignments" in original else {"timestamp_us":measured["timestamp_us"],"footprints":[]}
        measured_wrapped.append(assigned.wrap(measured,doc))
    independently_checked,old_cp=window_reference.component(binary,position,options,measured_wrapped)
    assert independently_checked==current_frames
    assert old_cp==snapshots[-1]["analysis"]["runs"]
    windows,current=window_reference.oracle(initial,width,origin,current_frames[cut:])
    old_window_source=window_reference.source({"resume":initial},width,origin)
    assert native(binary,window_reference.STREAM,[old_window_source]+measured_wrapped[cut:])==windows
    outputs=[];saved=[]
    initial_window=window_reference.checkpoint(initial,width,origin,initial["last_timestamp_us"],None)
    saved.append(combined(joint_reference.combined(snapshots[cut]["analysis"]["measurement"],initial_window),snapshots[cut]["health"]))
    for i,(value,window) in enumerate(zip(old[cut:],windows)):
        original=copy.deepcopy(value)
        original["kind"]="footprint_run_window_guarded_projection_replaced" if "replace_projection" in wrapped[cut+i] else "footprint_run_window_guarded_frame"
        original["analysis"]={"schema_version":"0.1.0","kind":"footprint_run_window_analysis_frame","measurement":value["analysis"]["measurement"],"windows":window}
        outputs.append(original)
        snapshot=snapshots[cut+i+1]
        window_cp=window_reference.checkpoint(snapshot["analysis"]["runs"],width,origin,initial["last_timestamp_us"],window["statistics"]["current_window"])
        saved.append(combined(joint_reference.combined(snapshot["analysis"]["measurement"],window_cp),snapshot["health"]))
    original_source={"resume":snapshots[cut]} if cut else head
    return source(original_source,width,origin),outputs,saved,wrapped[cut:],previews[cut:],errors


def replay_checks(binary):
    records=[];cuts=0;errors={};statuses=set();reasons=set()
    for name,old,raw,cut,width,origin in fixtures():
        head,expected,saved,frames,previews,numeric=component_chain(binary,old,raw,cut,width,origin)
        assert native(binary,MODE,[head]+frames)==expected,name
        assert native(binary,CHECKPOINT,[head]+frames,count=1)[0]==saved[-1],name
        if name=="started_confirmed_run":
            row=expected[0]["analysis"]["windows"]["statistics"]["current_window"]["zones"][0]
            assert row["opening_confirmed"]=="2" and row["confirmed_inside"]=="0"
        for split in range(len(frames)+1):
            cp=native(binary,CHECKPOINT,[head]+frames[:split],count=1)[0];assert cp==saved[split],(name,split)
            assert native(binary,MODE,[{"resume":cp}]+frames[split:])==expected[split:]
            assert native(binary,CHECKPOINT,[{"resume":cp}]+frames[split:],count=1)[0]==saved[-1]
            if split<len(frames) and "replace_projection" not in frames[split]:
                pair={k:frames[split][k] for k in ["measurement","health"]}
                assert native(binary,PREVIEW,[{"resume":cp},pair],count=1)[0]==previews[split]
                assert native(binary,CHECKPOINT,[{"resume":cp}],count=1)[0]==cp
            cuts+=1
        for key,value in numeric.items():errors[key]=max(errors.get(key,0),value)
        for value in expected:
            statuses.add(value["health"]["status"])
            reasons.update(v["reason"] for v in value["analysis"]["windows"]["runs"]["closed"])
        records.append({"name":name,"frames":len(frames),"baseline_frames":cut,"allowed":sum(v["decision"]=="allowed" for v in expected),"blocked":sum(v["decision"]=="blocked" for v in expected),"barriers":sum("replace_projection" in v for v in frames),"confirmations":sum(len(v["analysis"]["windows"]["runs"]["confirmed"]) for v in expected),"endings":sum(len(v["analysis"]["windows"]["runs"]["closed"]) for v in expected)})
    assert {"healthy","pending","drift","insufficient"}.issubset(statuses)
    return {"cases":len(records),"frames":sum(v["frames"] for v in records),"cut_points":cuts,"health_statuses":sorted(statuses),"ending_reasons_observed":sorted(reasons),"full_old_guarded_and_backward_runs_bigint_windows_exact":True,"numpy_health_maximum_absolute_errors":errors,"records":records}


def independent_components(binary,cp):
    native(binary,joint_reference.CHECKPOINT,[{"resume":cp["analysis"]}],count=1)
    old=guarded_reference.combined(guarded_reference.joint.combined(cp["analysis"]["measurement"],cp["analysis"]["windows"]["runs"]),cp["health"])
    native(binary,guarded_reference.CHECKPOINT,[{"resume":old}],count=1)


def synthetic(binary,name,times,shape_since=0,samples=1):
    _,old,_=guarded_reference.instant(name,gap=4,run_gap=100)
    h=json.loads(old["health"]);h["health"].update(min_observations=samples,confirmation_us="0");old["health"]=encode(h)
    a=json.loads(old["analysis"]);r=json.loads(a["runs"]);r["options"]=encode({"min_samples":"1","confirmation_us":"0","max_gap_us":"100"});a["runs"]=encode(r);old["analysis"]=encode(a)
    raw=[guarded_reference.replacement.observation_frame(h,t) for t in times]
    # One genuine target is enough for the sparse interval counterexamples.
    for value in raw:
        obj=json.loads(value["measurement"]);obj["observations"]=[v for v in obj["observations"] if v["track_id"]==1];value["measurement"]=encode(obj)
    expected,snapshots,wrapped,_,_=guarded_reference.host_reference(binary,old,raw)
    for frame,value in zip(wrapped,expected):
        t=int(value["health"]["timestamp_us"])
        if t<shape_since:frame["assignments"]=encode({"timestamp_us":str(t),"footprints":[]})
    # Re-evaluate with explicit omissions so source runs agree with actual docs.
    head,_,saved,frames,_,_=component_chain(binary,old,wrapped,width=100)
    return head,frames,saved[-1]


def strict_checks(binary):
    records=[]
    def bad(name,values,mode=CHECKPOINT,prefix=()):
        out,meta=execute(binary,mode,values,status=2);assert out==list(prefix),name;records.append(dict(name=name,**meta))
    head,frames,saved=synthetic(binary,"guard-window-strict",[0,1,2])
    for name,value in [("unknown_source",dict(head,extra=True)),("guarded_not_raw",dict(head,guarded={})),("window_number",dict(head,window='{"window_us":100}')),("noncanonical_width",dict(head,window='{"window_us":"0100"}'))]:bad(name,[value])
    for name,change in [("version",lambda c:c.update(checkpoint_version="2")),("watermark",lambda c:c["health"]["state"].update(last_timestamp_us="3")),("calibration",lambda c:c["health"]["configuration"]["calibration"]["matrix"].__setitem__(2,.01)),("nonHealthy_active",lambda c:c["health"]["state"].update(streak=None))]:
        changed=copy.deepcopy(saved);change(changed);bad(name,[{"resume":changed}])
    prefix=native(binary,MODE,[head,frames[0]])
    for name,change in [("duplicate_raw",lambda f:'{"measurement":"bad",'+encode(f)[1:]),("unknown_frame",lambda f:dict(f,extra=True)),("fractional_raw_id",lambda f:dict(f,measurement=f["measurement"].replace('"track_id":1','"track_id":1.0000000000000001'))), ("health_time",lambda f:dict(f,health=encode(dict(json.loads(f["health"]),timestamp_us="99"))))]:
        bad(name,[head,frames[0],change(copy.deepcopy(frames[1]))],MODE,prefix)
    return {"rejected_cases":len(records),"records":records}


def health_window_checks(binary):
    records=[]
    def bad(name,cp):
        independent_components(binary,cp)
        out,meta=execute(binary,CHECKPOINT,[{"resume":cp}],status=2);assert not out;records.append(dict(name=name,**meta))
    _,_,cp=synthetic(binary,"local-health-gap",[0,1,8,20],shape_since=8)
    cp["health"]["state"]["streak"]["since_us"]="0"
    cp["analysis"]["measurement"]["motion"]["tracks"][0]["accepted_count"]=10
    cp["analysis"]["windows"]["current_window"]["input_frames"]="10"
    for state in cp["analysis"]["windows"]["runs"]["states"]:state["run"]["sample_count"]="9"
    bad("local_health_bridges_exceed_exact_suffix_interval",cp)
    good=copy.deepcopy(cp);good["health"]["configuration"]["health"]["max_gap_us"]="9"
    assert native(binary,CHECKPOINT,[{"resume":good}],count=1)[0]==good
    _,_,cp=synthetic(binary,"instant-forbidden-slots",[0,1,10,11],shape_since=11)
    cp["analysis"]["measurement"]["motion"]["tracks"][0]["accepted_count"]=2
    cp["analysis"]["windows"]["current_window"]["input_frames"]="10"
    bad("instant_restart_forbidden_global_slots",cp)
    good=copy.deepcopy(cp);good["analysis"]["windows"]["current_window"]["input_frames"]="9"
    assert native(binary,CHECKPOINT,[{"resume":good}],count=1)[0]==good
    _,_,cp=synthetic(binary,"pending-health-exact",[0,1,2],samples=5)
    cp["health"]["state"]["streak"]["observations"]=2
    bad("Pending_unsaturated_exact_suffix_disagrees",cp)
    _,_,cp=synthetic(binary,"omitted-health-first",[0,1,2],samples=5)
    cp["analysis"]["windows"]["current_window"].update(first_timestamp_us="1",input_frames="2")
    bad("health_since_missing_before_observed_first",cp)
    return {"independently_legal_component_counterexamples":len(records),"local_gap_and_instant_boundary_positive_controls":2,"records":records}


def atomic_checks(binary):
    records=[]
    old,_,raw=guarded_reference.replacement.fixture(name="window-atomic-health")
    head,expected,saved,frames,_,_=component_chain(binary,guarded_reference.adapt(old),raw[:4])
    for index,identity in [(2,True),(3,False)]:
        failed=copy.deepcopy(frames[index]);doc=json.loads(failed["assignments"])
        if identity:doc["footprints"][0]["segment_id"]="99"
        else:
            for value in doc["footprints"]:value["shape"]=assigned.disk(1e-30)
        failed["assignments"]=encode(doc)
        out,meta=execute(binary,MODE,[head]+frames[:index]+[failed],status=2);assert out==expected[:index];records.append(meta)
        assert not execute(binary,CHECKPOINT,[{"resume":saved[index]},failed],status=2)[0]
        assert native(binary,CHECKPOINT,[{"resume":saved[index]},frames[index]],count=1)[0]==saved[index+1]
        assert native(binary,CHECKPOINT,[{"resume":saved[index]}],count=1)[0]==saved[index]
    _,old,raw=guarded_reference.instant("window-atomic-restart")
    head,expected,saved,frames,_,_=component_chain(binary,old,raw)
    failed=copy.deepcopy(frames[2]);doc=json.loads(failed["assignments"])
    for v in doc["footprints"]:v["shape"]=assigned.disk(1e-30)
    failed["assignments"]=encode(doc)
    out,meta=execute(binary,MODE,[head]+frames[:2]+[failed],status=2);assert out==expected[:2];records.append(meta)
    assert saved[2]["health"]["state"]["streak"]["since_us"]=="0"
    assert native(binary,CHECKPOINT,[{"resume":saved[2]},frames[2]],count=1)[0]==saved[3]
    return {"status":"passed","failure_records":records,"first_Healthy_identity_and_late_Ready_physical_failures":True,"health_restart_streak_motion_P_nextsegment_runs_windows_full_checkpoint_same_timestamp_retry":True,"live_prepared_retry_and_hidden_interrupt_core_consumer":True}


def transport_checks(binary):
    _,old,raw=guarded_reference.instant("window-health-transport")
    head,expected,_,frames,previews,_=component_chain(binary,old,raw[:1])
    pair={k:frames[0][k] for k in ["measurement","health"]}
    assert native(binary,PREVIEW,[head,pair],count=1)==previews
    assert not execute(binary,PREVIEW,[head],status=2)[0]
    assert execute(binary,PREVIEW,[head,pair,pair],status=2)[0]==previews
    for ending in [b"\n",b"\r\n"]:assert execute(binary,MODE,payload=ending.join(encode(v).encode() for v in [head,frames[0]]))[0]==expected
    assert native(binary,MODE,[head,encode(frames[0]).ljust(1048576)])==expected
    assert not execute(binary,CHECKPOINT,[head,encode(frames[0]).ljust(1048577)],status=2,extra=["--max-line-bytes","16777216"])[0]
    assert native(binary,CHECKPOINT,[encode(head).ljust(8388619)],count=1,extra=["--max-line-bytes","16777216"])
    assert not execute(binary,CHECKPOINT,[encode(head).ljust(8388620)],status=2,extra=["--max-line-bytes","16777216"])[0]
    assert not execute(binary,MODE,payload=b"",status=2)[0]
    return {"single_readonly_preview_exactly_one_pair":True,"frame_utf16":1048576,"source_utf16":8388619,"LF_CRLF_unterminated_EOF":"passed"}


def web_checks(binary):
    command=["node","--test","--test-reporter=tap","web/footprint-run-window-guarded.test.mjs"]
    process=subprocess.run(command,cwd=str(ROOT),env=dict(os.environ,MOONGROUND_CLI=str(binary)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8",timeout=900)
    if process.returncode:raise AssertionError(process.stdout[-30000:]+process.stderr[-2000:])
    summary={};details={}
    for value in process.stdout.splitlines():
        match=re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$",value)
        if match:summary[match.group(1)]=int(match.group(2))
        for prefix,key in [("cut_points","cross_runtime"),("empty_frame_count","actual_budgets"),("maximum_actual_face_expansions","maximum_work"),("warm_reframe_maximum_absolute_error","warm_reframe")]:
            if value.startswith('# {"'+prefix+'":'):details[key]=json.loads(value[2:])
    assert summary.get("tests")==summary.get("pass") and not summary.get("fail") and len(details)==4
    return {"status":"passed","summary":summary,"details":details,"command":" ".join(command),"node":subprocess.check_output(["node","--version"],text=True).strip(),"source_sha256":hashlib.sha256((ROOT/"web/footprint-run-window-guarded.test.mjs").read_bytes()).hexdigest(),"bridge_sha256":hashlib.sha256((ROOT/"_build/site/moonground.mjs").read_bytes()).hexdigest(),"stdout_sha256":hashlib.sha256(process.stdout.encode()).hexdigest()}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--binary",type=Path,required=True);parser.add_argument("--web",action="store_true");parser.add_argument("--output",type=Path,default=ROOT/"validation/footprint-run-window-guarded-results.json");args=parser.parse_args();binary=args.binary.resolve();started=time.perf_counter()
    version=reference.toolchain_version();assert "0.10.18" in str(version),version
    result={"format_version":"1","fixtures":"deterministic","command":" ".join(shlex.quote(v) for v in [sys.executable]+sys.argv),"python":platform.python_version(),"toolchain":version,"pinned_moon_home":os.environ.get("MOON_HOME"),"source_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"guarded_reference_sha256":hashlib.sha256(Path(guarded_reference.__file__).read_bytes()).hexdigest(),"window_reference_sha256":hashlib.sha256(Path(window_reference.__file__).read_bytes()).hexdigest(),"binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),"independent_reference":"Old guarded owner plus old assigned evidence, independent backward suffix runs, NumPy fixed-landmark health and bigint report-time grouping","scope":"observed_report_frame_confirmations_and_endings_under_explicit_footprints_not_visits_or_physical_dwell"}
    result["component_reference"]=replay_checks(binary);result["strict_restore_and_raw"]=strict_checks(binary);result["health_window_binding"]=health_window_checks(binary);result["atomic_failure"]=atomic_checks(binary);result["transport"]=transport_checks(binary)
    if args.web:result["web_interchange"]=web_checks(binary)
    result.update(status="passed",elapsed_seconds=time.perf_counter()-started)
    with args.output.open("w",encoding="utf-8",newline="\n") as f:f.write(json.dumps(result,indent=2,ensure_ascii=True)+"\n")
    print(encode({"status":"passed","cases":result["component_reference"]["cases"],"frames":result["component_reference"]["frames"],"cuts":result["component_reference"]["cut_points"],"rejects":result["strict_restore_and_raw"]["rejected_cases"],"binding_rejects":result["health_window_binding"]["independently_legal_component_counterexamples"],"output":str(args.output)}))


if __name__=="__main__":main()
