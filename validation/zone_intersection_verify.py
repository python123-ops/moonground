#!/usr/bin/env python3
"""Exact rational reference for bounded position ellipse / polygon intersection.

Every binary64 input is interpreted as an exact real rational. Inverse covariance,
centre membership, per-segment stationary clamp and the global minimum are exact
Fraction arithmetic. No empirical tolerance is used to validate a returned bound
or an intersection decision. NumPy is a separate ordinary-scale cross-check.
"""
import argparse
import copy
from decimal import Decimal,localcontext
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
import zone_verify as zones
import analysis_verify as analysis_reference
import checkpoint_verify as checkpoints
import camera_verify as camera_reference
import reframe_verify as reframe_reference
import gates_verify as gates
import verify as reference

ROOT=Path(__file__).resolve().parents[1]
MODE="--zone-intersection"
SEED=20261211
MAX=9223372036854775807
encode,native,execute=gates.encode,gates.native,gates.execute
F=lambda v:Fraction.from_float(float(v))


def exact(selected,point,covariance):
    vertices=[tuple(F(v) for v in p) for p in selected["vertices_m"]]
    mu=tuple(F(v) for v in point);xx,xy,yy=map(F,covariance);det=xx*yy-xy*xy
    assert det>0
    def metric(u,v):return (yy*u[0]*v[0]-xy*(u[0]*v[1]+u[1]*v[0])+xx*u[1]*v[1])/det
    area=sum(a[0]*b[1]-a[1]*b[0] for a,b in zip(vertices,vertices[1:]+vertices[:1]));sign=1 if area>0 else -1
    crosses=[sign*((b[0]-a[0])*(mu[1]-a[1])-(b[1]-a[1])*(mu[0]-a[0])) for a,b in zip(vertices,vertices[1:]+vertices[:1])]
    inside=all(v>=0 for v in crosses)
    values=[]
    for index,(a,b) in enumerate(zip(vertices,vertices[1:]+vertices[:1])):
        r=(a[0]-mu[0],a[1]-mu[1]);edge=(b[0]-a[0],b[1]-a[1]);A=metric(edge,edge);B=metric(r,edge)
        t=max(Fraction(0),min(Fraction(1),-B/A))
        offset=(r[0]+t*edge[0],r[1]+t*edge[1]);values.append((metric(offset,offset),index,t))
    minimum=Fraction(0) if inside else min(v[0] for v in values)
    return minimum,inside,vertices,mu,metric,values


def check_row(row,selected,item,statistics):
    q,inside,vertices,mu,metric,values=exact(selected,item["position_m"],item["position_covariance"])
    lo,hi=row["minimum_quadratic_lower"],row["minimum_quadratic_upper"]
    assert all(isinstance(v,(int,float)) and math.isfinite(v) for v in [lo,hi]),row
    assert 0<=F(lo)<=q<=F(hi),(selected,item,row,"exact quadratic escaped interval",str(q))
    threshold=F(selected.get("sigma_multiplier",2))**2
    if row["decision"]=="disjoint":assert q>threshold,(row,str(q),str(threshold))
    elif row["decision"]=="intersects":assert q<=threshold,(row,str(q),str(threshold))
    else:assert row["decision"]=="indeterminate"
    assert row["zone_id"]==selected["zone_id"] and row["sigma_multiplier"]==selected.get("sigma_multiplier",2)
    assert all(math.isfinite(v) for v in row["witness_position_m"])
    edge,fraction=row["witness_edge_index"],row["witness_fraction"]
    if edge is None:
        assert fraction is None and inside and q==0
        assert row["witness_position_m"]==item["position_m"]
    else:
        assert isinstance(edge,int) and 0<=edge<len(vertices)
        assert fraction is not None and math.isfinite(fraction) and 0<=fraction<=1
        a,b=vertices[edge],vertices[(edge+1)%len(vertices)];t=F(fraction)
        witness=(a[0]+t*(b[0]-a[0])-mu[0],a[1]+t*(b[1]-a[1])-mu[1])
        assert metric(witness,witness)<=F(hi),("explicit exact witness exceeded upper",row)
        statistics["explicit_witnesses"]+=1
    statistics["rows"]+=1;statistics["decisions"][row["decision"]]=statistics["decisions"].get(row["decision"],0)+1
    statistics["maximum_absolute_interval_width"]=max(statistics["maximum_absolute_interval_width"],hi-lo)
    if q>0:
        ratio=(F(hi)-F(lo))/q
        if ratio>Fraction(statistics["maximum_relative_interval_width_exact"]):
            statistics["maximum_relative_interval_width_exact"]=str(ratio)
            with localcontext() as context:
                context.prec=24
                statistics["maximum_relative_interval_width_decimal"]=str(Decimal(ratio.numerator)/Decimal(ratio.denominator))
    statistics["centre_inside_rows"]+=int(inside)
    # This numerical check is secondary; the rational inequalities above are
    # the enclosure and soundness tests, including every tangent/ULP case.
    matrix=reference.covariance_matrix(item["position_covariance"])
    if np.linalg.cond(matrix)<1e6 and np.max(np.abs(matrix))<1e100 and np.min(np.diag(matrix))>1e-100:
        actual=float(q)
        if not inside:
            inv=np.linalg.inv(matrix);point=np.asarray(item["position_m"]);candidate=[]
            p=np.asarray(selected["vertices_m"],dtype=float)
            for a,b in zip(p,np.roll(p,-1,axis=0)):
                r=a-point;e=b-a;t=np.clip(-(e@inv@r)/(e@inv@e),0,1);v=r+t*e;candidate.append(float(v@inv@v))
            approximate=min(candidate)
            error=abs(approximate-actual)
            statistics["numpy_crosscheck_rows"]+=1
            statistics["numpy_maximum_absolute_difference"]=max(statistics["numpy_maximum_absolute_difference"],error)
            assert error<=1e-8*max(abs(actual),1.),(actual,approximate)


