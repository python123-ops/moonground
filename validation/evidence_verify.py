#!/usr/bin/env python3
"""Independent normal covariance evidence and durable gate counting checks.

Fraction.from_float retains the exact supplied binary64 coordinates/covariance.
Decimal computes distances and square roots from that rational quadratic form;
NumPy independently solves finite mean-chord intersections. No production
normal-variance factorization is used by the reference.
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

import gates_verify as gates
import projection_replace_verify as replacements
import verify as reference


ROOT = Path(__file__).resolve().parents[1]
SEED = 20261123
encode, native, run = gates.encode, gates.native, gates.execute
D = decimal.Decimal


def fraction(value):
    return Fraction.from_float(float(value))


def dec(value):
    return D(value.numerator) / D(value.denominator)


def exact_evidence(gate, point, covariance, multiplier):
    with decimal.localcontext() as context:
        context.prec = 120
        ax, ay = map(fraction, gate["start_m"])
        bx, by = map(fraction, gate["end_m"])
        px, py = map(fraction, point)
        xx, xy, yy = map(fraction, covariance)
        dx, dy = bx - ax, by - ay
        length2 = dx * dx + dy * dy
        cross = dx * (py - ay) - dy * (px - ax)
        variance = (dy * dy * xx - 2 * dx * dy * xy + dx * dx * yy) / length2
        if variance <= 0:
            raise AssertionError("oracle covariance is not positive definite along the normal")
        distance = dec(cross) / dec(length2).sqrt()
        sigma = dec(variance).sqrt()
        radius = dec(fraction(multiplier)) * sigma
        lower, upper = distance - radius, distance + radius
        band = dec(fraction(gate.get("deadband_m", 0.05)))
        side = "positive" if lower > band else "negative" if upper < -band else "unconfirmed"
        return {"distance_m": float(distance), "normal_std_m": float(sigma),
            "lower_m": float(lower), "upper_m": float(upper), "side": side}


def configuration(name="evidence-reference", multiplier=2, selected=None, quality=None):
    counting = gates.configuration(name=name, gates=selected or [gates.gate()], quality=quality)
    counting["max_tracks"] = 32
    return {"counting": encode(counting), "sigma_multiplier": multiplier}


def measured(config, timestamp, point=None, covariance=(0.01, 0, 0.01), identity=1, segment="1", status="ready", std=0.1, closed=()):
    counting = json.loads(config["counting"])
    values = []
    if point is not None:
        value = gates.track(identity, point, timestamp, segment=segment, status=status, std=std)
        if status in ("initializing", "ready", "uncertain"):
            value["position_covariance"] = list(covariance)
        values.append(value)
    return gates.measurement(timestamp, values, closed=closed, name=counting["session_id"])


def sequence(config, points, covariances=None, times=None, start=0, status="ready"):
    return [measured(config, start + stamp, point, covariance, status=status) for stamp, point, covariance in
        zip(times or [index * 100000 for index in range(len(points))], points,
            covariances or [(0.01, 0, 0.01)] * len(points))]


class Oracle:
    def __init__(self, source, canonical):
        self.config = json.loads(source["counting"])
        self.multiplier = source["sigma_multiplier"]
        self.canonical = canonical
        self.time = None
        self.counts = [[0, 0] for _ in self.config["gates"]]
        self.tracks = {}

    def checkpoint(self):
        return {"format": "moonground.gate-evidence", "checkpoint_version": "1",
            "configuration": {"counting": self.canonical, "sigma_multiplier": self.multiplier},
            "state": {"last_timestamp_us": None if self.time is None else str(self.time),
                "counts": self.count_documents(), "tracks": [copy.deepcopy(self.tracks[key]) for key in sorted(self.tracks)]}}

    def count_documents(self):
        return [{"gate_id": gate["gate_id"], "negative_to_positive": str(self.counts[index][0]),
            "positive_to_negative": str(self.counts[index][1])} for index, gate in enumerate(self.config["gates"])]

    def update(self, frame):
        timestamp, gap = int(frame["timestamp_us"]), int(self.config["max_gap_us"])
        continuous = self.time is not None and timestamp - self.time < gap
        next_tracks, evidence, crossings = {}, [], []
        for track in sorted(frame["tracks"], key=lambda value: value["track_id"]):
            if track["status"] not in ("initializing", "ready", "uncertain"):
                continue
            limit = self.config.get("max_position_std_m")
            if limit is not None and (track["position_std_m"] is None or track["position_std_m"] > limit):
                continue
            identity, segment = track["track_id"], track["segment_id"]
            previous = self.tracks.get(identity) if continuous else None
            if previous is not None and previous["segment_id"] != segment:
                previous = None
            anchors = []
            for index, gate in enumerate(self.config["gates"]):
                value = exact_evidence(gate, track["position_m"], track["position_covariance"], self.multiplier)
                evidence.append(dict(track_id=identity, segment_id=segment, gate_id=gate["gate_id"], **value))
                anchor = previous["anchors"][index] if previous is not None else None
                if anchor is not None and timestamp - int(anchor["timestamp_us"]) >= gap:
                    anchor = None
                if value["side"] == "unconfirmed":
                    anchors.append(copy.deepcopy(anchor))
                    continue
                if anchor is not None:
                    old = exact_evidence(gate, anchor["point_m"], anchor["covariance"], self.multiplier)
                    if old["side"] != value["side"]:
                        before, point = np.asarray(anchor["point_m"]), np.asarray(track["position_m"])
                        a, b = np.asarray(gate["start_m"]), np.asarray(gate["end_m"])
                        alpha, beta = np.linalg.solve(np.column_stack((point - before, a - b)), a - before)
                        if 0 <= beta <= 1:
                            positive = value["side"] == "positive"
                            self.counts[index][0 if positive else 1] += 1
                            crossings.append({"gate_id": gate["gate_id"], "track_id": identity, "segment_id": segment,
                                "direction": "negative_to_positive" if positive else "positive_to_negative",
                                "from_timestamp_us": anchor["timestamp_us"], "to_timestamp_us": str(timestamp),
                                "from_position_m": anchor["point_m"], "to_position_m": track["position_m"],
                                "position_m": (before + alpha * (point - before)).tolist(), "crossing_fraction": float(alpha)})
                anchors.append({"timestamp_us": str(timestamp), "point_m": track["position_m"],
                    "covariance": track["position_covariance"]})
            next_tracks[identity] = {"track_id": identity, "segment_id": segment, "anchors": anchors}
        self.tracks, self.time = next_tracks, timestamp
        counting = {"schema_version": "0.1.0", "kind": "gate_events", "session_id": self.config["session_id"],
            "timestamp_us": str(timestamp), "crossings": crossings, "counts": self.count_documents(), "event_scope": "filtered_ground_positions"}
        return {"schema_version": "0.1.0", "kind": "gate_evidence_frame", "counting": counting,
            "evidence": evidence, "sigma_multiplier": self.multiplier, "evidence_scope": "normal_band_on_filtered_mean_chord"}


def fixtures():
    values = []
    config = configuration()
    values.append(("band_and_covariance_confirmation", config, sequence(config, [(0, -1), (0, -.1), (0, .1), (0, 1), (0, -1)])))
    for stamp in [499999, 500000, 500001]:
        values.append(("unconfirmed_anchor_ttl_{}".format(stamp), config,
            sequence(config, [(0, -1), (0, 1), (0, 1)], [(0.01, 0, 0.01), (1, .2, 1), (0.01, 0, 0.01)], [0, 250000, stamp])))
    values.append(("finite_extension_and_endpoint", config, sequence(config, [(2, -1), (2, 1), (1, 1), (1, -1), (-1, 1)])))
    boundary = configuration("evidence-boundary", selected=[gates.gate(deadband=.25)])
    threshold = .75
    values.append(("closed_band_exact_and_adjacent_floats", boundary,
        sequence(boundary, [(0, -1), (0, float(np.nextafter(threshold, 0))), (0, threshold), (0, float(np.nextafter(threshold, 1)))], [(0.0625, 0, 0.0625)] * 4)))
    for status in ["initializing", "uncertain"]:
        values.append(("accepted_motion_" + status, config, sequence(config, [(0, -1), (0, 1)], status=status)))
    for interruption in ["missing", "rejected_projection", "rejected_innovation", "numerical_failure", "segment", "closed", "quality"]:
        selected = configuration("evidence-" + interruption, quality=.5 if interruption == "quality" else None)
        frames = [measured(selected, 0, (0, -1))]
        frames.append(measured(selected, 100000, None if interruption == "missing" else (0, 1),
            status=interruption if interruption.startswith("rejected") or interruption == "numerical_failure" else "ready",
            segment="2" if interruption in ("segment", "closed") else "1", std=.51 if interruption == "quality" else .1,
            closed=["1"] if interruption == "closed" else []))
        frames.append(measured(selected, 200000, (0, 1), segment="2" if interruption in ("segment", "closed") else "1"))
        values.append((interruption + "_clears_anchor", selected, frames))
    for start in [9007199254740993, 9223372036854775807 - 500000]:
        values.append(("exact_clock_{}".format(start), config, sequence(config, [(0, -1), (0, 1), (0, 1)],
            [(0.01, 0, 0.01), (1, .2, 1), (.01, 0, .01)], [0, 250000, 500000], start)))
    for scale in [1e-150, 1, 1e150]:
        selected = configuration("evidence-scale-{}".format(scale), selected=[gates.gate("scaled", (-scale, 0), (scale, 0), .05 * scale)])
        for sign in [-1, 1]:
            cov = [scale * scale, sign * .9 * scale * scale, scale * scale]
            values.append(("scaled_covariance_{}_{}".format(scale, sign), selected,
                sequence(selected, [(0, -3 * scale), (0, 3 * scale)], [cov, cov])))
        correlated = configuration("evidence-conditioned-{}".format(scale), selected=[
            gates.gate("diagonal", (-scale, scale), (scale, -scale), 0)])
        cov = [scale * scale, -(1 - 1e-10) * scale * scale, scale * scale]
        values.append(("supported_near_correlation_{}".format(scale), correlated,
            sequence(correlated, [(-scale, -scale), (scale, scale)], [cov, cov])))
    anisotropic = configuration("evidence-anisotropy", selected=[gates.gate("horizontal"), gates.gate("vertical", (0, -1), (0, 1))])
    values.append(("normal_not_worst_direction_sigma", anisotropic, sequence(anisotropic, [(1, -1), (-1, 1)], [(100, 0, .0001)] * 2)))
    diagonal = configuration("evidence-diagonal-extremes")
    values.append(("independent_diagonal_extreme_ratio", diagonal,
        sequence(diagonal, [(0, -1e-49), (0, 1e-49)], [(1e200, 0, 1e-100)] * 2)))
    rng = np.random.default_rng(SEED)
    for index in range(12):
        angle = rng.uniform(-np.pi, np.pi)
        tangent = np.array([np.cos(angle), np.sin(angle)])
        normal = np.array([-tangent[1], tangent[0]])
        center = rng.uniform(-3, 3, 2)
        selected = configuration("evidence-rotation-{}".format(index), selected=[gates.gate("rotated", center - tangent * 3, center + tangent * 3, .02)])
        vectors = np.column_stack((tangent, normal))
        covariance = vectors @ np.array([[.25, .03], [.03, .01]]) @ vectors.T
        packed = [float(covariance[0, 0]), float(covariance[0, 1]), float(covariance[1, 1])]
        frames = []
        for step in range(4):
            frame = measured(selected, step * 100000)
            for identity in [7, 2, 19]:
                point = center + tangent * rng.uniform(-2, 2) + normal * (1 if step % 2 else -1)
                item = gates.track(identity, point, step * 100000, segment=str(identity))
                item["position_covariance"] = packed
                frame["tracks"].append(item)
            frames.append(frame)
        values.append(("rotated_multitrack_{}".format(index), selected, frames))
    zero = configuration("evidence-zero", multiplier=0, selected=[gates.gate(), gates.gate("vertical", (0, -1), (0, 1))])
    values.append(("zero_multiplier_legacy_parity", zero, sequence(zero, [(.6, -1), (-.6, 1), (.2, 0), (.4, -1), (-.8, 1), (-.7, .01), (.5, -1), (0, 1)])))
    return values


def compare_frame(actual, expected, absolute, relative):
    ordinary = dict(actual, evidence=[])
    ordinary_expected = dict(expected, evidence=[])
    gates.tree_close(ordinary, ordinary_expected, absolute)
    assert len(actual["evidence"]) == len(expected["evidence"])
    for found, wanted in zip(actual["evidence"], expected["evidence"]):
        assert set(found) == set(wanted)
        scale = max(abs(wanted["distance_m"]), wanted["normal_std_m"], 1e-300)
        for key, value in wanted.items():
            if isinstance(value, float):
                error = abs(found[key] - value)
                denominator = abs(value) if key == "normal_std_m" else scale
                ratio = error / denominator if denominator else error
                if not math.isfinite(found[key]) or ratio > 3e-8:
                    raise AssertionError("{}: actual {}, exact {}, scaled error {}".format(key, found[key], value, ratio))
                absolute[key] = max(absolute.get(key, 0), error)
                relative[key] = max(relative.get(key, 0), ratio)
            else:
                assert found[key] == value, (key, found[key], value)


def strip_covariance(checkpoint):
    result = copy.deepcopy(checkpoint)
    for track in result["state"]["tracks"]:
        for anchor in track["anchors"]:
            if anchor is not None:
                anchor.pop("covariance")
    return result["state"]


def reference_checks(binary):
    cases, absolute, relative = [], {}, {}
    total = evidence_count = crossings = cuts = zero_frames = 0
    for name, source, frames in fixtures():
        counting = json.loads(source["counting"])
        canonical = native(binary, "--count-checkpoint", [counting], count=1)[0]["configuration"]
        oracle = Oracle(source, canonical)
        expected, snapshots = [], [oracle.checkpoint()]
        for frame in frames:
            expected.append(oracle.update(frame))
            snapshots.append(oracle.checkpoint())
        actual = native(binary, "--count-evidence", [source] + frames, count=len(frames))
        for found, wanted in zip(actual, expected):
            compare_frame(found, wanted, absolute, relative)
        for cut in range(len(frames) + 1):
            saved = native(binary, "--evidence-checkpoint", [source] + frames[:cut], count=1)[0]
            if saved != snapshots[cut]:
                raise AssertionError("{} cut {} anchor/covariance/counter checkpoint differs".format(name, cut))
            continuation = native(binary, "--count-evidence", [{"resume": saved}] + frames[cut:])
            assert continuation == actual[cut:]
            assert native(binary, "--evidence-checkpoint", [{"resume": saved}] + frames[cut:], count=1)[0] == snapshots[-1]
            cuts += 1
        if source["sigma_multiplier"] == 0:
            assert [value["counting"] for value in actual] == native(binary, "--count", [counting] + frames)
            old = native(binary, "--count-checkpoint", [counting] + frames, count=1)[0]
            assert strip_covariance(snapshots[-1]) == old["state"]
            zero_frames += len(frames)
        count = sum(len(value["counting"]["crossings"]) for value in actual)
        evidence_count += sum(len(value["evidence"]) for value in actual)
        crossings += count
        total += len(frames)
        cases.append({"name": name, "frames": len(frames), "crossings": count,
            "checkpoint_sha256": hashlib.sha256(encode(snapshots[-1]).encode()).hexdigest()})
    return {"cases": len(cases), "frames": total, "evidence_records": evidence_count, "crossings": crossings,
        "resume_cut_points": cuts, "zero_multiplier_legacy_frames": zero_frames,
        "maximum_absolute_oracle_errors": absolute, "maximum_relative_or_scaled_evidence_errors": relative,
        "reference": "exact binary64 Fraction quadratic form; Decimal120 square root; NumPy finite-chord solve",
        "full_counts_anchor_times_points_and_original_covariances_equal": True, "records": cases}


def strict_checks(binary):
    source = configuration()
    frames = sequence(source, [(0, -1), (0, 1)])
    saved = native(binary, "--evidence-checkpoint", [source, frames[0]], count=1)[0]
    prefix = native(binary, "--count-evidence", [source, frames[0]])
    cases = []

    def bad(name, records, expected=(), mode="--count-evidence", payload=None, extra=()):
        try:
            found, detail = run(binary, mode, records, status=2, payload=payload, extra=extra)
        except AssertionError as error:
            raise AssertionError(name + ": " + str(error)) from error
        if found != list(expected):
            raise AssertionError(name + ": exposed partial data/checkpoint")
        cases.append(dict(name=name, **detail))

    for name, value in [
        ("negative_multiplier", dict(source, sigma_multiplier=-1)),
        ("unknown_source_field", dict(source, extra=True)),
        ("counting_object_not_raw", dict(source, counting=json.loads(source["counting"]))),
        ("duplicate_multiplier", '{"sigma_multiplier":0,' + encode(source)[1:]),
        ("nonfinite_multiplier", encode(source).replace('"sigma_multiplier":2', '"sigma_multiplier":1e999')),
        ("fractional_raw_capacity", dict(source, counting=source["counting"].replace('"max_tracks":32', '"max_tracks":32.0000000000000001'))),
    ]:
        bad(name, [value])
    old = native(binary, "--count-checkpoint", [json.loads(source["counting"])], count=1)[0]
    assert native(binary, "--count-evidence", [{"counting": source["counting"]}] + frames) == native(binary, "--count-evidence", [source] + frames)
    bad("old_checkpoint_not_upgraded", [{"resume": old}])
    bad("old_inner_resume_not_allowed", [dict(source, counting=encode({"resume": old}))])
    for name, mutate in [
        ("wrong_format", lambda v: v.update(format="moonground.gates")),
        ("wrong_version", lambda v: v.update(checkpoint_version="2")),
        ("unknown_checkpoint_key", lambda v: v.update(extra=True)),
        ("missing_effective_multiplier", lambda v: v["configuration"].pop("sigma_multiplier")),
        ("missing_effective_maximum_gap", lambda v: v["configuration"]["counting"].pop("max_gap_us")),
        ("missing_effective_track_capacity", lambda v: v["configuration"]["counting"].pop("max_tracks")),
        ("missing_effective_deadband", lambda v: v["configuration"]["counting"]["gates"][0].pop("deadband_m")),
        ("missing_anchor_covariance", lambda v: v["state"]["tracks"][0]["anchors"][0].pop("covariance")),
        ("indefinite_anchor_covariance", lambda v: v["state"]["tracks"][0]["anchors"][0].update(covariance=[1, 2, 1])),
        ("unconfirmed_anchor_covariance", lambda v: v["state"]["tracks"][0]["anchors"][0].update(covariance=[1, 0, 1])),
        ("future_anchor", lambda v: v["state"]["tracks"][0]["anchors"][0].update(timestamp_us="1")),
        ("expired_anchor", lambda v: v["state"].update(last_timestamp_us="500000")),
        ("zero_track_id", lambda v: v["state"]["tracks"][0].update(track_id=0)),
        ("noncanonical_segment", lambda v: v["state"]["tracks"][0].update(segment_id="01")),
        ("wrong_anchor_shape", lambda v: v["state"]["tracks"][0].update(anchors=[])),
        ("negative_counter", lambda v: v["state"]["counts"][0].update(negative_to_positive="-1")),
    ]:
        invalid = copy.deepcopy(saved)
        mutate(invalid)
        bad(name, [{"resume": invalid}])
    for name, covariance in [("missing_covariance", None), ("indefinite_covariance", [1, 2, 1]),
        ("zero_variance", [1, 0, 0]), ("wrong_covariance_shape", [1, 0])]:
        invalid = copy.deepcopy(frames[1])
        invalid["tracks"][0]["position_covariance"] = covariance
        bad(name, [source, frames[0], invalid], prefix)
        if name == "missing_covariance":
            zero = dict(source, sigma_multiplier=0)
            bad("zero_multiplier_still_requires_covariance", [zero, invalid])
    for name, invalid in [
        ("same_time", frames[0]),
        ("unknown_frame_key", dict(frames[1], extra=True)),
        ("duplicate_track", dict(frames[1], tracks=frames[1]["tracks"] * 2)),
        ("duplicate_raw_track_token", encode(frames[1]).replace('"track_id":1', '"track_id":1,"track_id":1')),
        ("fractional_raw_track_token", encode(frames[1]).replace('"track_id":1', '"track_id":1.0000000000000001')),
        ("nonfinite_raw_covariance", encode(frames[1]).replace('"position_covariance":[0.01', '"position_covariance":[1e999')),
    ]:
        bad(name, [source, frames[0], invalid], prefix)
    invalid = copy.deepcopy(frames[1])
    invalid["tracks"][0]["position_covariance"] = None
    bad("late_failure_no_checkpoint", [source, frames[0], invalid], mode="--evidence-checkpoint")
    saturated = copy.deepcopy(saved)
    saturated["state"]["counts"][0]["negative_to_positive"] = "9223372036854775807"
    bad("crossing_counter_exhaustion", [{"resume": saturated}, frames[1]])
    bad("crossing_counter_exhaustion_no_checkpoint", [{"resume": saturated}, frames[1]], mode="--evidence-checkpoint")
    correction = measured(source, 100000, (0, -.5))
    corrected = native(binary, "--evidence-checkpoint", [{"resume": saturated}, correction], count=1)[0]
    assert corrected["state"]["last_timestamp_us"] == "100000"
    assert corrected["state"]["counts"] == saturated["state"]["counts"]
    large = copy.deepcopy(saved)
    large["state"]["counts"][0]["negative_to_positive"] = "9007199254740993"
    counted = native(binary, "--count-evidence", [{"resume": large}, frames[1]], count=1)[0]
    assert counted["counting"]["counts"][0]["negative_to_positive"] == "9007199254740994"
    return {"rejected_cases": len(cases), "cases": cases, "complete_prefix_preserved": True,
        "default_multiplier_equals_explicit_two": True,
        "same_proposed_timestamp_correction_from_saved_state": "passed", "exact_counter_after_increment": "9007199254740994"}


def zero_multiplier_checks(binary):
    total = events = 0
    values = fixtures()
    for name, original, frames in values:
        source = dict(original, sigma_multiplier=0)
        counting = json.loads(source["counting"])
        actual = native(binary, "--count-evidence", [source] + frames)
        expected = native(binary, "--count", [counting] + frames)
        assert [value["counting"] for value in actual] == expected, name
        evidence_cp = native(binary, "--evidence-checkpoint", [source] + frames, count=1)[0]
        old_cp = native(binary, "--count-checkpoint", [counting] + frames, count=1)[0]
        assert strip_covariance(evidence_cp) == old_cp["state"], name
        total += len(frames)
        events += sum(len(frame["crossings"]) for frame in expected)
    return {"cases": len(values), "frames": total, "crossings": events,
        "all_existing_counting_reports_and_anchor_states_equal_on_supported_covariance_domain": True}


def pipeline_checks(binary):
    header, _, frames = replacements.fixture(name="evidence-guarded")
    guarded = native(binary, "--guarded", [header] + frames)
    analysis = json.loads(header["analysis"])
    source = {"counting": analysis["counting"], "sigma_multiplier": 2}
    measurements = [value["analysis"]["measurement"] for value in guarded]
    canonical = native(binary, "--count-checkpoint", [json.loads(source["counting"])], count=1)[0]["configuration"]
    oracle = Oracle(source, canonical)
    expected = [oracle.update(value) for value in measurements]
    actual = native(binary, "--count-evidence", [source] + measurements)
    absolute, relative = {}, {}
    for found, wanted in zip(actual, expected):
        compare_frame(found, wanted, absolute, relative)
    for cut in range(len(measurements) + 1):
        saved = native(binary, "--evidence-checkpoint", [source] + measurements[:cut], count=1)[0]
        if cut and guarded[cut - 1]["decision"] == "blocked":
            assert saved["state"]["tracks"] == []
    return {"status": "passed", "unmodified_guarded_measurement_frames": len(measurements),
        "projection_barriers": sum(v["kind"] == "guarded_projection_replaced" for v in guarded),
        "blocked_frames_clear_all_evidence_anchors": True, "maximum_absolute_oracle_errors": absolute,
        "maximum_relative_or_scaled_evidence_errors": relative}


def numerical_domain_checks(binary):
    """Unsupported arithmetic must fail atomically, rather than reduce sigma."""
    cases = []
    for scale in [1e-300, 1, 1e300]:
        root = math.sqrt(scale)
        source = configuration("evidence-unsupported-{}".format(scale), selected=[
            gates.gate("diagonal", (-root, root), (root, -root), 0)])
        covariance = [scale, float(np.nextafter(-scale, 0)), scale]
        cases.append(("near_singular_correlation_{}".format(scale), source,
            measured(source, 1, (root, root), covariance)))
    floor_source = configuration("evidence-correlation-floor", selected=[gates.gate("diagonal", (-1, 1), (1, -1), 0)])
    cases.append(("correlation_precision_floor", floor_source,
        measured(floor_source, 1, (1, 1), [1, -(1 - 32 * np.finfo(float).eps), 1])))
    residual_source = configuration("evidence-residual-floor")
    cases.append(("normalized_correlated_residual_floor", residual_source,
        measured(residual_source, 1, (0, 1e-154), [1, 1e-156, 1e-310])))
    for name, multiplier, point, covariance in [
        ("radius_underflow", 5e-324, (0, 1e-149), (1e-300, 0, 1e-300)),
        ("radius_overflow", 1e308, (0, 1), (100, 0, 100)),
        ("coalesced_interval", 2, (0, 1e200), (1, 0, 1)),
        ("interval_bound_overflow", 1e154, (0, -1.7e308), (1e308, 0, 1e308)),
    ]:
        source = configuration("evidence-" + name, multiplier=multiplier)
        cases.append((name, source, measured(source, 1, point, covariance)))
    records = []
    for name, source, invalid in cases:
        empty = measured(source, 0)
        prefix = native(binary, "--count-evidence", [source, empty], count=1)
        found, detail = run(binary, "--count-evidence", [source, empty, invalid], status=2)
        assert found == prefix
        assert run(binary, "--evidence-checkpoint", [source, empty, invalid], status=2, count=0)[0] == []
        saved = native(binary, "--evidence-checkpoint", [source, empty], count=1)[0]
        corrected = native(binary, "--evidence-checkpoint", [{"resume": saved}, measured(source, 1)], count=1)[0]
        assert corrected["state"]["last_timestamp_us"] == "1"
        records.append(dict(name=name, **detail))
    return {"rejected_cases": len(records), "cases": records,
        "near_singular_covariances_are_explicitly_outside_supported_domain": True,
        "no_prefix_or_checkpoint_on_failing_frame": True,
        "same_proposed_timestamp_empty_correction_from_saved_state": "passed"}


def capacity_checks(binary):
    source = configuration("evidence-capacity", selected=[gates.gate(str(index)) for index in range(16)])
    first = measured(source, 0)
    first["tracks"] = [gates.track(index, (0, -1), 0, segment=str(index)) for index in range(1, 33)]
    reports = native(binary, "--count-evidence", [source, first], count=1)
    saved = native(binary, "--evidence-checkpoint", [source, first], count=1)[0]
    assert len(reports[0]["evidence"]) == 512
    assert sum(anchor is not None for track in saved["state"]["tracks"] for anchor in track["anchors"]) == 512
    assert native(binary, "--evidence-checkpoint", [{"resume": saved}], count=1)[0] == saved
    later = copy.deepcopy(first)
    later["timestamp_us"] = "1"
    for item in later["tracks"]:
        item["position_m"] = [0, 1]
        item["last_accepted_timestamp_us"] = "1"
    crossings = native(binary, "--count-evidence", [{"resume": saved}, later], count=1)[0]
    assert len(crossings["counting"]["crossings"]) == 512
    assert all(value["negative_to_positive"] == "32" and value["positive_to_negative"] == "0"
        for value in crossings["counting"]["counts"])
    overflow = copy.deepcopy(later)
    overflow["tracks"].append(gates.track(33, (0, 1), 1, segment="33"))
    found, detail = run(binary, "--count-evidence", [source, first, overflow], status=2)
    assert found == reports
    run(binary, "--evidence-checkpoint", [source, first, overflow], status=2, count=0)
    counting = json.loads(source["counting"])
    counting["max_tracks"] = 4096
    boundary = dict(source, counting=encode(counting))
    empty = native(binary, "--evidence-checkpoint", [boundary], count=1)[0]
    assert empty["state"]["tracks"] == []
    counting["max_tracks"] = 4097
    _, budget = run(binary, "--evidence-checkpoint", [dict(source, counting=encode(counting))], status=2, count=0)
    return {"actual_populated_tracks": 32, "actual_populated_anchors": 512,
        "actual_simultaneous_crossings": 512, "populated_checkpoint_utf16_units": len(encode(saved)),
        "configured_track_capacity_overflow": detail, "empty_constructor_anchor_capacity": 65536,
        "constructor_one_over_anchor_capacity": budget, "global_maximum_capacity_was_not_populated": True}


def transport_checks(binary):
    source = configuration()
    frames = sequence(source, [(0, -1), (0, 1)])
    expected = native(binary, "--count-evidence", [source] + frames)
    for ending in [b"\n", b"\r\n"]:
        assert run(binary, "--count-evidence", payload=ending.join(encode(v).encode() for v in [source] + frames))[0] == expected
    padded = encode(frames[0]).ljust(1048576)
    assert native(binary, "--count-evidence", [source, padded]) == expected[:1]
    _, failure = run(binary, "--count-evidence", [source, padded + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    saved = native(binary, "--evidence-checkpoint", [source], count=1)[0]
    exact_source = encode({"resume": saved}).ljust(8388619)
    assert native(binary, "--evidence-checkpoint", [exact_source], count=1, extra=["--max-line-bytes", "16777216"])[0] == saved
    _, overflow = run(binary, "--evidence-checkpoint", [exact_source + " "], status=2, count=0, extra=["--max-line-bytes", "16777216"])
    return {"crlf_and_unterminated_eof": "passed", "exact_frame_utf16_units": 1048576,
        "frame_overflow": failure, "exact_resume_source_utf16_units": 8388619, "source_overflow": overflow}


def web_checks(binary):
    command = ["node", "--test", "--test-reporter=tap", "web/evidence.test.mjs"]
    completed = subprocess.run(command, cwd=str(ROOT), env=dict(os.environ, MOONGROUND_CLI=str(binary)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=300)
    if completed.returncode:
        raise AssertionError("Node evidence verification failed:\n" + completed.stdout[-18000:] + completed.stderr[-2000:])
    summary, directions = {}, None
    for value in completed.stdout.splitlines():
        match = re.match(r"# (tests|pass|fail|cancelled|skipped|todo) (\d+)$", value)
        if match:
            summary[match.group(1)] = int(match.group(2))
        if value.startswith('# {"cut_points":'):
            directions = json.loads(value[2:])
    assert summary.get("tests") and summary.get("pass") == summary["tests"] and not summary.get("fail") and directions is not None
    return {"status": "passed", "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "command": " ".join(command), "summary": summary, "cross_runtime": directions,
        "test_script_sha256": hashlib.sha256((ROOT / "web/evidence.test.mjs").read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((ROOT / "_build/site/moonground.mjs").read_bytes()).hexdigest(),
        "stdout_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(), "stderr": completed.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/evidence-results.json")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("native binary does not exist")
    started = time.perf_counter()
    result = {"format_version": "1", "fixtures": "deterministic", "seed": SEED,
        "command": " ".join(shlex.quote(v) for v in [sys.executable] + sys.argv),
        "python": platform.python_version(), "numpy": np.__version__, "toolchain": reference.toolchain_version(),
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "gate_reference_sha256": hashlib.sha256(Path(gates.__file__).read_bytes()).hexdigest(),
        "projection_fixture_sha256": hashlib.sha256(Path(replacements.__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["independent_reference"] = reference_checks(binary)
    result["strict_transport"] = strict_checks(binary)
    result["zero_multiplier_legacy_comparison"] = zero_multiplier_checks(binary)
    result["numerical_supported_domain"] = numerical_domain_checks(binary)
    result["bounded_state"] = capacity_checks(binary)
    result["guarded_pipeline"] = pipeline_checks(binary)
    result["bounded_transport"] = transport_checks(binary)
    if args.web:
        result["web_interchange"] = web_checks(binary)
    result["elapsed_seconds"] = time.perf_counter() - started
    result["status"] = "passed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    print(encode({"status": "passed", "output": str(args.output), "cases": result["independent_reference"]["cases"],
        "frames": result["independent_reference"]["frames"], "resume_cut_points": result["independent_reference"]["resume_cut_points"],
        "strict_rejections": result["strict_transport"]["rejected_cases"]}))


if __name__ == "__main__":
    main()
