#!/usr/bin/env python3
"""Independent explicit disk support plus current position covariance bands.

Decimal evaluates raw-edge distance, the full covariance quadratic form and
deterministic disk support independently of the production expansion. The old
zone path separately checks exact radius-zero reduction and preserved position
endpoints. No physical footprint is inferred from detector or velocity data.
"""

import argparse
import copy
import decimal
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import sys
import time

import numpy as np

import analysis_verify as analysis_reference
import camera_verify as camera_reference
import checkpoint_verify as checkpoints
import gates_verify as gates
import reframe_verify as reframe_reference
import verify as reference
import zone_verify as position_reference


ROOT=Path(__file__).resolve().parents[1]
MODE="--disk-zone-evidence"
SCOPE="model_position_halfplane_bands_plus_explicit_disk"
encode,native,run=gates.encode,gates.native,gates.execute
D=decimal.Decimal


def source(position,radius=.125):
    return {"position":position if isinstance(position,str) else encode(position),"disk":encode({"radius_m":radius})}


def exact_band(selected,position,covariance,radius):
    old=position_reference.exact_band(selected,position,covariance)
    orientation=position_reference.winding([list(map(float,p)) for p in selected["vertices_m"]])
    faces=[]
    with decimal.localcontext() as context:
        context.prec=220
        xx,xy,yy=[D.from_float(float(v)) for v in covariance]
        k=D.from_float(float(selected.get("sigma_multiplier",2)))
        r=D.from_float(float(radius))
        for face,start,normal in zip(old["faces"],selected["vertices_m"],position_reference.normals(selected)):
            end=selected["vertices_m"][(face["edge_index"]+1)%len(selected["vertices_m"])]
            dx,dy=[D.from_float(float(end[i])-float(start[i])) for i in (0,1)]
            x,y=[D.from_float(float(position[i])-float(start[i])) for i in (0,1)]
            nx,ny=[D.from_float(v) for v in normal]
            distance=orientation*(dy*x-dx*y)/(dx*dx+dy*dy).sqrt()
            deviation=(nx*nx*xx+2*nx*ny*xy+ny*ny*yy).sqrt()
            spread=k*deviation+r
            faces.append(dict(face,position_lower_m=face["lower_m"],position_upper_m=face["upper_m"],
                lower_m=float(distance-spread),upper_m=float(distance+spread)))
    separated=[face["edge_index"] for face in faces if face["lower_m"]>0]
    decision="inside" if all(face["upper_m"]<=0 for face in faces) else "outside" if separated else "indeterminate"
    return {"zone_id":selected["zone_id"],"radius_m":radius,"sigma_multiplier":selected.get("sigma_multiplier",2),
        "faces":faces,"decision":decision,"separating_edge_index":separated[0] if separated else None}


def oracle(position,radius,frame):
    evidence,unavailable=[],[]
    for item in sorted(frame["tracks"],key=lambda value:value["track_id"]):
        if item["status"]!="ready":
            unavailable.append({"track_id":item["track_id"],"segment_id":item["segment_id"],"reason":item["status"]})
        else:
            for selected in position["zones"]:
                evidence.append(dict(track_id=item["track_id"],segment_id=item["segment_id"],
                    **exact_band(selected,item["position_m"],item["position_covariance"],radius)))
    return {"schema_version":"0.1.0","kind":"disk_zone_evidence_frame","evidence_scope":SCOPE,
        "session_id":frame["session_id"],"timestamp_us":frame["timestamp_us"],"evidence":evidence,"unavailable":unavailable}