def check_frame(output,head,frame,statistics):
    assert set(output)=={"schema_version","kind","evidence_scope","session_id","timestamp_us","evidence","unavailable"}
    assert output["schema_version"]=="0.1.0" and output["kind"]=="position_zone_intersection_frame"
    assert output["evidence_scope"]=="model_position_ellipse_convex_zone_intersection"
    assert output["session_id"]==head["session_id"] and output["timestamp_us"]==frame["timestamp_us"]
    expected=[];unavailable=[]
    for item in sorted(frame["tracks"],key=lambda t:t["track_id"]):
        if item["status"]!="ready":unavailable.append({"track_id":item["track_id"],"segment_id":item["segment_id"],"reason":item["status"]})
        else:
            for selected in head["zones"]:expected.append((item,selected))
    assert output["unavailable"]==unavailable
    assert len(output["evidence"])==len(expected)
    for row,(item,selected) in zip(output["evidence"],expected):
        assert row["track_id"]==item["track_id"] and row["segment_id"]==item["segment_id"]
        assert set(row)=={"track_id","segment_id","zone_id","sigma_multiplier","minimum_quadratic_lower","minimum_quadratic_upper","witness_edge_index","witness_fraction","witness_position_m","decision"}
        check_row(row,selected,item,statistics)


def statistics():return {"rows":0,"explicit_witnesses":0,"centre_inside_rows":0,"decisions":{},"maximum_absolute_interval_width":0.,"maximum_relative_interval_width_exact":"0","maximum_relative_interval_width_decimal":"0","numpy_crosscheck_rows":0,"numpy_maximum_absolute_difference":0.}


def fixtures():
    values=list(zones.fixtures())
    for name,head,frames in values:
        if name=="supported_correlation":frames.append(zones.measured(head,101,(12,12),(1,-(1-1e-10),1)))
    # Old halfplane evidence has a deliberately different semantic scope. This
    # exact dyadic case distinguishes it from complete closed-set separation.
    h=zones.configuration("corner-blind-spot",[zones.zone(multiplier=1)])
    values.append(("corner-blind-spot",h,[zones.measured(h,i,p,(.015625,0,.015625)) for i,p in enumerate([(1.125,1.125),(1.125,.5),(float(np.nextafter(1.125,2.)),.5),(float(np.nextafter(1.125,1.)),.5)])]))
    h=zones.configuration("original-differences",[zones.zone(vertices=[[1e15,1e15],[1e15+8,1e15],[1e15+8,1e15+8],[1e15,1e15+8]],multiplier=1)])
    values.append(("original-differences",h,[zones.measured(h,i,p,(.015625,0,.015625)) for i,p in enumerate([(1e15+4,1e15+4),(1e15+8.125,1e15+8.125),(1e15+8,1e15+8)])]))
    h=zones.configuration("normal-subnormal-rounding",[zones.zone(multiplier=0)])
    boundary=float.fromhex('0x1.fffffffffffffp-1022')
    values.append(("normal-subnormal-rounding",h,[zones.measured(h,0,(.5,2),(2,0,boundary)),zones.measured(h,1,(-0.,0),(1,0,1)),zones.measured(h,2,(-5e-324,.5),(1,0,1))]))
    rng=np.random.default_rng(SEED)
    random_frames=[];h=zones.configuration("seeded-rational-reference",[zones.zone(vertices=[[-2,-1],[2,-1],[3,2],[-1,3]],multiplier=1.7)])
    for i in range(160):
        axis=rng.uniform(.05,1.5,size=2);rho=rng.uniform(-.95,.95);covariance=[axis[0]**2,rho*axis[0]*axis[1],axis[1]**2];point=rng.uniform([-4,-3],[5,5])
        random_frames.append(zones.measured(h,i,point,covariance))
    values.append(("seeded-rational-reference",h,random_frames))
    return values


