#!/usr/bin/env python3
"""Independent old health and v27 footprint-run transactional composition.

Every successful frame and complete nested checkpoint is compared with the old
component CLI paths. NumPy landmark projection and integer run evidence remain
independent references; sampled spans are not physical dwell durations.
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

import footprint_run_analysis_verify as joint
import guarded_verify as guarded
import projection_replace_verify as replacement
import health_verify as health_reference
import checkpoint_verify as checkpoints
import gates_verify as gates
import verify as reference

ROOT=Path(__file__).resolve().parents[1]
MODE="--guarded-footprint-runs"
CHECKPOINT="--guarded-footprint-runs-checkpoint"
PREVIEW="--preview-guarded-footprint-run"
encode,native,execute=gates.encode,gates.native,gates.execute
assigned=joint.assigned
MAX=9223372036854775807


def combined(analysis,health):return {"format":"moonground.footprint-run-guarded","checkpoint_version":"1","analysis":analysis,"health":health}
def source(analysis,health):return guarded.source(analysis,health)
def adapt(old,multiplier=2,run_gap="500000"):
    old_analysis=json.loads(old["analysis"]);measurement=json.loads(old_analysis["measurement"])
    position=assigned.position_reference.configuration(measurement["session_id"],[assigned.position_reference.zone("wide",[[-100,-100],[100,-100],[100,100],[-100,100]],multiplier)],measurement["motion"].get("max_tracks",1000))
    return source(joint.source(measurement,joint.run_reference.source(position,{"min_samples":"2","confirmation_us":"100000","max_gap_us":run_gap})),old["health"])
def instant(name="instant-health-run",start=0,gap=3,run_gap=100):
    old,config=replacement.configuration(name,immediate=True);head=adapt(old,2,str(run_gap));h=json.loads(head["health"]);h["health"]["max_gap_us"]=str(gap);head["health"]=encode(h)
    a=json.loads(head["analysis"]);m=json.loads(a["measurement"]);m["motion"].update(min_span_us="0",max_gap_us="100",min_observations=2);a["measurement"]=encode(m);head["analysis"]=encode(a)
    frames=[replacement.observation_frame(h,start+t) for t in [0,1,gap+1,gap+2]]
    return name,head,frames

def fixtures():
    result=[("barrier_"+name,adapt(old),frames) for name,old,_,frames in replacement.fixtures()]
    result.extend(("health_"+name,adapt(old),frames) for name,old,_,frames in guarded.fixtures())
    result.extend([instant(),instant("instant-large-clock",9007199254740993),instant("instant-max-clock",MAX-5)])
    return result

def host_reference(binary,head,records):
    analysis=native(binary,joint.CHECKPOINT,[head["analysis"]],count=1)[0]
    health=native(binary,"--health-checkpoint",[head["health"]],count=1)[0]
    oracle=health_reference.Oracle(health["configuration"]);outputs=[];snapshots=[combined(analysis,health)];wrapped=[];previews=[];errors={}
    for index,value in enumerate(records):
        replacing="replace_projection" in value
        if replacing:
            control=json.loads(value["replace_projection"]);stamp=control["timestamp_us"]
            config=copy.deepcopy(health["configuration"]);replacement.change_projection(config,control if control["camera"] is not None else {"calibration":control["calibration"]})
            health_source=config;landmarks=health_reference.frame(stamp);objects=checkpoints.frame(stamp);oracle=health_reference.Oracle(config)
        else:
            objects=json.loads(value["measurement"]);landmarks=json.loads(value["health"]);health_source={"resume":health}
        report=native(binary,"--health",[health_source,landmarks],count=1)[0]
        health_reference.compare_report(report,oracle.update(landmarks),errors)
        allowed=not replacing and report["status"]=="healthy"
        effective=objects if allowed else checkpoints.frame(objects["timestamp_us"],removed=sorted(t["track_id"] for t in analysis["measurement"]["motion"]["tracks"]))
        measured=native(binary,joint.PREVIEW,[{"resume":analysis},effective],count=1)[0]["measurement"]
        doc=(json.loads(value["assignments"]) if "assignments" in value else joint.document(measured,0)) if allowed else assigned.bundle(measured,[])
        old_input=assigned.wrap(effective,doc)
        current=native(binary,joint.MODE,[{"resume":analysis},old_input],count=1)[0]
        next_analysis=native(binary,joint.CHECKPOINT,[{"resume":analysis},old_input],count=1)[0]
        next_health=native(binary,"--health-checkpoint",[health_source,landmarks],count=1)[0]
        if replacing:
            replacement.change_projection(next_analysis["measurement"]["configuration"],next_health["configuration"])
            wrapped.append(copy.deepcopy(value))
        else:wrapped.append(dict(value,assignments=encode(doc)))
        suppressed=[] if allowed or replacing else sorted(t["track_id"] for t in objects["observations"])
        output={"schema_version":"0.1.0","kind":"footprint_run_guarded_projection_replaced" if replacing else "footprint_run_guarded_frame","decision":"allowed" if allowed else "blocked","health":report,"analysis":current,"suppressed_track_ids":suppressed}
        outputs.append(output);previews.append({"decision":output["decision"],"health":report,"measurement":current["measurement"],"suppressed_track_ids":suppressed})
        analysis,health=next_analysis,next_health;snapshots.append(combined(analysis,health))
    return outputs,snapshots,wrapped,previews,errors

def replay_checks(binary):
    cases=[];cuts=0;errors={};statuses=set();reasons=set()
    for name,head,records in fixtures():
        expected,snapshots,wrapped,previews,numeric=host_reference(binary,head,records)
        assert native(binary,MODE,[head]+wrapped)==expected,name
        assert native(binary,CHECKPOINT,[head]+wrapped,count=1)[0]==snapshots[-1]
        for cut in range(len(records)+1):
            saved=native(binary,CHECKPOINT,[head]+wrapped[:cut],count=1)[0];assert saved==snapshots[cut],(name,cut)
            for resume in [{"resume":saved},source({"resume":saved["analysis"]},{"resume":saved["health"]})]:
                assert native(binary,MODE,[resume]+wrapped[cut:])==expected[cut:],(name,cut)
                assert native(binary,CHECKPOINT,[resume]+wrapped[cut:],count=1)[0]==snapshots[-1]
            if cut<len(records) and "replace_projection" not in records[cut]:
                assert native(binary,PREVIEW,[{"resume":saved},records[cut]],count=1)[0]==previews[cut]
                assert native(binary,CHECKPOINT,[{"resume":saved}],count=1)[0]==saved
            cuts+=1
        for key,value in numeric.items():errors[key]=max(errors.get(key,0),value)
        for output in expected:
            statuses.add(output["health"]["status"]);reasons.update(t["reason"] for t in output["analysis"]["runs"]["closed"])
        if name.startswith("instant"):
            assert all(t["decision"]=="allowed" for t in expected)
            assert snapshots[-1]["analysis"]["runs"]["states"][0]["run"]["first_timestamp_us"]==json.loads(records[1]["measurement"])["timestamp_us"]
        cases.append({"name":name,"frames":len(records),"allowed":sum(v["decision"]=="allowed" for v in expected),"blocked":sum(v["decision"]=="blocked" for v in expected),"barriers":sum("replace_projection" in v for v in records),"active_rows":sum(len(v["analysis"]["runs"]["active"]) for v in expected),"closed_rows":sum(len(v["analysis"]["runs"]["closed"]) for v in expected)})
    assert {"healthy","pending","drift","insufficient"}.issubset(statuses)
    return {"cases":len(cases),"frames":sum(v["frames"] for v in cases),"cut_points":cuts,"resume_source_forms":2,"health_statuses":sorted(statuses),"run_close_reasons":sorted(reasons),"full_old_component_outputs_and_checkpoints_exact":True,"numpy_health_maximum_absolute_errors":errors,"records":cases}


def strict_checks(binary):
    old,config,raw=replacement.fixture(name="strict-footprint-guard");head=adapt(old);expected,snapshots,frames,previews,_=host_reference(binary,head,raw[:4]);saved=snapshots[4];records=[]
    def bad(name,values,mode=MODE,prefix=()):
        out,meta=execute(binary,mode,values,status=2);assert out==list(prefix),name;records.append(dict(name=name,**meta))
    for name,value in [("unknown_source",dict(head,extra=True)),("analysis_not_raw",dict(head,analysis=json.loads(head["analysis"]))),("missing_health",{"analysis":head["analysis"]})]:bad(name,[value])
    def cpbad(name,mutate,independent=False):
        cp=copy.deepcopy(saved);mutate(cp)
        if independent:
            native(binary,joint.CHECKPOINT,[{"resume":cp["analysis"]}],count=1)
            native(binary,"--health-checkpoint",[{"resume":cp["health"]}],count=1)
        bad(name,[{"resume":cp}],CHECKPOINT)
    cpbad("version",lambda c:c.update(checkpoint_version="2"))
    cpbad("watermark",lambda c:c["health"]["state"].update(last_timestamp_us="400001"))
    cpbad("projection",lambda c:c["health"]["configuration"]["calibration"]["matrix"].__setitem__(2,.01),True)
    cpbad("noise",lambda c:c["health"]["configuration"]["calibration"].update(ground_noise_floor_m=.002),True)
    cpbad("roi_order",lambda c:c["health"]["configuration"]["calibration"]["roi"].reverse(),True)
    cpbad("nonhealthy_active",lambda c:c["health"]["state"].update(streak=None),True)
    cpbad("health_confirmation_after_segment",lambda c:c["health"]["state"]["streak"].update(since_us="100000"),True)
    cpbad("capacity",lambda c:c["analysis"]["runs"].update(max_tracks=2),True)
    prefix=expected[:1]
    for name,mutate in [("blocked_duplicate",lambda o:o["observations"].append(copy.deepcopy(o["observations"][0]))),("blocked_conflict",lambda o:o.update(lost=[1])),("blocked_spd",lambda o:o["observations"][0].update(covariance=[1,2,1]))]:
        value=copy.deepcopy(frames[1]);obj=json.loads(value["measurement"]);mutate(obj);value["measurement"]=encode(obj);bad(name,[head,frames[0],value],prefix=prefix)
    blocked=copy.deepcopy(frames[0]);doc=json.loads(blocked["assignments"]);doc["footprints"]=[{"track_id":1,"segment_id":"1","shape":assigned.disk()}];blocked["assignments"]=encode(doc);bad("blocked_nonempty_exact_policy",[head,blocked])
    timestamp=copy.deepcopy(frames[0]);timestamp["assignments"]=encode({"timestamp_us":"1","footprints":[]});bad("blocked_bundle_time",[head,timestamp])
    fraction=copy.deepcopy(frames[1]);fraction["measurement"]=fraction["measurement"].replace('"track_id":2','"track_id":2.0000000000000001');bad("blocked_fractional_raw_id",[head,frames[0],fraction],prefix=prefix)
    bad("unknown_frame",[head,dict(frames[0],extra=True)])
    bad("duplicate_raw_wrapper",[head,'{"measurement":"bad",'+encode(frames[0])[1:]])
    mismatch=copy.deepcopy(frames[0]);mismatch["health"]=encode(dict(json.loads(mismatch["health"]),timestamp_us="1"));bad("health_timestamp",[head,mismatch])
    # Valid raw objects which would fail ROI/numeric projection remain suppressed.
    ignored=copy.deepcopy(frames[0]);objects=json.loads(ignored["measurement"])
    for item in objects["observations"]:item.update(point=[1e308,-1e308],covariance=[1e300,0,1e300])
    ignored["measurement"]=encode(objects);out=native(binary,MODE,[head,ignored],count=1)[0];assert out["analysis"]["measurement"]["tracks"]==[] and out["suppressed_track_ids"]==[1,2]
    return {"rejected_cases":len(records),"records":records,"independently_valid_component_mismatches":True,"blocked_skips_projection_and_footprint_math":True}


def instant_checkpoint_checks(binary):
    _,head,raw=instant();expected,snapshots,frames,_,_=host_reference(binary,head,raw);saved=snapshots[-1];records=[]
    def bad(name,cp):
        native(binary,joint.CHECKPOINT,[{"resume":cp["analysis"]}],count=1);native(binary,"--health-checkpoint",[{"resume":cp["health"]}],count=1)
        out,meta=execute(binary,CHECKPOINT,[{"resume":cp}],status=2);assert not out;records.append(dict(name=name,**meta))
    # F=1,S=4,T=5. Original true run contains samples1,4,5 and motion0,1,4,5.
    assert saved["analysis"]["runs"]["states"]
    cp=copy.deepcopy(saved);cp["analysis"]["runs"]["config"]["max_gap_us"]="3";bad("restart_gap_requires_run_gap_larger",cp)
    cp=copy.deepcopy(saved)
    for state in cp["analysis"]["runs"]["states"]:state["run"]["sample_count"]="5"
    for track in cp["analysis"]["measurement"]["motion"]["tracks"]:track["accepted_count"]=6
    bad("forbidden_restart_gap_integer_slots",cp)
    cp=copy.deepcopy(saved)
    for state in cp["analysis"]["runs"]["states"]:state["run"]["sample_count"]="2"
    for track in cp["analysis"]["measurement"]["motion"]["tracks"]:track["accepted_count"]=3
    bad("health_since_target_accepted_witness",cp)
    cp=copy.deepcopy(saved)
    for state in cp["analysis"]["runs"]["states"]:state["run"]["sample_count"]="2"
    bad("health_since_run_suffix_lower_bound",cp)
    return {"true_instant_restart_continues_run_and_restores":True,"independently_legal_counterexamples":len(records),"records":records}


def atomic_checks(binary):
    old,_,raw=replacement.fixture(name="atomic-footprint-health");head=adapt(old);expected,snapshots,frames,_,_=host_reference(binary,head,raw[:4]);records=[]
    # First Healthy creates an Initializing segment, so exact identity failure
    # exercises health confirmation rollback without claiming footprint math ran.
    wrong=copy.deepcopy(frames[2]);doc=json.loads(wrong["assignments"]);doc["footprints"][0]["segment_id"]="99";wrong["assignments"]=encode(doc)
    out,meta=execute(binary,MODE,[head]+frames[:2]+[wrong],status=2);assert out==expected[:2];records.append(meta)
    assert not execute(binary,CHECKPOINT,[{"resume":snapshots[2]},wrong],status=2)[0]
    assert native(binary,CHECKPOINT,[{"resume":snapshots[2]},frames[2]],count=1)[0]==snapshots[3]
    tiny=copy.deepcopy(frames[3]);doc=json.loads(tiny["assignments"])
    for value in doc["footprints"]:value["shape"]=assigned.disk(1e-30)
    tiny["assignments"]=encode(doc)
    out,meta=execute(binary,MODE,[head]+frames[:3]+[tiny],status=2);assert out==expected[:3];records.append(meta)
    assert not execute(binary,CHECKPOINT,[{"resume":snapshots[3]},tiny],status=2)[0]
    assert native(binary,CHECKPOINT,[{"resume":snapshots[3]},frames[3]],count=1)[0]==snapshots[4]
    assert native(binary,CHECKPOINT,[{"resume":snapshots[3]}],count=1)[0]==snapshots[3]
    _,instant_head,instant_raw=instant("atomic-instant-restart")
    instant_outputs,instant_saved,instant_frames,_,_=host_reference(binary,instant_head,instant_raw)
    failing=copy.deepcopy(instant_frames[2]);document=json.loads(failing["assignments"])
    for value in document["footprints"]:value["shape"]=assigned.disk(1e-30)
    failing["assignments"]=encode(document)
    out,meta=execute(binary,MODE,[instant_head]+instant_frames[:2]+[failing],status=2);assert out==instant_outputs[:2];records.append(meta)
    assert not execute(binary,CHECKPOINT,[{"resume":instant_saved[2]},failing],status=2)[0]
    assert instant_saved[2]["health"]["state"]["streak"]["since_us"]=="0"
    assert native(binary,CHECKPOINT,[{"resume":instant_saved[2]},instant_frames[2]],count=1)[0]==instant_saved[3]
    assert instant_saved[3]["health"]["state"]["streak"]["since_us"]=="4"
    return {"status":"passed","first_Healthy_identity_first_Ready_numeric_and_instant_restart_failures":records,"instant_health_restart_since_preserved_on_failure":True,"same_timestamp_corrections_full_checkpoint_exact":True,"live_same_preparation_retry_and_stale_tested_by_core_consumers":True}


def transport_checks(binary):
    _,head,raw=instant("transport-instant");expected,_,frames,previews,_=host_reference(binary,head,raw[:1]);out=native(binary,PREVIEW,[head,raw[0]],count=1);assert out==previews
    assert not execute(binary,PREVIEW,[head],status=2)[0]
    assert execute(binary,PREVIEW,[head,raw[0],raw[0]],status=2)[0]==previews
    assert native(binary,PREVIEW,[head,raw[0]],count=1)==out
    assert not execute(binary,MODE,payload=b"",status=2)[0]
    for ending in (b"\n",b"\r\n"):assert execute(binary,MODE,payload=ending.join(encode(v).encode() for v in [head,frames[0]]))[0]==expected
    assert native(binary,MODE,[head,encode(frames[0]).ljust(1048576)])==expected
    assert not execute(binary,CHECKPOINT,[head,encode(frames[0]).ljust(1048577)],status=2,extra=["--max-line-bytes","16777216"])[0]
    assert native(binary,CHECKPOINT,[encode(head).ljust(8388619)],extra=["--max-line-bytes","16777216"],count=1)
    assert not execute(binary,CHECKPOINT,[encode(head).ljust(8388620)],extra=["--max-line-bytes","16777216"],status=2)[0]
    return {"read_only_single_preview_exactly_one_pair":True,"frame_utf16":1048576,"source_utf16":8388619,"lf_crlf_unterminated_eof":"passed"}


def web_checks(binary):
    command=["node","--test","--test-reporter=tap","web/footprint-run-guarded.test.mjs"]
    result=subprocess.run(command,cwd=str(ROOT),env=dict(os.environ,MOONGROUND_CLI=str(binary)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8",timeout=600)
    if result.returncode:raise AssertionError(result.stdout[-22000:]+result.stderr[-2000:])
    summary={};details={}
    for value in result.stdout.splitlines():
        match=re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$",value)
        if match:summary[match.group(1)]=int(match.group(2))
        for prefix,key in [("cut_points","cross_runtime"),("empty_frame_count","actual_budgets"),("maximum_actual_face_expansions","maximum_work"),("warm_reframe_maximum_absolute_error","warm_reframe")]:
            if value.startswith('# {"'+prefix+'":'):details[key]=json.loads(value[2:])
    assert summary.get("tests")==summary.get("pass") and not summary.get("fail") and len(details)==4
    return {"status":"passed","command":" ".join(command),"summary":summary,"details":details,"node":subprocess.check_output(["node","--version"],text=True).strip(),"source_sha256":hashlib.sha256((ROOT/"web/footprint-run-guarded.test.mjs").read_bytes()).hexdigest(),"bridge_sha256":hashlib.sha256((ROOT/"_build/site/moonground.mjs").read_bytes()).hexdigest(),"stdout_sha256":hashlib.sha256(result.stdout.encode()).hexdigest()}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--binary",type=Path,required=True);parser.add_argument("--web",action="store_true");parser.add_argument("--output",type=Path,default=ROOT/"validation/footprint-run-guarded-results.json");args=parser.parse_args();binary=args.binary.resolve();started=time.perf_counter();version=reference.toolchain_version();assert "0.10.18" in str(version)
    result={"format_version":"1","fixtures":"deterministic","command":" ".join(shlex.quote(v) for v in [sys.executable]+sys.argv),"python":platform.python_version(),"toolchain":version,"inherited_moon_home":os.environ.get("MOON_HOME"),"source_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"component_reference_sha256":hashlib.sha256(Path(joint.__file__).read_bytes()).hexdigest(),"health_reference_sha256":hashlib.sha256(Path(health_reference.__file__).read_bytes()).hexdigest(),"binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),"scope":"health_controlled_confirmed_sample_spans_not_physical_dwell","independent_reference":"Old health reports/checkpoints + old v27 measurement/run reports/checkpoints; NumPy landmark calibration reference; explicit removed-all barrier reconstructed from committed motion CP"}
    result["component_reference"]=replay_checks(binary);result["strict_restore_and_raw"]=strict_checks(binary);result["instant_restart_binding"]=instant_checkpoint_checks(binary);result["atomic_failure"]=atomic_checks(binary);result["transport"]=transport_checks(binary)
    if args.web:result["web_interchange"]=web_checks(binary)
    result.update(status="passed",elapsed_seconds=time.perf_counter()-started)
    with args.output.open("w",encoding="utf-8",newline="\n") as f:f.write(json.dumps(result,indent=2,ensure_ascii=True)+"\n")
    print(encode({"status":"passed","cases":result["component_reference"]["cases"],"frames":result["component_reference"]["frames"],"cuts":result["component_reference"]["cut_points"],"strict_rejects":result["strict_restore_and_raw"]["rejected_cases"],"output":str(args.output)}))

if __name__=="__main__":main()