def verify_preservation(actual,original,radius):
    assert actual["unavailable"]==original["unavailable"]
    assert len(actual["evidence"])==len(original["evidence"])
    for disk,point in zip(actual["evidence"],original["evidence"]):
        assert disk["radius_m"]==radius
        for key in ("track_id","segment_id","zone_id","sigma_multiplier"):assert disk[key]==point[key]
        for combined,base in zip(disk["faces"],point["faces"]):
            for key in ("edge_index","outward_normal","distance_m","normal_std_m"):assert combined[key]==base[key]
            assert combined["position_lower_m"]==base["lower_m"] and combined["position_upper_m"]==base["upper_m"]
            if radius==0:
                assert combined["lower_m"]==base["lower_m"] and combined["upper_m"]==base["upper_m"]
            else:
                assert combined["lower_m"]<base["lower_m"] and combined["upper_m"]>base["upper_m"]
        if radius==0:
            assert disk["decision"]==point["decision"] and disk["separating_edge_index"]==point["separating_edge_index"]


def fixtures():
    cases=[]
    for name,position,frames in position_reference.fixtures():
        extent=max(max(p[i] for p in selected["vertices_m"])-min(p[i] for p in selected["vertices_m"])
            for selected in position["zones"] for i in (0,1))
        for radius in (0,.03125*extent):cases.append((name+("_point_reduction" if radius==0 else "_explicit_body"),position,radius,frames))
    for k in (0,1,2):
        position=position_reference.configuration("disk-tangencies-{}".format(k),[position_reference.zone(multiplier=k)])
        points=[(.5,.5),(.875,.5),(1.125,.5),(1.25,.5),(1.5,.5),(1.2,1.2),(1,1)]
        cases.append(("body_closed_tangencies_{}".format(k),position,.125,
            [position_reference.measured(position,i,p,(.015625,0,.015625)) for i,p in enumerate(points)]))
    return cases


def numeric_checks(binary):
    absolute,scaled,records={}, {}, []
    sampled=0
    for name,position,radius,frames in fixtures():
        actual=native(binary,MODE,[source(position,radius)]+frames)
        original=native(binary,"--zone-evidence",[position]+frames)
        for frame,combined,point in zip(frames,actual,original):
            position_reference.compare(combined,oracle(position,radius,frame),absolute,scaled)
            verify_preservation(combined,point,radius)
            for row in combined["evidence"]:
                if row["decision"]!="inside":continue
                selected=next(v for v in position["zones"] if v["zone_id"]==row["zone_id"])
                item=next(v for v in frame["tracks"] if v["track_id"]==row["track_id"])
                matrix=reference.covariance_matrix(item["position_covariance"])
                if np.max(np.abs(selected["vertices_m"]))>1e6 or np.linalg.cond(matrix)>1e6 or np.max(abs(matrix))<1e-100:continue
                theta=np.linspace(0,2*np.pi,257);circle=np.array([np.cos(theta),np.sin(theta)])
                samples=np.asarray(item["position_m"])[:,None]+(selected.get("sigma_multiplier",2)*np.linalg.cholesky(matrix)+radius*np.eye(2))@circle
                for start,normal in zip(selected["vertices_m"],position_reference.normals(selected)):
                    assert np.max(np.asarray(normal)@(samples-np.asarray(start)[:,None]))<2e-11
                sampled+=1
        order=list(reversed(range(len(frames))))+list(range(len(frames)))
        assert native(binary,MODE,[source(position,radius)]+[frames[i] for i in order])==[actual[i] for i in order]
        records.append({"name":name,"radius_m":radius,"frames":len(frames),"evidence_rows":sum(len(v["evidence"]) for v in actual),
            "face_rows":sum(len(row["faces"]) for v in actual for row in v["evidence"])})
    # Explicit body and uncertainty are different inputs: k0 has no covariance
    # spread, yet a disk centered inside can cross the physical boundary.
    position=position_reference.configuration(zones=[position_reference.zone(multiplier=0)])
    frame=position_reference.measured(position,position=(.9,.5))
    base=native(binary,"--zone-evidence",[position,frame])[0]["evidence"][0]
    body=native(binary,MODE,[source(position,.2),frame])[0]["evidence"][0]
    assert base["decision"]=="inside" and body["decision"]=="indeterminate"
    return {"cases":len(records),"frames":sum(v["frames"] for v in records),"evidence_rows":sum(v["evidence_rows"] for v in records),
        "face_rows":sum(v["face_rows"] for v in records),"zero_radius_cases":sum(v["radius_m"]==0 for v in records),
        "zero_radius_original_path_exact":True,"original_position_bands_preserved_exactly":True,"physical_body_changes_center_only_relation":True,
        "numpy_minkowski_sample_checks":sampled,"secondary_sample_points_per_case":257,
        "stateless_repeat_and_reordering_exact":True,"maximum_absolute_decimal_errors":absolute,"maximum_relative_or_scaled_decimal_errors":scaled,"records":records}