def numeric_checks(binary):
    counts=statistics();records=[]
    for name,head,frames in fixtures():
        actual=native(binary,MODE,[head]+frames)
        for frame,out in zip(frames,actual):check_frame(out,head,frame,counts)
        order=list(reversed(range(len(frames))))+list(range(len(frames)))
        assert native(binary,MODE,[head]+[frames[i] for i in order])==[actual[i] for i in order]
        if name=="corner-blind-spot":
            assert actual[0]["evidence"][0]["decision"]=="disjoint"
            assert actual[1]["evidence"][0]["decision"]!="disjoint"
            before,meta1=execute(binary,"--zone-evidence",[head,frames[0]])
            native(binary,MODE,[head]+frames)
            after,meta2=execute(binary,"--zone-evidence",[head,frames[0]])
            assert before==after and meta1["stdout_sha256"]==meta2["stdout_sha256"]
            assert before[0]["evidence"][0]["decision"]=="indeterminate"
        records.append({"name":name,"frames":len(frames),"rows":sum(len(v["evidence"]) for v in actual)})
    assert counts["decisions"].get("disjoint") and counts["decisions"].get("intersects")
    return dict(counts,cases=len(records),frames=sum(v["frames"] for v in records),exact_fraction_bounds_and_decisions="passed_without_empirical_tolerance",explicit_fraction_witness_upper="passed",stateless_repeat_reordering_exact=True,old_face_bytes_identical_before_after_intersection=True,records=records)


def real_checks(binary):
    records=[];statuses=set();counts=statistics()
    for name,measurement,_,raw in analysis_reference.fixtures():
        measured=native(binary,"--stream",[measurement]+raw)
        head=zones.configuration(measurement["session_id"],[zones.zone(vertices=[[-100,-100],[100,-100],[100,100],[-100,100]])])
        expected=native(binary,MODE,[head]+measured)
        for frame,out in zip(measured,expected):
            check_frame(out,head,frame,counts);statuses.update(t["status"] for t in frame["tracks"])
        for cut in range(len(raw)+1):
            cp=native(binary,"--checkpoint",[measurement]+raw[:cut],count=1)[0]
            continued=native(binary,"--stream",[{"resume":cp}]+raw[cut:])
            assert continued==measured[cut:]
            assert native(binary,MODE,[head]+continued)==expected[cut:]
        records.append({"name":name,"frames":len(raw),"old_checkpoint_cut_points":len(raw)+1,"rows":sum(len(v["evidence"]) for v in expected)})
    assert {"initializing","ready","uncertain","rejected_innovation","numerical_failure","rejected_projection"}.issubset(statuses)
    return dict(counts,cases=len(records),frames=sum(v["frames"] for v in records),old_checkpoint_cut_points=sum(v["old_checkpoint_cut_points"] for v in records),statuses=sorted(statuses),original_authored_motion_numpy=checkpoints.independent_reference_checks(binary),records=records)


