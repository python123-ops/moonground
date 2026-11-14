#!/usr/bin/env python3
"""Independent explicit convex footprint support plus current position covariance bands.

Decimal evaluates raw-edge distance, the full covariance quadratic form and
deterministic vertex supports independently of the production expansion. The old
zone path separately checks unchanged position bands and diagnostics. No physical footprint is inferred from detector or velocity data.
"""

import argparse
import copy
import decimal
from fractions import Fraction
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
MODE="--footprint-zone-evidence"
SCOPE="model_position_halfplane_bands_plus_explicit_convex_footprint"
encode,native,run=gates.encode,gates.native,gates.execute
D=decimal.Decimal
DEFAULT=[[-.25,-.25],[1.,-.25],[1.,.25],[-.25,.25]]


def source(position,vertices=None):
    return {"position":position if isinstance(position,str) else encode(position),"footprint":encode({"vertices_offset_m":DEFAULT if vertices is None else vertices})}


def square(radius):
    return [[-radius,-radius],[radius,-radius],[radius,radius],[-radius,radius]]


def validate_geometry(vertices):
    # Fraction operates on the exact input binary64 coordinates. This is an
    # independent geometric oracle, not an invocation of a production helper.
    assert 3<=len(vertices)<=32
    points=[[Fraction(float(v)) for v in p] for p in vertices]
    turns=[]
    for i,a in enumerate(points):
        b=points[(i+1)%len(points)]
        cross=lambda p:(b[0]-a[0])*(p[1]-a[1])-(b[1]-a[1])*(p[0]-a[0])
        values=[cross(p) for j,p in enumerate(points) if j not in (i,(i+1)%len(points))]
        assert all(v>0 for v in values) or all(v<0 for v in values)
        turns.append(1 if values[0]>0 else -1)
        assert turns[-1]*cross([Fraction(0),Fraction(0)])>=0
    assert len(set(turns))==1
    return turns[0]


def supports(selected,vertices,index):
    orientation=position_reference.winding([list(map(float,p)) for p in selected["vertices_m"]])
    start=selected["vertices_m"][index];end=selected["vertices_m"][(index+1)%len(selected["vertices_m"])]
    dx,dy=[Fraction(float(end[i])-float(start[i])) for i in (0,1)]
    numerators=[orientation*(dy*Fraction(float(p[0]))-dx*Fraction(float(p[1]))) for p in vertices]
    def dec(v):return D(v.numerator)/D(v.denominator)
    length=(dec(dx)**2+dec(dy)**2).sqrt()
    return dec(min(numerators))/length,dec(max(numerators))/length


def exact_band(selected,position,covariance,vertices):
    old=position_reference.exact_band(selected,position,covariance)
    orientation=position_reference.winding([list(map(float,p)) for p in selected["vertices_m"]])
    faces=[]
    with decimal.localcontext() as context:
        context.prec=220
        xx,xy,yy=[D.from_float(float(v)) for v in covariance]
        k=D.from_float(float(selected.get("sigma_multiplier",2)))
        for face,start,normal in zip(old["faces"],selected["vertices_m"],position_reference.normals(selected)):
            end=selected["vertices_m"][(face["edge_index"]+1)%len(selected["vertices_m"])]
            dx,dy=[D.from_float(float(end[i])-float(start[i])) for i in (0,1)]
            x,y=[D.from_float(float(position[i])-float(start[i])) for i in (0,1)]
            nx,ny=[D.from_float(v) for v in normal]
            distance=orientation*(dy*x-dx*y)/(dx*dx+dy*dy).sqrt()
            noise=k*(nx*nx*xx+2*nx*ny*xy+ny*ny*yy).sqrt()
            low,high=supports(selected,vertices,face["edge_index"])
            assert low<=0<=high
            faces.append(dict(face,position_lower_m=face["lower_m"],position_upper_m=face["upper_m"],
                footprint_lower_m=float(low),footprint_upper_m=float(high),
                lower_m=face["lower_m"] if low==0 else float(distance-noise+low),
                upper_m=face["upper_m"] if high==0 else float(distance+noise+high)))
    separated=[face["edge_index"] for face in faces if face["lower_m"]>0]
    decision="inside" if all(face["upper_m"]<=0 for face in faces) else "outside" if separated else "indeterminate"
    return {"zone_id":selected["zone_id"],"vertices_offset_m":vertices,"sigma_multiplier":selected.get("sigma_multiplier",2),
        "faces":faces,"decision":decision,"separating_edge_index":separated[0] if separated else None}