def real_checks(binary):
    records,statuses,absolute,scaled=[],set(),{},{}
    for name,measurement,_,frames in analysis_reference.fixtures():
        outputs=native(binary,"--stream",[measurement]+frames)
        position=position_reference.configuration(measurement["session_id"],[position_reference.zone(vertices=[[-100,-100],[100,-100],[100,100],[-100,100]])])
        head=source(position,.25);expected=native(binary,MODE,[head]+outputs);original=native(binary,"--zone-evidence",[position]+outputs)
        for frame,result,base in zip(outputs,expected,original):
            position_reference.compare(result,oracle(position,.25,frame),absolute,scaled);verify_preservation(result,base,.25)
            statuses.update(item["status"] for item in frame["tracks"])
        for cut in range(len(frames)+1):
            saved=native(binary,"--checkpoint",[measurement]+frames[:cut],count=1)[0]
            continued=native(binary,"--stream",[{"resume":saved}]+frames[cut:])
            assert continued==outputs[cut:] and native(binary,MODE,[head]+continued)==expected[cut:]
        records.append({"name":name,"frames":len(frames),"old_checkpoint_cut_points":len(frames)+1,"evidence_rows":sum(len(v["evidence"]) for v in expected)})
    assert {"initializing","ready","uncertain","rejected_innovation","numerical_failure","rejected_projection"}.issubset(statuses)
    return {"cases":len(records),"frames":sum(v["frames"] for v in records),"old_checkpoint_cut_points":sum(v["old_checkpoint_cut_points"] for v in records),
        "statuses":sorted(statuses),"maximum_absolute_decimal_errors":absolute,"maximum_relative_or_scaled_decimal_errors":scaled,"records":records}