def strict_checks(binary):
    head=zones.configuration();frame=zones.measured(head);prefix=native(binary,MODE,[head,frame]);records=[]
    def bad(name,h=head,f=None):
        out,meta=execute(binary,MODE,[h] if f is None else [h,frame,f],status=2)
        assert out==([] if f is None else prefix),name;records.append(dict(name=name,**meta))
    for name,vertices in [("duplicate_vertex",[[0,0],[1,0],[1,0],[0,1]]),("collinear",[[0,0],[1,0],[2,0],[0,1]]),("concave",[[0,0],[2,0],[.5,.5],[0,2]]),("crossed",[[0,0],[1,1],[0,1],[1,0]]),("normal_component_loss",[[0,0],[1e300,1e-300],[1e300,1e300],[0,1e300]])]:bad(name,zones.configuration(zones=[zones.zone(vertices=vertices)]))
    for name,change in [("negative_k",lambda v:v["zones"][0].update(sigma_multiplier=-1)),("unknown_zone",lambda v:v["zones"][0].update(extra=1)),("duplicate_zones",lambda v:v["zones"].append(copy.deepcopy(v["zones"][0]))),("work_capacity",lambda v:v.update(max_tracks=10000,zones=[zones.zone("a"),zones.zone("b")])),("unknown_source",lambda v:v.update(extra=1))]:
        h=copy.deepcopy(head);change(h);bad(name,h)
    bad("raw_fractional_capacity",encode(head).replace('"max_tracks":32','"max_tracks":32.000000000000001'))
    bad("duplicate_source",'{"session_id":"other",'+encode(head)[1:])
    for name,change in [("wrong_session",lambda v:v.update(session_id="other")),("staleReady",lambda v:v["tracks"][0].update(last_accepted_timestamp_us="99")),("nonSPD",lambda v:v["tracks"][0].update(position_covariance=[1,2,1])),("duplicate_target",lambda v:v["tracks"].append(copy.deepcopy(v["tracks"][0]))),("duplicate_segment",lambda v:v["tracks"].append(dict(v["tracks"][0],track_id=2))),("closed_current",lambda v:v.update(closed_segment_ids=["1"])),("unknown_frame",lambda v:v.update(extra=1))]:
        f=copy.deepcopy(frame);change(f);bad(name,f=f)
    bad("fractional_raw_id",f=encode(frame).replace('"track_id":1','"track_id":1.0000000000000001'))
    for name,point,covariance,k in [("near_singular_det_interval",(2,2),(.9,float(np.nextafter(.9,0.)),.9),1),("unsupported_covariance_scale",(2,2),(1e308,0,1e-308),1),("quadratic_overflow",(1e308,1e308),(1,0,1),1),("threshold_square_overflow",(2,2),(1,0,1),1e308)]:
        h=zones.configuration(zones=[zones.zone(multiplier=k)]);f=zones.measured(h,position=point,covariance=covariance)
        out,meta=execute(binary,MODE,[h,f],status=2);assert not out;records.append(dict(name=name,**meta))
    assert native(binary,MODE,[head,encode(frame).replace('"track_id":1','"track_id":10e-1')])==prefix
    assert not execute(binary,MODE,payload=b"",status=2)[0]
    return {"rejected_cases":len(records),"records":records,"raw_integral_exponent_token_supported":True,"complete_cli_prefix_preserved":True}


def reframe_checks(binary):
    source=reframe_reference.configuration(camera_reference.CAMERAS[0],"intersection-warm-brown")
    source["motion"].update(min_observations=2,min_span_us="100000",max_velocity_std_mps=1e5,max_position_std_m=1e5)
    frames=[checkpoints.frame(i*100000,[checkpoints.observation(1,camera_reference.distort_pixel([580+i*2,330+i*.5],camera_reference.CAMERAS[0]),[4,.7,6])]) for i in range(8)]
    cp=native(binary,"--checkpoint",[source]+frames[:4],count=1)[0]
    baseline=native(binary,"--stream",[{"resume":cp}]+frames[4:]);changed=reframe_reference.reframe(binary,[{"resume":cp}]+frames[4:],reframe_reference.TRANSFORMS[1]);future=native(binary,"--stream",changed)
    head=zones.configuration(source["session_id"],[zones.zone(vertices=[[12,8],[20,8],[20,14],[12,14]],multiplier=1)])
    counts=statistics()
    left,right=native(binary,MODE,[head]+baseline),native(binary,MODE,[head]+future)
    for inputs,outputs in [(baseline,left),(future,right)]:
        for frame,out in zip(inputs,outputs):check_frame(out,head,frame,counts)
    assert all(v["evidence"] for v in left+right)
    # Both are separately exact-enclosure checked. Pixel re-expression changes
    # rounded filter inputs slightly, so bound endpoints need not be identical.
    differences={}
    for a,b in zip(left,right):
        for x,y in zip(a["evidence"],b["evidence"]):
            assert x["decision"]==y["decision"]
            for key in ["minimum_quadratic_lower","minimum_quadratic_upper"]:differences[key]=max(differences.get(key,0.),abs(x[key]-y[key]))
    return {"status":"passed","prefix_frames":4,"continuation_frames":4,"exact_enclosure_checked_both_representations":True,"maximum_absolute_bound_endpoint_reframe_differences":differences}