def oracle(position,vertices,frame):
    evidence,unavailable=[],[]
    for item in sorted(frame["tracks"],key=lambda value:value["track_id"]):
        if item["status"]!="ready":unavailable.append({"track_id":item["track_id"],"segment_id":item["segment_id"],"reason":item["status"]})
        else:
            for selected in position["zones"]:
                evidence.append(dict(track_id=item["track_id"],segment_id=item["segment_id"],**exact_band(selected,item["position_m"],item["position_covariance"],vertices)))
    return {"schema_version":"0.1.0","kind":"footprint_zone_evidence_frame","evidence_scope":SCOPE,
        "session_id":frame["session_id"],"timestamp_us":frame["timestamp_us"],"evidence":evidence,"unavailable":unavailable}


def verify_preservation(actual,original,vertices):
    assert actual["unavailable"]==original["unavailable"]
    assert len(actual["evidence"])==len(original["evidence"])
    for body,point in zip(actual["evidence"],original["evidence"]):
        assert body["vertices_offset_m"]==vertices
        for key in ("track_id","segment_id","zone_id","sigma_multiplier"):assert body[key]==point[key]
        for combined,base in zip(body["faces"],point["faces"]):
            for key in ("edge_index","outward_normal","distance_m","normal_std_m"):assert combined[key]==base[key]
            assert combined["position_lower_m"]==base["lower_m"] and combined["position_upper_m"]==base["upper_m"]
            assert combined["footprint_lower_m"]<=0<=combined["footprint_upper_m"]
            assert combined["lower_m"]<=base["lower_m"] and combined["upper_m"]>=base["upper_m"]
            if combined["footprint_lower_m"]==0:assert combined["lower_m"]==base["lower_m"]
            else:assert combined["lower_m"]<base["lower_m"]
            if combined["footprint_upper_m"]==0:assert combined["upper_m"]==base["upper_m"]
            else:assert combined["upper_m"]>base["upper_m"]


def fixtures():
    cases=[]
    for name,position,frames in position_reference.fixtures():
        extent=max(max(p[i] for p in selected["vertices_m"])-min(p[i] for p in selected["vertices_m"])
            for selected in position["zones"] for i in (0,1))
        shape=[[x*.03125*extent,y*.03125*extent] for x,y in DEFAULT]
        cases.append((name,position,shape,frames))
    variants=[("interior",DEFAULT),("edge",[[-.25,0],[.5,0],[.5,.25],[-.25,.25]]),("vertex",[[0,0],[.5,0],[0,.25]])]
    for name,shape in variants:
        for order,vertices in [("ccw",shape),("cw",shape[::-1]),("cyclic",shape[1:]+shape[:1])]:
            position=position_reference.configuration("anchor-"+name+order,[position_reference.zone(multiplier=0)])
            points=[(.5,.5),(.75,.5),(1,.5),(1.25,.5),(1.5,.5),(1.2,1.2)]
            cases.append((name+"_"+order,position,vertices,[position_reference.measured(position,i,p,(.015625,0,.015625)) for i,p in enumerate(points)]))
    for name,shape,points in [
        ("slanted_exact_own_boundary",[[0,0],[3,4],[0,5]],[(0,0)]),
        ("slanted_zero_support_ulp",[[0,0],[3,4],[0,5]],[(1.5,2),(1.5,float(np.nextafter(2.,0.))),(1.5,float(np.nextafter(2.,3.)))])]:
        verts=[[0,0],[3,4],[0,5]] if name.endswith("boundary") else [[0,0],[6,8],[0,10]]
        position=position_reference.configuration(name,[position_reference.zone(vertices=verts,multiplier=0)])
        cases.append((name,position,shape,[position_reference.measured(position,i,p) for i,p in enumerate(points)]))
    for name,matrix,shift,scale in [("shape_rotation",np.array([[.6,-.8],[.8,.6]]),[0,0],1),
        ("shape_reflection",np.array([[-1.,0],[0,1.]]),[0,0],1),("shape_translation",np.eye(2),[1000,-2000],1),
        ("shape_scale",np.eye(2),[0,0],3.5)]:
        transform=matrix*scale
        zoneverts=(np.array([[-2,-2],[2,-2],[2,2],[-2,2]])@transform.T+shift).tolist()
        shape=(np.asarray(DEFAULT)@transform.T).tolist()
        position=position_reference.configuration(name,[position_reference.zone(vertices=zoneverts)])
        cov=reference.compact_covariance(transform@np.array([[.01,.002],[.002,.02]])@transform.T)
        cases.append((name,position,shape,[position_reference.measured(position,i,transform@np.asarray(p)+shift,cov) for i,p in enumerate([(0,0),(2,0),(3,3)])]))
    return cases