def rejection_checks(binary):
    position=position_reference.configuration();head=source(position);frame=position_reference.measured(position);prefix=native(binary,MODE,[head,frame]);records=[]
    def bad(name,value,frames=()):
        actual,metadata=run(binary,MODE,[value]+list(frames),status=2)
        assert actual==(prefix if len(frames)>1 else []),name
        records.append(dict(name=name,**metadata))
    for name,value in [
        ("missing_position",{"disk":head["disk"]}),("missing_disk",{"position":head["position"]}),
        ("position_not_raw",dict(head,position=position)),("disk_not_raw",dict(head,disk={"radius_m":.125})),
        ("unknown_wrapper",dict(head,extra=True)),("duplicate_wrapper",'{"position":"duplicate",'+encode(head)[1:]),
        ("missing_radius",dict(head,disk="{}")),("negative_radius",dict(head,disk=encode({"radius_m":-1}))),
        ("nonfinite_radius",dict(head,disk='{"radius_m":1e999}')),("unknown_disk_field",dict(head,disk='{"radius_m":0.25,"extra":0}')),
        ("duplicate_disk_radius",dict(head,disk='{"radius_m":0.25,"radius_m":0}')),
        ("old_position_source_not_broadened",source(dict(position,radius_m=.25))),
        ("raw_fractional_capacity",source(encode(position).replace('"max_tracks":32','"max_tracks":32.000000000000001'))),
        ("duplicate_nested_position",source('{"session_id":"duplicate",'+encode(position)[1:])),
    ]:bad(name,value)
    for name,mutate in [("wrong_session",lambda v:v.update(session_id="other")),("stale_ready",lambda v:v["tracks"][0].update(last_accepted_timestamp_us="99")),
        ("duplicate_track",lambda v:v["tracks"].append(copy.deepcopy(v["tracks"][0]))),("duplicate_segment",lambda v:v["tracks"].append(dict(copy.deepcopy(v["tracks"][0]),track_id=2))),
        ("non_spd",lambda v:v["tracks"][0].update(position_covariance=[1,2,1])),("missing_ready_position",lambda v:v["tracks"][0].update(position_m=None)),
        ("closed_current",lambda v:v.update(closed_segment_ids=["1"])),("unknown_frame",lambda v:v.update(extra=True))]:
        value=copy.deepcopy(frame);mutate(value);bad(name,head,[frame,value])
    bad("fractional_track_token",head,[frame,encode(frame).replace('"track_id":1','"track_id":1.0000000000000001')])
    for name,k,radius,covariance,point in [
        ("physical_contribution_swallowed",2,.125,(1e32,0,1e32),(.5,.5)),
        ("statistical_contribution_swallowed",2,1e16,(.01,0,.01),(.5,.5)),
        ("combined_overflow",1e154,1e308,(1e308,0,1e308),(.5,.5)),
        ("expanded_endpoint_swallowed",2,.25,(1,0,1),(1e16,.5)),
        ("positive_subnormal_disk_cannot_expand",0,5e-324,(.01,0,.01),(.5,.5)),
        ("old_position_failure_not_rescued",2,1e300,(1,0,1),(1e300,.5)),
    ]:
        selected=position_reference.configuration(zones=[position_reference.zone(multiplier=k)])
        bad(name,source(selected,radius),[position_reference.measured(selected,position=point,covariance=covariance)])
    _,metadata=run(binary,MODE,payload=gates.lines([head,frame]).encode()+b"\xff\n",status=2)
    records.append(dict(name="invalid_utf8_complete_prefix",**metadata));assert metadata["complete_output_lines"]==1
    _,metadata=run(binary,MODE,payload=b"",status=2);records.append(dict(name="missing_header",**metadata))
    assert native(binary,MODE,[head,encode(frame).replace('"track_id":1','"track_id":10e-1')])==prefix
    return {"rejected_cases":len(records),"cases":records,"complete_prefix_preserved":True,"contribution_and_endpoint_domains_checked":True,"old_position_domain_not_masked":True,"integral_raw_id_token":"passed"}


def reframe_checks(binary):
    raw=reframe_reference.configuration(camera_reference.CAMERAS[0],"disk-zone-warm-brown")
    raw["motion"].update(min_observations=2,min_span_us="100000",max_velocity_std_mps=1e5,max_position_std_m=1e5)
    frames=[checkpoints.frame(i*100000,[checkpoints.observation(1,camera_reference.distort_pixel([580+i*2,330+i*.5],camera_reference.CAMERAS[0]),[4,.7,6])]) for i in range(8)]
    saved=native(binary,"--checkpoint",[raw]+frames[:4],count=1)[0];baseline=native(binary,"--stream",[{"resume":saved}]+frames[4:])
    changed=reframe_reference.reframe(binary,[{"resume":saved}]+frames[4:],reframe_reference.TRANSFORMS[1]);future=native(binary,"--stream",changed)
    position=position_reference.configuration(raw["session_id"],[position_reference.zone(vertices=[[-100,-100],[100,-100],[100,100],[-100,100]])]);head=source(position,.25)
    expected,actual=native(binary,MODE,[head]+baseline),native(binary,MODE,[head]+future);errors={};gates.tree_close(actual,expected,errors)
    assert sum(len(v["evidence"]) for v in actual)>0
    return {"status":"passed","brown_warm_prefix_frames":4,"continuation_frames":4,"explicit_radius_m":.25,"maximum_absolute_metric_reframe_differences":errors}


