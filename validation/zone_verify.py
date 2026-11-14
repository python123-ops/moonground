#!/usr/bin/env python3
"""Independent current-position convex-zone covariance evidence.

Fraction determines polygon winding. Binary64 edge/point differences define
the model inputs; Decimal evaluates the raw supporting cross/length and the
quadratic form under actual normalized binary64 normals, without production
compensation or factorization.
NumPy ellipse boundary samples are a secondary check, not a containment proof.
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


ROOT = Path(__file__).resolve().parents[1]
MODE = "--zone-evidence"
SEED = 20261201
MAX = 9223372036854775807
encode, native, run = gates.encode, gates.native, gates.execute
D = decimal.Decimal


def zone(identity="workspace", vertices=((0, 0), (1, 0), (1, 1), (0, 1)), multiplier=2):
    return {"zone_id": identity, "vertices_m": [list(point) for point in vertices], "sigma_multiplier": multiplier}


def configuration(name="zone-reference", zones=None, capacity=32):
    return {"session_id": name, "zones": zones or [zone()], "max_tracks": capacity}


def measured(config, timestamp=100, position=(.5, .5), covariance=(.01, 0, .01), identity=1, segment="1", status="ready"):
    item = gates.track(identity, position, timestamp, segment=segment, status=status)
    if status in ("initializing", "ready", "uncertain"):
        item.update(position_covariance=list(covariance), position_std_m=math.sqrt(max(covariance[0], covariance[2])))
    return gates.measurement(timestamp, [item], name=config["session_id"])


def winding(points):
    exact = [[Fraction.from_float(value) for value in point] for point in points]
    area = sum(a[0]*b[1]-a[1]*b[0] for a, b in zip(exact, exact[1:]+exact[:1]))
    return 1 if area > 0 else -1


def normals(selected):
    points = [list(map(float, point)) for point in selected["vertices_m"]]
    sign = winding(points)
    result = []
    for start, end in zip(points, points[1:]+points[:1]):
        dx, dy = end[0]-start[0], end[1]-start[1]
        scale = max(abs(dx), abs(dy))
        x, y = dx/scale, dy/scale
        # The saved outward normal follows the documented binary64 edge
        # length, not a second normalization of its rounded coefficients.
        length = scale*math.sqrt(x*x+y*y)
        result.append([sign*dy/length, -sign*dx/length])
    return result


def exact_band(selected, position, covariance):
    faces = []
    orientation=winding([list(map(float,p)) for p in selected["vertices_m"]])
    with decimal.localcontext() as context:
        context.prec = 220
        xx, xy, yy = [D.from_float(float(value)) for value in covariance]
        multiplier = D.from_float(float(selected.get("sigma_multiplier", 2)))
        for index, (start, normal) in enumerate(zip(selected["vertices_m"], normals(selected))):
            nx, ny = [D.from_float(value) for value in normal]
            delta = [float(position[i])-float(start[i]) for i in (0, 1)]
            x, y = [D.from_float(value) for value in delta]
            end=selected["vertices_m"][(index+1)%len(selected["vertices_m"])]
            edge=[float(end[i])-float(start[i]) for i in (0,1)]
            dx,dy=[D.from_float(value) for value in edge]
            # Keep raw-edge collinearity. A rounded normal dotted into the
            # edge's own endpoint can otherwise put that endpoint Outside.
            cross=dy*x-dx*y
            distance=orientation*cross/(dx*dx+dy*dy).sqrt()
            variance = nx*nx*xx+2*nx*ny*xy+ny*ny*yy
            assert variance > 0
            sigma = variance.sqrt()
            radius = multiplier*sigma
            faces.append({"edge_index": index, "outward_normal": normal, "distance_m": float(distance),
                "normal_std_m": float(sigma), "lower_m": float(distance-radius), "upper_m": float(distance+radius)})
    separated = [value["edge_index"] for value in faces if value["lower_m"] > 0]
    decision = "inside" if all(value["upper_m"] <= 0 for value in faces) else "outside" if separated else "indeterminate"
    return {"zone_id": selected["zone_id"], "sigma_multiplier": selected.get("sigma_multiplier", 2),
        "faces": faces, "decision": decision, "separating_edge_index": separated[0] if separated else None}


def oracle(config, frame):
    evidence, unavailable = [], []
    for item in sorted(frame["tracks"], key=lambda value: value["track_id"]):
        if item["status"] != "ready":
            unavailable.append({"track_id": item["track_id"], "segment_id": item["segment_id"], "reason": item["status"]})
        else:
            for selected in config["zones"]:
                evidence.append(dict(track_id=item["track_id"], segment_id=item["segment_id"],
                    **exact_band(selected, item["position_m"], item["position_covariance"])))
    return {"schema_version": "0.1.0", "kind": "zone_evidence_frame", "evidence_scope": "model_position_halfplane_bands",
        "session_id": frame["session_id"], "timestamp_us": frame["timestamp_us"], "evidence": evidence, "unavailable": unavailable}


def compare(actual, expected, absolute, scaled, where="$"):
    if isinstance(expected, dict):
        assert set(actual) == set(expected), where
        for key in expected: compare(actual[key], expected[key], absolute, scaled, where+"."+key)
    elif isinstance(expected, list):
        assert len(actual) == len(expected), where
        for left, right in zip(actual, expected): compare(left, right, absolute, scaled, where+"[]")
    elif isinstance(expected, float):
        error = abs(actual-expected)
        denominator = max(abs(expected), 1e-300)
        absolute[where] = max(absolute.get(where, 0), error)
        scaled[where] = max(scaled.get(where, 0), error/denominator)
        assert error <= 5e-10*denominator, (where, actual, expected)
    else:
        assert actual == expected, (where, actual, expected)


def fixtures():
    cases = []
    head=configuration("slanted_original_boundary",[zone(vertices=[[0,0],[3,4],[0,5]],multiplier=0)])
    points=[(0,0),(3,4),(0,5),(1.5,2),(1.5,4.5),(0,2.5),
        (1.5,float(np.nextafter(2.,0.))),(1.5,float(np.nextafter(2.,3.)))]
    cases.append(("slanted_original_boundary",head,[measured(head,i,p) for i,p in enumerate(points)]))
    for k in (0, 1, 2):
        head = configuration("closed-bands-{}".format(k), [zone(multiplier=k)])
        points = ((.5,.5),(1,1),(1.2,1.2),(1.25,.5),(float(np.nextafter(1.25, 2)),.5),(1.5,.5),(-.5,.5))
        cases.append((head["session_id"], head, [measured(head, i, point, (.0625,0,.0625)) for i, point in enumerate(points)]))
    for scale in (1e-150, 1, 1e150):
        for sign in (-1, 1):
            vertices = [[-scale,-scale],[scale,-scale],[scale,scale],[-scale,scale]]
            head = configuration("correlated-{}-{}".format(scale,sign), [zone(vertices=vertices)])
            covariance = (.01*scale*scale, sign*.009*scale*scale, .01*scale*scale)
            cases.append((head["session_id"],head,[measured(head,i,(x*scale,y*scale),covariance) for i,(x,y) in enumerate(((0,0),(.9,0),(1.3,0),(1.1,1.1)))]))
    vertices = [[-2,-1],[2,-1],[3,2],[-1,3]]
    for index, points in enumerate([vertices,vertices[::-1],vertices[2:]+vertices[:2]]):
        head = configuration("winding-{}".format(index), [zone(vertices=points)])
        cases.append((head["session_id"],head,[measured(head,i,p,(.01,.002,.02)) for i,p in enumerate(((0,0),(4,0),(-2,3)))]))
    for name, matrix, shift, scale in [
        ("rotation",np.array([[.6,-.8],[.8,.6]]),[0,0],1),
        ("reflection",np.array([[-1.,0],[0,1.]]),[0,0],1),
        ("translation",np.eye(2),[1000,-2000],1),
        ("metric_scale",np.eye(2),[0,0],3.5),
    ]:
        transform = matrix*scale
        points = (np.asarray(vertices)@transform.T+shift).tolist()
        covariance = reference.compact_covariance(transform@np.array([[.01,.002],[.002,.02]])@transform.T)
        head = configuration(name,[zone(vertices=points)])
        cases.append((name,head,[measured(head,i,transform@np.asarray(p)+shift,covariance) for i,p in enumerate(((0,0),(4,0),(-2,3)))]))
    for name,covariance in [("anisotropic",(100,0,.0001)),("supported_correlation",(1,-(1-1e-10),1))]:
        head=configuration(name,[zone(vertices=[[-10,-10],[10,-10],[10,10],[-10,10]])])
        cases.append((name,head,[measured(head,position=(0,0),covariance=covariance)]))
    head=configuration("lifecycle")
    statuses=("initializing","ready","uncertain","rejected_innovation","numerical_failure","rejected_projection")
    frames=[measured(head,10+i,status=status) for i,status in enumerate(statuses)]
    frames += [gates.measurement(0,name=head["session_id"]), measured(head,MAX),measured(head,9007199254740993)]
    cases.append(("all_statuses_exact_clock_and_empty",head,frames))
    head=configuration("defaults");del head["max_tracks"];del head["zones"][0]["sigma_multiplier"]
    cases.append(("optional_defaults",head,[measured(head)]))
    return cases


def numeric_checks(binary):
    absolute,scaled,records,decisions={}, {}, [], set()
    sampled_inside=0
    for name,head,frames in fixtures():
        actual=native(binary,MODE,[head]+frames)
        if name=="slanted_original_boundary":
            # A separate exact geometric assertion, beyond matching numeric
            # diagnostics, prevents rounded-normal self-boundary regressions.
            assert [v["evidence"][0]["decision"] for v in actual]==["inside"]*6+["outside","inside"]
        for frame,output in zip(frames,actual):
            compare(output,oracle(head,frame),absolute,scaled)
            decisions.update(row["decision"] for row in output["evidence"])
            # A secondary geometric check for ordinary-scale cases only.
            for row in output["evidence"]:
                if row["decision"] != "inside" or name.startswith("correlated-1e"): continue
                item=next(value for value in frame["tracks"] if value["track_id"]==row["track_id"])
                selected=next(value for value in head["zones"] if value["zone_id"]==row["zone_id"])
                matrix=reference.covariance_matrix(item["position_covariance"])
                if np.linalg.cond(matrix)>1e6: continue
                theta=np.linspace(0,2*np.pi,257)
                circle=np.array([np.cos(theta),np.sin(theta)])
                points=np.asarray(item["position_m"])[:,None]+selected.get("sigma_multiplier",2)*np.linalg.cholesky(matrix)@circle
                for start,normal in zip(selected["vertices_m"],normals(selected)):
                    assert np.max(np.asarray(normal)@(points-np.asarray(start)[:,None])) < 2e-11
                sampled_inside+=1
        order=list(reversed(range(len(frames))))+list(range(len(frames)))
        assert native(binary,MODE,[head]+[frames[i] for i in order]) == [actual[i] for i in order]
        records.append({"name":name,"frames":len(frames),"evidence_rows":sum(len(v["evidence"]) for v in actual),
            "face_rows":sum(len(row["faces"]) for v in actual for row in v["evidence"])})
    assert decisions=={"inside","outside","indeterminate"}
    # This is disjoint but no single supporting face separates it.
    head=configuration(zones=[zone(multiplier=1)])
    corner=native(binary,MODE,[head,measured(head,position=(1.2,1.2),covariance=(.0625,0,.0625))])[0]["evidence"][0]
    assert math.hypot(.2,.2)>.25 and corner["decision"]=="indeterminate" and corner["separating_edge_index"] is None
    return {"cases":len(records),"frames":sum(v["frames"] for v in records),"evidence_rows":sum(v["evidence_rows"] for v in records),
        "face_rows":sum(v["face_rows"] for v in records),"maximum_absolute_decimal_errors":absolute,"maximum_relative_or_scaled_decimal_errors":scaled,
        "numpy_boundary_sample_checks":sampled_inside,"sampled_points_per_ellipse":257,"corner_disjoint_is_conservatively_indeterminate":True,
        "repeat_and_reordering_exact":True,"records":records}


def real_checks(binary):
    records,statuses,absolute,scaled=[],set(),{},{}
    for name,measurement,_,frames in analysis_reference.fixtures():
        outputs=native(binary,"--stream",[measurement]+frames)
        head=configuration(measurement["session_id"],[zone(vertices=[[-100,-100],[100,-100],[100,100],[-100,100]])])
        expected=native(binary,MODE,[head]+outputs)
        for frame,result in zip(outputs,expected):
            compare(result,oracle(head,frame),absolute,scaled)
            statuses.update(item["status"] for item in frame["tracks"])
        for cut in range(len(frames)+1):
            saved=native(binary,"--checkpoint",[measurement]+frames[:cut],count=1)[0]
            continued=native(binary,"--stream",[{"resume":saved}]+frames[cut:])
            assert continued==outputs[cut:]
            assert native(binary,MODE,[head]+continued)==expected[cut:]
        records.append({"name":name,"frames":len(frames),"old_checkpoint_cut_points":len(frames)+1,
            "evidence_rows":sum(len(v["evidence"]) for v in expected)})
    assert {"initializing","ready","uncertain","rejected_innovation","numerical_failure","rejected_projection"}.issubset(statuses)
    return {"cases":len(records),"frames":sum(v["frames"] for v in records),"old_checkpoint_cut_points":sum(v["old_checkpoint_cut_points"] for v in records),
        "statuses":sorted(statuses),"maximum_absolute_decimal_errors":absolute,"maximum_relative_or_scaled_decimal_errors":scaled,
        "independent_authored_motion_numpy":checkpoints.independent_reference_checks(binary),"records":records}


def rejection_checks(binary):
    head=configuration();frame=measured(head);prefix=native(binary,MODE,[head,frame]);records=[]
    def bad(name,source=head,value=None,payload=None):
        actual,metadata=run(binary,MODE,[source,frame,value] if value is not None else [source],status=2,payload=payload)
        assert actual==(prefix if value is not None or payload is not None else []),name
        records.append(dict(name=name,**metadata))
    for name,vertices in [
        ("two_vertices",[[0,0],[1,0]]),("duplicate_vertex",[[0,0],[1,0],[1,0],[0,1]]),
        ("collinear",[[0,0],[1,0],[2,0],[0,1]]),("concave",[[0,0],[2,0],[.5,.5],[0,2]]),
        ("crossed",[[0,0],[1,1],[0,1],[1,0]]),
        ("same_turn_star",[[math.cos(4*math.pi*i/5),math.sin(4*math.pi*i/5)] for i in range(5)]),
        ("near_collinear_unsupported",[[0,0],[1,0],[1,1e-14],[0,1]]),
        ("edge_difference_overflow",[[-1e308,0],[1e308,0],[0,1e308]]),
        ("normal_component_underflow",[[0,0],[1e300,1e-300],[1e300,1e300],[0,1e300]]),
        ("too_many_vertices",[[math.cos(2*math.pi*i/33),math.sin(2*math.pi*i/33)] for i in range(33)]),
    ]: bad(name,configuration(zones=[zone(vertices=vertices)]))
    for name,mutate in [("empty_zones",lambda v:v.update(zones=[])),("duplicate_zone_ids",lambda v:v.update(zones=[zone(),zone()])),
        ("seventeen_zones",lambda v:v.update(zones=[zone(str(i)) for i in range(17)])),
        ("negative_multiplier",lambda v:v["zones"][0].update(sigma_multiplier=-1)),("empty_zone_id",lambda v:v["zones"][0].update(zone_id="")),
        ("long_zone_id",lambda v:v["zones"][0].update(zone_id="x"*129)),("unknown_zone_field",lambda v:v["zones"][0].update(extra=0)),
        ("empty_session",lambda v:v.update(session_id="")),("zero_capacity",lambda v:v.update(max_tracks=0)),
        ("facet_work_budget",lambda v:v.update(max_tracks=10000,zones=[zone("a"),zone("b")])),
        ("too_large_capacity",lambda v:v.update(max_tracks=10001)),("resume_not_supported",lambda v:v.update(resume={}))]:
        value=copy.deepcopy(head);mutate(value);bad(name,value)
    for name,source in [("fractional_capacity",encode(head).replace('"max_tracks":32','"max_tracks":32.000000000000001')),
        ("duplicate_source_key",'{"session_id":"duplicate",'+encode(head)[1:]),
        ("duplicate_zone_key",encode(head).replace('"sigma_multiplier":2','"sigma_multiplier":2,"sigma_multiplier":1'))]:bad(name,source)
    for name,mutate in [("wrong_session",lambda v:v.update(session_id="other")),("stale_ready",lambda v:v["tracks"][0].update(last_accepted_timestamp_us="99")),
        ("future_accepted",lambda v:v["tracks"][0].update(last_accepted_timestamp_us="101")),("missing_position",lambda v:v["tracks"][0].update(position_m=None)),
        ("non_spd",lambda v:v["tracks"][0].update(position_covariance=[1,2,1])),("duplicate_track",lambda v:v["tracks"].append(copy.deepcopy(v["tracks"][0]))),
        ("duplicate_segment",lambda v:v["tracks"].append(dict(copy.deepcopy(v["tracks"][0]),track_id=2))),
        ("noncanonical_segment",lambda v:v["tracks"][0].update(segment_id="01")),("closed_current",lambda v:v.update(closed_segment_ids=["1"])),
        ("unknown_frame_field",lambda v:v.update(extra=True))]:
        value=copy.deepcopy(frame);mutate(value);bad(name,value=value)
    bad("fractional_track_id",value=encode(frame).replace('"track_id":1','"track_id":1.0000000000000001'))
    for name,source,position,covariance in [
        ("near_singular",configuration(zones=[zone(vertices=[[0,-2],[2,0],[0,2],[-2,0]])]),(0,0),(1,float(np.nextafter(1.,0.)),1)),
        ("radius_overflow",configuration(zones=[zone(multiplier=1e308)]),(.5,.5),(1e308,0,1e308)),
        ("radius_underflow",configuration(zones=[zone(multiplier=5e-324)]),(.5,.5),(5e-324,0,5e-324)),
        ("endpoint_swallowing",head,(1e300,.5),(1,0,1)),
    ]:
        actual,metadata=run(binary,MODE,[source,measured(source,position=position,covariance=covariance)],status=2)
        assert not actual
        records.append(dict(name=name,**metadata))
    bad("invalid_utf8_tail",payload=gates.lines([head,frame]).encode()+b"\xff\n")
    _,metadata=run(binary,MODE,[],status=2,payload=b"");records.append(dict(name="missing_header",**metadata))
    assert native(binary,MODE,[head,encode(frame).replace('"track_id":1','"track_id":10e-1')])==prefix
    return {"rejected_cases":len(records),"cases":records,"complete_prefix_preserved":True,"integral_raw_id_token":"passed","no_persistent_state":True}


def reframe_checks(binary):
    source=reframe_reference.configuration(camera_reference.CAMERAS[0],"zone-warm-brown")
    source["motion"].update(min_observations=2,min_span_us="100000",max_velocity_std_mps=1e5,max_position_std_m=1e5)
    frames=[checkpoints.frame(i*100000,[checkpoints.observation(1,camera_reference.distort_pixel([580+i*2,330+i*.5],camera_reference.CAMERAS[0]),[4,.7,6])]) for i in range(8)]
    saved=native(binary,"--checkpoint",[source]+frames[:4],count=1)[0]
    baseline=native(binary,"--stream",[{"resume":saved}]+frames[4:])
    changed=reframe_reference.reframe(binary,[{"resume":saved}]+frames[4:],reframe_reference.TRANSFORMS[1])
    future=native(binary,"--stream",changed)
    head=configuration(source["session_id"],[zone(vertices=[[-100,-100],[100,-100],[100,100],[-100,100]])])
    expected,actual=native(binary,MODE,[head]+baseline),native(binary,MODE,[head]+future)
    errors={};gates.tree_close(actual,expected,errors)
    assert sum(len(v["evidence"]) for v in actual)>0
    return {"status":"passed","brown_warm_prefix_frames":4,"continuation_frames":4,"maximum_absolute_metric_reframe_differences":errors}


def transport_checks(binary):
    head=configuration();frame=measured(head);expected=native(binary,MODE,[head,frame])
    for ending in (b"\n",b"\r\n"):
        assert run(binary,MODE,payload=ending.join(encode(v).encode() for v in [head,frame]))[0]==expected
    assert native(binary,MODE,[encode(head).ljust(1048576),encode(frame).ljust(1048576)])==expected
    _,source_overflow=run(binary,MODE,[encode(head).ljust(1048577)],status=2,extra=["--max-line-bytes","16777216"])
    values,frame_overflow=run(binary,MODE,[head,frame,encode(frame).ljust(1048577)],status=2,extra=["--max-line-bytes","16777216"])
    assert values==expected
    return {"crlf_and_unterminated_eof":"passed","source_and_frame_exact_units":1048576,"source_overflow":source_overflow,"frame_overflow_complete_prefix":frame_overflow}


def web_checks(binary):
    command=["node","--test","--test-reporter=tap","web/zone.test.mjs"]
    result=subprocess.run(command,cwd=str(ROOT),env=dict(os.environ,MOONGROUND_CLI=str(binary)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8",timeout=360)
    if result.returncode:raise AssertionError("Node zones failed:\n"+result.stdout[-18000:]+result.stderr[-2000:])
    summary,cross,batch={},None,None
    for value in result.stdout.splitlines():
        match=re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$",value)
        if match:summary[match.group(1)]=int(match.group(2))
        if value.startswith('# {"cut_points":'):cross=json.loads(value[2:])
        if value.startswith('# {"successful_empty_frames":'):batch=json.loads(value[2:])
    assert summary.get("tests") and summary["tests"]==summary["pass"] and not summary["fail"] and cross and batch
    return {"status":"passed","node":subprocess.check_output(["node","--version"],text=True).strip(),"command":" ".join(command),"summary":summary,
        "old_checkpoint_cross_runtime":cross,"measured_bounded_batch":batch,"test_script_sha256":hashlib.sha256((ROOT/"web/zone.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256":hashlib.sha256((ROOT/"_build/site/moonground.mjs").read_bytes()).hexdigest(),"stdout_sha256":hashlib.sha256(result.stdout.encode()).hexdigest(),"stderr":result.stderr.strip()}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--binary",type=Path,required=True);parser.add_argument("--web",action="store_true")
    parser.add_argument("--output",type=Path,default=ROOT/"validation/zone-results.json");args=parser.parse_args();binary=args.binary.resolve();started=time.perf_counter()
    result={"format_version":"1","fixtures":"deterministic","seed":SEED,"command":" ".join(shlex.quote(v) for v in [sys.executable]+sys.argv),
        "python":platform.python_version(),"numpy":np.__version__,"toolchain":reference.toolchain_version(),"source_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),"evidence_scope":"model_position_halfplane_bands","scaled_error_denominator":"max(abs(reference),1e-300)",
        "independent_reference":"Fraction winding; binary64 edge/offset differences; Decimal220 raw supporting cross/length and quadratic under actual binary64 normal; rounded endpoint classification; NumPy ellipse samples are secondary checks"}
    result["numeric_reference"]=numeric_checks(binary);result["original_motion_and_checkpoint_continuations"]=real_checks(binary)
    result["strict_and_numerical_rejections"]=rejection_checks(binary);result["warm_brown_reframe"]=reframe_checks(binary);result["bounded_transport"]=transport_checks(binary)
    if args.web:result["web_interchange"]=web_checks(binary)
    result.update(status="passed",elapsed_seconds=time.perf_counter()-started);args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open("w",encoding="utf-8",newline="\n") as f:f.write(json.dumps(result,indent=2,ensure_ascii=True)+"\n")
    print(encode({"status":"passed","numeric_cases":result["numeric_reference"]["cases"],"real_cases":result["original_motion_and_checkpoint_continuations"]["cases"],"strict_rejections":result["strict_and_numerical_rejections"]["rejected_cases"],"output":str(args.output)}))


if __name__=="__main__":main()