def numeric_checks(binary):
    absolute,scaled,records={}, {}, []
    sampled,zero_sides=0,0
    for name,position,vertices,frames in fixtures():
        validate_geometry(vertices)
        actual=native(binary,MODE,[source(position,vertices)]+frames);original=native(binary,"--zone-evidence",[position]+frames)
        if name=="slanted_exact_own_boundary":assert actual[0]["evidence"][0]["decision"]=="inside"
        if name=="slanted_zero_support_ulp":assert [v["evidence"][0]["decision"] for v in actual]==["inside","indeterminate","inside"]
        for frame,combined,point in zip(frames,actual,original):
            position_reference.compare(combined,oracle(position,vertices,frame),absolute,scaled);verify_preservation(combined,point,vertices)
            for row in combined["evidence"]:
                zero_sides+=sum(face["footprint_lower_m"]==0 or face["footprint_upper_m"]==0 for face in row["faces"])
                if row["decision"]!="inside":continue
                selected=next(v for v in position["zones"] if v["zone_id"]==row["zone_id"]);item=next(v for v in frame["tracks"] if v["track_id"]==row["track_id"])
                matrix=reference.covariance_matrix(item["position_covariance"])
                if np.max(np.abs(selected["vertices_m"]))>1e6 or np.linalg.cond(matrix)>1e6 or np.max(abs(matrix))<1e-100:continue
                theta=np.linspace(0,2*np.pi,257);circle=np.array([np.cos(theta),np.sin(theta)])
                ellipse=selected.get("sigma_multiplier",2)*np.linalg.cholesky(matrix)@circle
                for offset in vertices:
                    samples=np.asarray(item["position_m"])[:,None]+np.asarray(offset)[:,None]+ellipse
                    for start,normal in zip(selected["vertices_m"],position_reference.normals(selected)):
                        assert np.max(np.asarray(normal)@(samples-np.asarray(start)[:,None]))<2e-11
                sampled+=1
        order=list(reversed(range(len(frames))))+list(range(len(frames)))
        assert native(binary,MODE,[source(position,vertices)]+[frames[i] for i in order])==[actual[i] for i in order]
        records.append({"name":name,"shape_vertices":len(vertices),"frames":len(frames),"evidence_rows":sum(len(v["evidence"]) for v in actual),
            "face_rows":sum(len(row["faces"]) for v in actual for row in v["evidence"])})
    # Axis faces have identical support for a square and a centered disk.
    position=position_reference.configuration();frames=[position_reference.measured(position,i,p) for i,p in enumerate([(.5,.5),(1.25,.5),(2,2)])]
    body=native(binary,MODE,[source(position,square(.125))]+frames)
    diskhead={"position":encode(position),"disk":encode({"radius_m":.125})};disk=native(binary,"--disk-zone-evidence",[diskhead]+frames)
    for a,b in zip(body,disk):
        assert a["evidence"][0]["decision"]==b["evidence"][0]["decision"]
        for x,y in zip(a["evidence"][0]["faces"],b["evidence"][0]["faces"]):assert x["lower_m"]==y["lower_m"] and x["upper_m"]==y["upper_m"]
    return {"cases":len(records),"frames":sum(v["frames"] for v in records),"evidence_rows":sum(v["evidence_rows"] for v in records),"face_rows":sum(v["face_rows"] for v in records),
        "original_position_bands_preserved_exactly":True,"one_sided_zero_support_faces":zero_sides,"axis_square_disk_exact":True,"fraction_geometry_support_extrema":"passed",
        "numpy_vertex_plus_ellipse_sample_checks":sampled,"secondary_sample_points_per_vertex":257,"stateless_repeat_and_reordering_exact":True,
        "maximum_absolute_decimal_errors":absolute,"maximum_relative_or_scaled_decimal_errors":scaled,"records":records}