def transport_checks(binary):
    head=zones.configuration();frame=zones.measured(head);expected=native(binary,MODE,[head,frame])
    for ending in [b"\n",b"\r\n"]:assert execute(binary,MODE,payload=ending.join(encode(v).encode() for v in [head,frame]))[0]==expected
    assert native(binary,MODE,[encode(head).ljust(1048576),encode(frame).ljust(1048576)])==expected
    assert not execute(binary,MODE,[encode(head).ljust(1048577)],status=2,extra=["--max-line-bytes","16777216"])[0]
    assert execute(binary,MODE,[head,frame,encode(frame).ljust(1048577)],status=2,extra=["--max-line-bytes","16777216"])[0]==expected
    return {"source_frame_utf16_limit":1048576,"LF_CRLF_unterminated_EOF":"passed","complete_prefix":"passed"}


def web_checks(binary):
    command=["node","--test","--test-reporter=tap","web/zone-intersection.test.mjs"]
    process=subprocess.run(command,cwd=str(ROOT),env=dict(os.environ,MOONGROUND_CLI=str(binary)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8",timeout=900)
    if process.returncode:raise AssertionError(process.stdout[-30000:]+process.stderr[-2000:])
    summary={};details={}
    for value in process.stdout.splitlines():
        match=re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$",value)
        if match:summary[match.group(1)]=int(match.group(2))
        for prefix,key in [("cut_points","cross_runtime"),("successful_empty_frames","actual_budgets"),("maximum_actual_edges_times_targets","maximum_work")]:
            if value.startswith('# {"'+prefix+'":'):details[key]=json.loads(value[2:])
    assert summary.get("tests")==summary.get("pass") and not summary.get("fail") and len(details)==3
    return {"status":"passed","summary":summary,"details":details,"command":" ".join(command),"node":subprocess.check_output(["node","--version"],text=True).strip(),"source_sha256":hashlib.sha256((ROOT/"web/zone-intersection.test.mjs").read_bytes()).hexdigest(),"bridge_sha256":hashlib.sha256((ROOT/"_build/site/moonground.mjs").read_bytes()).hexdigest(),"stdout_sha256":hashlib.sha256(process.stdout.encode()).hexdigest()}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--binary",type=Path,required=True);parser.add_argument("--web",action="store_true");parser.add_argument("--output",type=Path,default=ROOT/"validation/zone-intersection-results.json");args=parser.parse_args();binary=args.binary.resolve();started=time.perf_counter()
    version=reference.toolchain_version();assert "0.10.18" in str(version),version
    result={"format_version":"1","seed":SEED,"command":" ".join(shlex.quote(v) for v in [sys.executable]+sys.argv),"python":platform.python_version(),"numpy":np.__version__,"toolchain":version,"pinned_moon_home":os.environ.get("MOON_HOME"),"source_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),"independent_reference":"Fraction inverse covariance, exact original input differences, clamped rational segment minimization, closed centre membership; strict rational enclosure and decision checks without tolerance; NumPy secondary only","scope":"model_position_ellipse_convex_zone_intersection_not_containment_probability_or_physical_occupancy"}
    result["exact_numeric_reference"]=numeric_checks(binary);result["real_motion_and_old_checkpoint_recovery"]=real_checks(binary);result["strict_and_numerical_rejections"]=strict_checks(binary);result["warm_brown_reframe"]=reframe_checks(binary);result["transport"]=transport_checks(binary)
    if args.web:result["web_interchange"]=web_checks(binary)
    result.update(status="passed",elapsed_seconds=time.perf_counter()-started)
    with args.output.open("w",encoding="utf-8",newline="\n") as f:f.write(json.dumps(result,indent=2,ensure_ascii=True)+"\n")
    print(encode({"status":"passed","math_cases":result["exact_numeric_reference"]["cases"],"math_frames":result["exact_numeric_reference"]["frames"],"rows":result["exact_numeric_reference"]["rows"],"rejects":result["strict_and_numerical_rejections"]["rejected_cases"],"output":str(args.output)}))


if __name__=="__main__":main()
