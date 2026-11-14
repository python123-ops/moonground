#!/usr/bin/env python3
"""Independent current target identity/time joins and mixed physical footprint bands.

Decimal evaluates raw-edge distance, the full covariance quadratic form and
deterministic vertex supports independently of the production expansion. The old
zone paths separately check exact grouped disk/convex equivalence and unchanged
position diagnostics. No dimensions are inferred from detector or velocity data.
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
import disk_zone_verify as disk_reference
import footprint_zone_verify as convex_reference




ROOT=Path(__file__).resolve().parents[1]
MODE="--assigned-zone-evidence"
SCOPE="model_position_halfplane_bands_plus_current_target_footprints"
encode,native,run=gates.encode,gates.native,gates.execute
DEFAULT=convex_reference.DEFAULT
MAX=9223372036854775807


def disk(radius=.125):return {"kind":"disk","radius_m":radius}
def convex(vertices=None):return {"kind":"convex","vertices_offset_m":DEFAULT if vertices is None else vertices}
def assignment(track,shape):return {"track_id":track["track_id"],"segment_id":track["segment_id"],"shape":shape}
def bundle(frame,items=None):
    if items is None:
        items=[assignment(item,disk(.25) if (item["track_id"]+int(frame["timestamp_us"])//100000)%2 else convex()) for item in frame["tracks"] if item["segment_id"] is not None]
    return {"timestamp_us":frame["timestamp_us"],"footprints":items}
def wrap(frame,assignments=None):return {"measurement":frame if isinstance(frame,str) else encode(frame),"assignments":assignments if isinstance(assignments,str) else encode(bundle(frame) if assignments is None else assignments)}


def with_shape(row,shape):
    value=copy.deepcopy(row);value["shape_kind"]=shape["kind"]
    if shape["kind"]=="disk":
        for face in value["faces"]:face.update(footprint_lower_m=-shape["radius_m"],footprint_upper_m=shape["radius_m"])
    return value


def oracle(position,frame,assignments):
    assert frame["timestamp_us"]==assignments["timestamp_us"]
    by_id={v["track_id"]:v for v in assignments["footprints"]}
    evidence,unavailable=[],[]
    for item in sorted(frame["tracks"],key=lambda value:value["track_id"]):
        selected=by_id.get(item["track_id"])
        if selected:assert selected["segment_id"]==item["segment_id"]
        reason=item["status"] if item["status"]!="ready" else "missing_footprint" if not selected else None
        if reason:unavailable.append({"track_id":item["track_id"],"segment_id":item["segment_id"],"reason":reason});continue
        shape=selected["shape"]
        for region in position["zones"]:
            band=(disk_reference.exact_band(region,item["position_m"],item["position_covariance"],shape["radius_m"]) if shape["kind"]=="disk" else
                convex_reference.exact_band(region,item["position_m"],item["position_covariance"],shape["vertices_offset_m"]))
            evidence.append(with_shape(dict(track_id=item["track_id"],segment_id=item["segment_id"],**band),shape))
    return {"schema_version":"0.1.0","kind":"assigned_zone_evidence_frame","evidence_scope":SCOPE,"session_id":frame["session_id"],"timestamp_us":frame["timestamp_us"],"evidence":evidence,"unavailable":unavailable}


def grouped(binary,position,frame,assignments):
    # Original full-frame position evaluation is deliberately performed first;
    # omitted assignments cannot conceal old Ready numerical errors.
    point=native(binary,"--zone-evidence",[position,frame])[0]
    by_id={v["track_id"]:v for v in assignments["footprints"]};expected=copy.deepcopy(point)
    expected.update(kind="assigned_zone_evidence_frame",evidence_scope=SCOPE,evidence=[])
    for item in sorted(frame["tracks"],key=lambda value:value["track_id"]):
        if item["status"]!="ready":continue
        selected=by_id.get(item["track_id"])
        if not selected:
            expected["unavailable"].append({"track_id":item["track_id"],"segment_id":item["segment_id"],"reason":"missing_footprint"});continue
        shape=selected["shape"];sub=dict(frame,tracks=[item])
        mode,head=("--disk-zone-evidence",disk_reference.source(position,shape["radius_m"])) if shape["kind"]=="disk" else ("--footprint-zone-evidence",convex_reference.source(position,shape["vertices_offset_m"]))
        expected["evidence"].extend(with_shape(row,shape) for row in native(binary,mode,[head,sub])[0]["evidence"])
    expected["unavailable"].sort(key=lambda v:v["track_id"])
    return expected


def fixtures():
    cases=[]
    for name,position,vertices,frames in convex_reference.fixtures():
        extent=max(max(p[i] for p in zone["vertices_m"])-min(p[i] for p in zone["vertices_m"]) for zone in position["zones"] for i in (0,1))
        measured,assigned=[],[]
        for frame in frames:
            current=copy.deepcopy(frame);current["tracks"]=[];items=[]
            for source in frame["tracks"]:
                for identity,segment,shape in [(5,str(MAX),disk(.03125*extent)),(2,"9007199254740993",convex(vertices)),(9,"1",None)]:
                    item=dict(copy.deepcopy(source),track_id=identity)
                    if item["segment_id"] is not None:item["segment_id"]=segment
                    current["tracks"].append(item)
                    if shape is not None and item["segment_id"] is not None:items.append(assignment(item,shape))
            measured.append(current);assigned.append(bundle(current,list(reversed(items))))
        cases.append((name,position,measured,assigned))
    return cases


def numeric_checks(binary):
    absolute,scaled,records={}, {}, []
    shapes,missing=0,0
    for name,position,frames,assignments in fixtures():
        actual=native(binary,MODE,[position]+[wrap(f,a) for f,a in zip(frames,assignments)])
        for frame,items,result in zip(frames,assignments,actual):
            position_reference.compare(result,oracle(position,frame,items),absolute,scaled)
            assert result==grouped(binary,position,frame,items),name
            shapes+=len(result["evidence"]);missing+=sum(v["reason"]=="missing_footprint" for v in result["unavailable"])
        order=list(reversed(range(len(frames))))+list(range(len(frames)))
        assert native(binary,MODE,[position]+[wrap(frames[i],assignments[i]) for i in order])==[actual[i] for i in order]
        records.append({"name":name,"frames":len(frames),"evidence_rows":sum(len(v["evidence"]) for v in actual),"face_rows":sum(len(row["faces"]) for v in actual for row in v["evidence"])})
    return {"cases":len(records),"frames":sum(v["frames"] for v in records),"evidence_rows":shapes,"face_rows":sum(v["face_rows"] for v in records),"missing_ready_rows":missing,
        "grouped_old_disk_and_convex_exact":True,"old_position_bands_preserved_exactly":True,"stateless_repeat_and_reordering_exact":True,
        "maximum_absolute_decimal_errors":absolute,"maximum_relative_or_scaled_decimal_errors":scaled,"records":records}


def real_checks(binary):
    records,statuses,absolute,scaled=[],set(),{},{};observed_shapes=set()
    for name,measurement,_,frames in analysis_reference.fixtures():
        outputs=native(binary,"--stream",[measurement]+frames)
        position=position_reference.configuration(measurement["session_id"],[position_reference.zone(vertices=[[-100,-100],[100,-100],[100,100],[-100,100]])])
        expected=native(binary,MODE,[position]+[wrap(v) for v in outputs])
        for frame,result in zip(outputs,expected):
            position_reference.compare(result,oracle(position,frame,bundle(frame)),absolute,scaled);assert result==grouped(binary,position,frame,bundle(frame))
            statuses.update(item["status"] for item in frame["tracks"]);observed_shapes.update(item["shape_kind"] for item in result["evidence"])
        for cut in range(len(frames)+1):
            saved=native(binary,"--checkpoint",[measurement]+frames[:cut],count=1)[0]
            continued=native(binary,"--stream",[{"resume":saved}]+frames[cut:])
            assert continued==outputs[cut:] and native(binary,MODE,[position]+[wrap(v) for v in continued])==expected[cut:]
        records.append({"name":name,"frames":len(frames),"old_checkpoint_cut_points":len(frames)+1,"evidence_rows":sum(len(v["evidence"]) for v in expected)})
    assert {"initializing","ready","uncertain","rejected_innovation","numerical_failure","rejected_projection"}.issubset(statuses)
    assert observed_shapes=={"disk","convex"}
    return {"shape_kinds":sorted(observed_shapes),"cases":len(records),"frames":sum(v["frames"] for v in records),"old_checkpoint_cut_points":sum(v["old_checkpoint_cut_points"] for v in records),
        "statuses":sorted(statuses),"maximum_absolute_decimal_errors":absolute,"maximum_relative_or_scaled_decimal_errors":scaled,"records":records}


def binding_checks(binary):
    position=position_reference.configuration();timestamp=9007199254740993
    tracks=[]
    for i,status in enumerate(["ready","ready","initializing","uncertain","rejected_innovation","numerical_failure","rejected_projection"],1):
        tracks.extend(position_reference.measured(position,timestamp,identity=i,segment=str(MAX-i),status=status)["tracks"])
    frame=gates.measurement(timestamp,tracks,name=position["session_id"])
    items=[assignment(v,convex() if v["track_id"]%2 else disk(.25)) for v in tracks if v["segment_id"] is not None and v["track_id"]!=2]
    current=bundle(frame,list(reversed(items)));result=native(binary,MODE,[position,wrap(frame,current)])[0]
    assert result==grouped(binary,position,frame,current)
    assert [v["reason"] for v in result["unavailable"]]==["missing_footprint","initializing","uncertain","rejected_innovation","numerical_failure","rejected_projection"]
    rejected=position_reference.measured(position,100,identity=1,segment="7",status="rejected_innovation");rejected["closed_segment_ids"]=["7"]
    assert native(binary,MODE,[position,wrap(rejected)])[0]["unavailable"][0]["reason"]=="rejected_innovation"
    # Reusing an ID in a fresh segment is accepted only with a fresh exact pair.
    first=position_reference.measured(position,0,segment="1");later=position_reference.measured(position,1,segment=str(MAX))
    outputs=native(binary,MODE,[position,wrap(first),wrap(later)])
    assert outputs[0]["evidence"][0]["segment_id"]=="1" and outputs[1]["evidence"][0]["segment_id"]==str(MAX)
    return {"status":"passed","all_original_reasons_before_missing":True,"matched_nonready_allowed":True,"rejected_plus_closed_allowed":True,"same_id_new_segment_reissued":True,"exact_clock_us":str(timestamp),"exact_segment_id":str(MAX)}


def rejection_checks(binary):
    position=position_reference.configuration();frame=position_reference.measured(position);doc=bundle(frame);first=wrap(frame,doc);prefix=native(binary,MODE,[position,first]);records=[]
    def bad(name,value,head=position):
        result,metadata=run(binary,MODE,[head,first,value],status=2);assert result==prefix,name;records.append(dict(name=name,**metadata))
    for name,value in [("missing_measurement",{"assignments":encode(doc)}),("missing_assignments",{"measurement":encode(frame)}),
        ("measurement_not_raw",dict(first,measurement=frame)),("assignments_not_raw",dict(first,assignments=doc)),("unknown_wrapper",dict(first,extra=True)),
        ("duplicate_wrapper",'{"measurement":"duplicate",'+encode(first)[1:])]:bad(name,value)
    invalid=[("missing_clock",{"footprints":doc["footprints"]}),("numeric_clock",dict(doc,timestamp_us=100)),("negative_clock",dict(doc,timestamp_us="-1")),
        ("leading_zero_clock",dict(doc,timestamp_us="0100")),("clock_overflow",dict(doc,timestamp_us=str(MAX+1))),("wrong_clock",dict(doc,timestamp_us="101")),
        ("unknown_document",dict(doc,extra=1)),("missing_items",{"timestamp_us":"100"}),("duplicate_document",'{"timestamp_us":"100",'+encode(doc)[1:]),
        ("duplicate_id",dict(doc,footprints=doc["footprints"]*2)),("extra_id",dict(doc,footprints=[dict(doc["footprints"][0],track_id=9)])),
        ("stale_segment",dict(doc,footprints=[dict(doc["footprints"][0],segment_id="2")])),("noncanonical_segment",dict(doc,footprints=[dict(doc["footprints"][0],segment_id="01")]))]
    for name,value in invalid:bad(name,wrap(frame,value))
    for name,shape in [("unknown_kind",{"kind":"capsule","radius_m":.25}),("negative_disk",disk(-1)),("disk_unknown_field",dict(disk(),extra=True)),
        ("disk_with_vertices",dict(disk(),vertices_offset_m=DEFAULT)),("convex_with_radius",dict(convex(),radius_m=.25)),("degenerate_convex",convex([[0,0]])),
        ("origin_outside_convex",convex([[1,1],[2,1],[1,2]])),("nonfinite_disk_raw",None)]:
        changed=copy.deepcopy(doc);changed["footprints"][0]["shape"]=shape
        text=encode(changed) if shape is not None else encode(doc).replace('"radius_m":0.25','"radius_m":1e999')
        bad(name,wrap(frame,text))
    bad("nested_assignment_depth",wrap(frame,'{"timestamp_us":"100","footprints":'+"["*33+"0"+"]"*33+"}"))
    raw=encode(doc)
    for name,value in [("fractional_assignment_id",raw.replace('"track_id":1','"track_id":1.0000000000000001')),
        ("duplicate_assignment_field",raw.replace('"track_id":1','"track_id":1,"track_id":1')),
        ("duplicate_shape_field",raw.replace('"kind":"disk"','"kind":"disk","kind":"disk"')),
        ("unknown_assignment_field",raw.replace('"track_id":1','"track_id":1,"extra":0'))]:bad(name,wrap(frame,value))
    for name,mutate in [("wrong_session",lambda v:v.update(session_id="other")),("stale_ready",lambda v:v["tracks"][0].update(last_accepted_timestamp_us="99")),
        ("duplicate_track",lambda v:v["tracks"].append(copy.deepcopy(v["tracks"][0]))),("non_spd",lambda v:v["tracks"][0].update(position_covariance=[1,2,1])),
        ("missing_position",lambda v:v["tracks"][0].update(position_m=None)),("closed_current",lambda v:v.update(closed_segment_ids=["1"])),("unknown_frame",lambda v:v.update(extra=True))]:
        changed=copy.deepcopy(frame);mutate(changed);bad(name,wrap(changed,doc))
    projection=position_reference.measured(position,status="rejected_projection");bad("cannot_bind_projection_without_segment",wrap(projection,doc))
    empty=gates.measurement(100,[],["1"],name=position["session_id"]);bad("cannot_bind_closed_only",wrap(empty,doc))
    late=position_reference.measured(position,position=(1e300,.5),covariance=(1,0,1));bad("missing_cannot_bypass_old_numerics",wrap(late,bundle(late,[])))
    huge=copy.deepcopy(doc);huge["footprints"][0]["shape"]=disk(1e16);bad("late_expansion_error",wrap(frame,huge))
    assert native(binary,MODE,[position,wrap(frame,raw.replace('"track_id":1','"track_id":10e-1'))])==prefix
    # A failed batch has no retained clock; corrected same raw frame still works.
    assert native(binary,MODE,[position,first])==prefix
    _,metadata=run(binary,MODE,payload=gates.lines([position,first]).encode()+b"\xff\n",status=2);assert metadata["complete_output_lines"]==1;records.append(dict(name="invalid_utf8_prefix",**metadata))
    _,metadata=run(binary,MODE,payload=b"",status=2);records.append(dict(name="missing_header",**metadata))
    return {"rejected_cases":len(records),"cases":records,"complete_prefix_preserved":True,"integral_raw_id_token":"passed","stateless_same_frame_retry":"passed"}


def reframe_checks(binary):
    raw=reframe_reference.configuration(camera_reference.CAMERAS[0],"assigned-zone-warm-brown")
    raw["motion"].update(min_observations=2,min_span_us="100000",max_velocity_std_mps=1e5,max_position_std_m=1e5)
    frames=[checkpoints.frame(i*100000,[checkpoints.observation(1,camera_reference.distort_pixel([580+i*2,330+i*.5],camera_reference.CAMERAS[0]),[4,.7,6])]) for i in range(8)]
    saved=native(binary,"--checkpoint",[raw]+frames[:4],count=1)[0];baseline=native(binary,"--stream",[{"resume":saved}]+frames[4:])
    changed=reframe_reference.reframe(binary,[{"resume":saved}]+frames[4:],reframe_reference.TRANSFORMS[1]);future=native(binary,"--stream",changed)
    position=position_reference.configuration(raw["session_id"],[position_reference.zone(vertices=[[-100,-100],[100,-100],[100,100],[-100,100]])])
    expected,actual=native(binary,MODE,[position]+[wrap(v) for v in baseline]),native(binary,MODE,[position]+[wrap(v) for v in future]);errors={};gates.tree_close(actual,expected,errors)
    assert {row["shape_kind"] for v in actual for row in v["evidence"]}=={"disk","convex"}
    return {"status":"passed","shape_kinds":["convex","disk"],"brown_warm_prefix_frames":4,"continuation_frames":4,"assignments_reissued_per_frame":True,"maximum_absolute_metric_reframe_differences":errors}


def transport_checks(binary):
    position=position_reference.configuration();frame=position_reference.measured(position);current=wrap(frame);expected=native(binary,MODE,[position,current])
    for ending in (b"\n",b"\r\n"):assert run(binary,MODE,payload=ending.join(encode(v).encode() for v in [position,current]))[0]==expected
    assert native(binary,MODE,[encode(position).ljust(1048576),encode(current).ljust(1048576)])==expected
    values,metadata=run(binary,MODE,[position,current,encode(current).ljust(1048577)],status=2,extra=["--max-line-bytes","16777216"]);assert values==expected
    return {"crlf_and_unterminated_eof":"passed","source_and_wrapped_frame_exact_units":1048576,"overflow_complete_prefix":metadata,"inner_budget_note":"Inner raw strings plus escaping and wrapper overhead share the wrapped frame 1Mi limit."}


def web_checks(binary):
    command=["node","--test","--test-reporter=tap","web/assigned-zone.test.mjs"]
    result=subprocess.run(command,cwd=str(ROOT),env=dict(os.environ,MOONGROUND_CLI=str(binary)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8",timeout=360)
    if result.returncode:raise AssertionError("Node assigned zones failed:\n"+result.stdout[-18000:]+result.stderr[-2000:])
    summary,cross,batch={},None,None
    for line in result.stdout.splitlines():
        match=re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$",line)
        if match:summary[match.group(1)]=int(match.group(2))
        if line.startswith('# {"cut_points":'):cross=json.loads(line[2:])
        if line.startswith('# {"successful_empty_frames":'):batch=json.loads(line[2:])
    assert summary.get("tests") and summary["tests"]==summary["pass"] and not summary["fail"] and cross and batch
    return {"status":"passed","node":subprocess.check_output(["node","--version"],text=True).strip(),"command":" ".join(command),"summary":summary,"old_checkpoint_cross_runtime":cross,
        "measured_bounded_batch":batch,"test_script_sha256":hashlib.sha256((ROOT/"web/assigned-zone.test.mjs").read_bytes()).hexdigest(),"bridge_sha256":hashlib.sha256((ROOT/"_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256":hashlib.sha256(result.stdout.encode()).hexdigest(),"stderr":result.stderr.strip()}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--binary",type=Path,required=True);parser.add_argument("--web",action="store_true")
    parser.add_argument("--output",type=Path,default=ROOT/"validation/assigned-zone-results.json");args=parser.parse_args();binary=args.binary.resolve();started=time.perf_counter()
    result={"format_version":"1","fixtures":"deterministic","command":" ".join(shlex.quote(v) for v in [sys.executable]+sys.argv),"python":platform.python_version(),"numpy":np.__version__,"toolchain":reference.toolchain_version(),
        "source_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"disk_reference_sha256":hashlib.sha256(Path(disk_reference.__file__).read_bytes()).hexdigest(),"convex_reference_sha256":hashlib.sha256(Path(convex_reference.__file__).read_bytes()).hexdigest(),"position_reference_sha256":hashlib.sha256(Path(position_reference.__file__).read_bytes()).hexdigest(),"binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),
        "evidence_scope":SCOPE,"scaled_error_denominator":"max(abs(reference),1e-300)","independent_reference":"Fraction rawcross/support extrema and Decimal220 lengths/covariance, explicit deterministic vertex supports, independently rounded endpoints; old point path verifies preserved position fields; old disk and convex grouped paths independently check exact production compatibility"}
    result["numeric_reference"]=numeric_checks(binary);result["original_motion_and_checkpoint_continuations"]=real_checks(binary);result["strict_and_numerical_rejections"]=rejection_checks(binary);result["current_frame_binding"]=binding_checks(binary)
    result["warm_brown_reframe"]=reframe_checks(binary);result["bounded_transport"]=transport_checks(binary)
    if args.web:result["web_interchange"]=web_checks(binary)
    result.update(status="passed",elapsed_seconds=time.perf_counter()-started);args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open("w",encoding="utf-8",newline="\n") as f:f.write(json.dumps(result,indent=2,ensure_ascii=True)+"\n")
    print(encode({"status":"passed","numeric_cases":result["numeric_reference"]["cases"],"real_cases":result["original_motion_and_checkpoint_continuations"]["cases"],"strict_rejections":result["strict_and_numerical_rejections"]["rejected_cases"],"output":str(args.output)}))


if __name__=="__main__":main()