def real_checks(binary):
    records,statuses,absolute,scaled=[],set(),{},{}
    for name,measurement,_,frames in analysis_reference.fixtures():
        outputs=native(binary,"--stream",[measurement]+frames)
        position=position_reference.configuration(measurement["session_id"],[position_reference.zone(vertices=[[-100,-100],[100,-100],[100,100],[-100,100]])])
        head=source(position);expected=native(binary,MODE,[head]+outputs);original=native(binary,"--zone-evidence",[position]+outputs)
        for frame,result,base in zip(outputs,expected,original):
            position_reference.compare(result,oracle(position,DEFAULT,frame),absolute,scaled);verify_preservation(result,base,DEFAULT)
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
        ("missing_position",{"footprint":head["footprint"]}),("missing_footprint",{"position":head["position"]}),
        ("position_not_raw",dict(head,position=position)),("footprint_not_raw",dict(head,footprint={"vertices_offset_m":DEFAULT})),
        ("unknown_wrapper",dict(head,extra=True)),("duplicate_wrapper",'{"position":"duplicate",'+encode(head)[1:]),
        ("missing_vertices",dict(head,footprint="{}")),("unknown_footprint_field",dict(head,footprint='{"vertices_offset_m":'+encode(DEFAULT)+',"extra":0}')),
        ("duplicate_vertices",dict(head,footprint='{"vertices_offset_m":'+encode(DEFAULT)+',"vertices_offset_m":[]}')),
        ("old_position_source_not_broadened",source(dict(position,vertices_offset_m=DEFAULT))),
        ("raw_fractional_capacity",source(encode(position).replace('"max_tracks":32','"max_tracks":32.000000000000001'))),
        ("duplicate_nested_position",source('{"session_id":"duplicate",'+encode(position)[1:])),
        ("nonfinite_vertex",dict(head,footprint='{"vertices_offset_m":[[0,0],[1e999,0],[0,1]]}')),
    ]:bad(name,value)
    invalid=[("empty",[]),("point",[[0,0]]),("segment",[[0,0],[1,0]]),("allzero",[[0,0],[0,0],[0,0]]),
        ("outside_origin",[[1,1],[2,1],[1,2]]),("duplicate",[[0,0],[1,0],[1,0],[0,1]]),
        ("collinear",[[0,0],[1,0],[2,0]]),("concave",[[0,0],[1,0],[.25,.25],[0,1]]),
        ("self_intersecting",[[0,0],[1,1],[0,1],[1,0]]),("vertex_arity",[[0,0],[1,0,1],[0,1]]),
        ("too_many",[[math.cos(2*math.pi*i/33),math.sin(2*math.pi*i/33)] for i in range(33)]),
        ("origin_ulp_exterior",[[float(np.nextafter(0.,1.)),0],[1,0],[1,1],[float(np.nextafter(0.,1.)),1]])]
    for name,shape in invalid:bad(name,source(position,shape))
    for name,mutate in [("wrong_session",lambda v:v.update(session_id="other")),("stale_ready",lambda v:v["tracks"][0].update(last_accepted_timestamp_us="99")),
        ("duplicate_track",lambda v:v["tracks"].append(copy.deepcopy(v["tracks"][0]))),("duplicate_segment",lambda v:v["tracks"].append(dict(copy.deepcopy(v["tracks"][0]),track_id=2))),
        ("non_spd",lambda v:v["tracks"][0].update(position_covariance=[1,2,1])),("missing_ready_position",lambda v:v["tracks"][0].update(position_m=None)),
        ("closed_current",lambda v:v.update(closed_segment_ids=["1"])),("unknown_frame",lambda v:v.update(extra=True))]:
        value=copy.deepcopy(frame);mutate(value);bad(name,head,[frame,value])
    bad("fractional_track_token",head,[frame,encode(frame).replace('"track_id":1','"track_id":1.0000000000000001')])
    for name,k,shape,covariance,point in [
        ("physical_contribution_swallowed",2,square(.125),(1e32,0,1e32),(.5,.5)),
        ("statistical_contribution_swallowed",2,square(1e16),(.01,0,.01),(.5,.5)),
        ("combined_overflow",1.5e154,square(5e307),(1e308,0,1e308),(.5,.5)),
        ("expanded_endpoint_swallowed",2,square(.25),(1,0,1),(1e16,.5)),
        ("old_position_failure_not_rescued",2,square(1e100),(1,0,1),(1e300,.5)),
    ]:
        selected=position_reference.configuration(zones=[position_reference.zone(multiplier=k)])
        assert native(binary,MODE,[source(selected,shape)])==[],name
        bad(name,source(selected,shape),[position_reference.measured(selected,position=point,covariance=covariance)])
    _,metadata=run(binary,MODE,payload=gates.lines([head,frame]).encode()+b"\xff\n",status=2)
    records.append(dict(name="invalid_utf8_complete_prefix",**metadata));assert metadata["complete_output_lines"]==1
    _,metadata=run(binary,MODE,payload=b"",status=2);records.append(dict(name="missing_header",**metadata))
    assert native(binary,MODE,[head,encode(frame).replace('"track_id":1','"track_id":10e-1')])==prefix
    return {"rejected_cases":len(records),"cases":records,"complete_prefix_preserved":True,"contribution_and_endpoint_domains_checked":True,"old_position_domain_not_masked":True,"integral_raw_id_token":"passed"}