def transport_checks(binary):
    position=position_reference.configuration();head=source(position);frame=position_reference.measured(position);expected=native(binary,MODE,[head,frame])
    for ending in (b"\n",b"\r\n"):
        assert run(binary,MODE,payload=ending.join(encode(v).encode() for v in [head,frame]))[0]==expected
    assert native(binary,MODE,[encode(head).ljust(1048576),encode(frame).ljust(1048576)])==expected
    _,overflow=run(binary,MODE,[encode(head).ljust(1048577)],status=2,extra=["--max-line-bytes","16777216"])
    values,frame_overflow=run(binary,MODE,[head,frame,encode(frame).ljust(1048577)],status=2,extra=["--max-line-bytes","16777216"]);assert values==expected
    return {"crlf_and_unterminated_eof":"passed","source_wrapper_and_frame_exact_units":1048576,"source_overflow":overflow,"frame_overflow_complete_prefix":frame_overflow,
        "nested_source_budget_note":"Raw inner strings share the same 1Mi source wrapper budget; a full 1Mi inner string plus wrapper overhead cannot be a successful request."}


def web_checks(binary):
    command=["node","--test","--test-reporter=tap","web/disk-zone.test.mjs"]
    result=subprocess.run(command,cwd=str(ROOT),env=dict(os.environ,MOONGROUND_CLI=str(binary)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8",timeout=360)
    if result.returncode:raise AssertionError("Node disk zones failed:\n"+result.stdout[-18000:]+result.stderr[-2000:])
    summary,cross,batch={},None,None
    for line in result.stdout.splitlines():
        match=re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$",line)
        if match:summary[match.group(1)]=int(match.group(2))
        if line.startswith('# {"cut_points":'):cross=json.loads(line[2:])
        if line.startswith('# {"successful_empty_frames":'):batch=json.loads(line[2:])
    assert summary.get("tests") and summary["tests"]==summary["pass"] and not summary["fail"] and cross and batch
    return {"status":"passed","node":subprocess.check_output(["node","--version"],text=True).strip(),"command":" ".join(command),"summary":summary,"old_checkpoint_cross_runtime":cross,
        "measured_bounded_batch":batch,"test_script_sha256":hashlib.sha256((ROOT/"web/disk-zone.test.mjs").read_bytes()).hexdigest(),"bridge_sha256":hashlib.sha256((ROOT/"_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256":hashlib.sha256(result.stdout.encode()).hexdigest(),"stderr":result.stderr.strip()}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--binary",type=Path,required=True);parser.add_argument("--web",action="store_true")
    parser.add_argument("--output",type=Path,default=ROOT/"validation/disk-zone-results.json");args=parser.parse_args();binary=args.binary.resolve();started=time.perf_counter()
    result={"format_version":"1","fixtures":"deterministic","command":" ".join(shlex.quote(v) for v in [sys.executable]+sys.argv),"python":platform.python_version(),"numpy":np.__version__,"toolchain":reference.toolchain_version(),
        "source_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"position_reference_sha256":hashlib.sha256(Path(position_reference.__file__).read_bytes()).hexdigest(),"binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),
        "evidence_scope":SCOPE,"scaled_error_denominator":"max(abs(reference),1e-300)","independent_reference":"Decimal220 raw-edge cross/length and covariance quadratic, explicit deterministic disk support, independently rounded endpoints; original v22 path used only for exact reduction/preserved position fields"}
    result["numeric_reference"]=numeric_checks(binary);result["original_motion_and_checkpoint_continuations"]=real_checks(binary);result["strict_and_numerical_rejections"]=rejection_checks(binary)
    result["warm_brown_reframe"]=reframe_checks(binary);result["bounded_transport"]=transport_checks(binary)
    if args.web:result["web_interchange"]=web_checks(binary)
    result.update(status="passed",elapsed_seconds=time.perf_counter()-started);args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open("w",encoding="utf-8",newline="\n") as f:f.write(json.dumps(result,indent=2,ensure_ascii=True)+"\n")
    print(encode({"status":"passed","numeric_cases":result["numeric_reference"]["cases"],"real_cases":result["original_motion_and_checkpoint_continuations"]["cases"],"strict_rejections":result["strict_and_numerical_rejections"]["rejected_cases"],"output":str(args.output)}))


if __name__=="__main__":main()