def reframe_checks(binary):
    raw=reframe_reference.configuration(camera_reference.CAMERAS[0],"footprint-zone-warm-brown")
    raw["motion"].update(min_observations=2,min_span_us="100000",max_velocity_std_mps=1e5,max_position_std_m=1e5)
    frames=[checkpoints.frame(i*100000,[checkpoints.observation(1,camera_reference.distort_pixel([580+i*2,330+i*.5],camera_reference.CAMERAS[0]),[4,.7,6])]) for i in range(8)]
    saved=native(binary,"--checkpoint",[raw]+frames[:4],count=1)[0];baseline=native(binary,"--stream",[{"resume":saved}]+frames[4:])
    changed=reframe_reference.reframe(binary,[{"resume":saved}]+frames[4:],reframe_reference.TRANSFORMS[1]);future=native(binary,"--stream",changed)
    position=position_reference.configuration(raw["session_id"],[position_reference.zone(vertices=[[-100,-100],[100,-100],[100,100],[-100,100]])]);head=source(position)
    expected,actual=native(binary,MODE,[head]+baseline),native(binary,MODE,[head]+future);errors={};gates.tree_close(actual,expected,errors)
    assert sum(len(v["evidence"]) for v in actual)>0
    return {"status":"passed","brown_warm_prefix_frames":4,"continuation_frames":4,"explicit_vertices_offset_m":DEFAULT,"maximum_absolute_metric_reframe_differences":errors}


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
    command=["node","--test","--test-reporter=tap","web/footprint-zone.test.mjs"]
    result=subprocess.run(command,cwd=str(ROOT),env=dict(os.environ,MOONGROUND_CLI=str(binary)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8",timeout=360)
    if result.returncode:raise AssertionError("Node convex footprint zones failed:\n"+result.stdout[-18000:]+result.stderr[-2000:])
    summary,cross,batch={},None,None
    for line in result.stdout.splitlines():
        match=re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$",line)
        if match:summary[match.group(1)]=int(match.group(2))
        if line.startswith('# {"cut_points":'):cross=json.loads(line[2:])
        if line.startswith('# {"successful_empty_frames":'):batch=json.loads(line[2:])
    assert summary.get("tests") and summary["tests"]==summary["pass"] and not summary["fail"] and cross and batch
    return {"status":"passed","node":subprocess.check_output(["node","--version"],text=True).strip(),"command":" ".join(command),"summary":summary,"old_checkpoint_cross_runtime":cross,
        "measured_bounded_batch":batch,"test_script_sha256":hashlib.sha256((ROOT/"web/footprint-zone.test.mjs").read_bytes()).hexdigest(),"bridge_sha256":hashlib.sha256((ROOT/"_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256":hashlib.sha256(result.stdout.encode()).hexdigest(),"stderr":result.stderr.strip()}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--binary",type=Path,required=True);parser.add_argument("--web",action="store_true")
    parser.add_argument("--output",type=Path,default=ROOT/"validation/footprint-zone-results.json");args=parser.parse_args();binary=args.binary.resolve();started=time.perf_counter()
    result={"format_version":"1","fixtures":"deterministic","command":" ".join(shlex.quote(v) for v in [sys.executable]+sys.argv),"python":platform.python_version(),"numpy":np.__version__,"toolchain":reference.toolchain_version(),
        "source_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"position_reference_sha256":hashlib.sha256(Path(position_reference.__file__).read_bytes()).hexdigest(),"binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),
        "evidence_scope":SCOPE,"scaled_error_denominator":"max(abs(reference),1e-300)","independent_reference":"Fraction rawcross/support extrema and Decimal220 lengths/covariance, explicit deterministic vertex supports, independently rounded endpoints; original v22 path used only for exact preserved position fields"}
    result["numeric_reference"]=numeric_checks(binary);result["original_motion_and_checkpoint_continuations"]=real_checks(binary);result["strict_and_numerical_rejections"]=rejection_checks(binary)
    result["warm_brown_reframe"]=reframe_checks(binary);result["bounded_transport"]=transport_checks(binary)
    if args.web:result["web_interchange"]=web_checks(binary)
    result.update(status="passed",elapsed_seconds=time.perf_counter()-started);args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open("w",encoding="utf-8",newline="\n") as f:f.write(json.dumps(result,indent=2,ensure_ascii=True)+"\n")
    print(encode({"status":"passed","numeric_cases":result["numeric_reference"]["cases"],"real_cases":result["original_motion_and_checkpoint_continuations"]["cases"],"strict_rejections":result["strict_and_numerical_rejections"]["rejected_cases"],"output":str(args.output)}))


if __name__=="__main__":main()
