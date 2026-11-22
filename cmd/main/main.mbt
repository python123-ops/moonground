///|
extern "C" fn exit_process(code : Int32) = "exit"

///|
async fn diagnostic(message : String) -> Unit {
  @stdio.stderr.write(message + "\n")
  exit_process(2)
}

///|
fn reframe_line(
  state : Ref[@codec.ReplayReframer?],
  source : String,
) -> String raise @types.GroundError {
  match state.val {
    None => {
      let converter = @codec.ReplayReframer::new(source)
      let header = converter.header_line()
      state.val = Some(converter)
      header
    }
    Some(converter) => converter.process_line(source)
  }
}

///|
fn count_line(
  state : Ref[@codec.GateReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.GateReplay::open(source))
      None
    }
    Some(counter) => Some(counter.process_line(source))
  }
}

///|
fn analysis_line(
  state : Ref[@codec.AnalysisReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.AnalysisReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn health_line(
  state : Ref[@codec.HealthReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.HealthReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn guarded_line(
  state : Ref[@codec.GuardedReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.GuardedReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn transit_line(
  state : Ref[@codec.TransitReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.TransitReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn evidence_line(
  state : Ref[@codec.EvidenceGateReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.EvidenceGateReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn evidence_analysis_line(
  state : Ref[@codec.EvidenceAnalysisReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.EvidenceAnalysisReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn evidence_guarded_line(
  state : Ref[@codec.EvidenceGuardedReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.EvidenceGuardedReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn footprint_run_window_guarded_line(
  state : Ref[@codec.FootprintRunWindowGuardedReplay?],
  source : String,
  preview : Bool,
  preview_seen : Ref[Bool],
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.FootprintRunWindowGuardedReplay::open(source))
      None
    }
    Some(replay) =>
      if preview {
        if preview_seen.val {
          raise @types.InvalidInput(
            "guarded footprint run window preview accepts exactly one observation frame",
          )
        }
        let output = replay.preview_line(source)
        preview_seen.val = true
        Some(output)
      } else {
        Some(replay.process_line(source))
      }
  }
}

///|
fn footprint_run_guarded_line(
  state : Ref[@codec.FootprintRunGuardedReplay?],
  source : String,
  preview : Bool,
  preview_seen : Ref[Bool],
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.FootprintRunGuardedReplay::open(source))
      None
    }
    Some(replay) =>
      if preview {
        if preview_seen.val {
          raise @types.InvalidInput(
            "guarded footprint run preview accepts exactly one observation frame",
          )
        }
        let output = replay.preview_line(source)
        preview_seen.val = true
        Some(output)
      } else {
        Some(replay.process_line(source))
      }
  }
}

///|
fn footprint_run_window_analysis_line(
  state : Ref[@codec.FootprintRunWindowAnalysisReplay?],
  source : String,
  preview : Bool,
  preview_seen : Ref[Bool],
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.FootprintRunWindowAnalysisReplay::open(source))
      None
    }
    Some(replay) =>
      if preview {
        if preview_seen.val {
          raise @types.InvalidInput(
            "footprint run window preview accepts exactly one observation frame",
          )
        }
        let output = replay.preview_line(source)
        preview_seen.val = true
        Some(output)
      } else {
        Some(replay.process_line(source))
      }
  }
}

///|
fn footprint_run_analysis_line(
  state : Ref[@codec.FootprintRunAnalysisReplay?],
  source : String,
  preview : Bool,
  preview_seen : Ref[Bool],
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.FootprintRunAnalysisReplay::open(source))
      None
    }
    Some(replay) =>
      if preview {
        if preview_seen.val {
          raise @types.InvalidInput(
            "footprint run preview accepts exactly one observation frame",
          )
        }
        let output = replay.preview_line(source)
        preview_seen.val = true
        Some(output)
      } else {
        Some(replay.process_line(source))
      }
  }
}

///|
fn footprint_run_windows_line(
  state : Ref[@codec.FootprintRunWindowReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.FootprintRunWindowReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn footprint_runs_line(
  state : Ref[@codec.FootprintRunReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.FootprintRunReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn assigned_zone_evidence_line(
  state : Ref[@codec.AssignedZoneEvidenceReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.AssignedZoneEvidenceReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn footprint_zone_evidence_line(
  state : Ref[@codec.FootprintZoneEvidenceReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.FootprintZoneEvidenceReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn disk_zone_evidence_line(
  state : Ref[@codec.DiskZoneEvidenceReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.DiskZoneEvidenceReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn zone_intersection_line(
  state : Ref[@codec.ZoneIntersectionReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.ZoneIntersectionReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn zone_evidence_line(
  state : Ref[@codec.ZoneEvidenceReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.ZoneEvidenceReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn velocity_evidence_line(
  state : Ref[@codec.VelocityEvidenceReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.VelocityEvidenceReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn guarded_transit_windows_line(
  state : Ref[@codec.EvidenceGuardedTransitWindowReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.EvidenceGuardedTransitWindowReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn transit_window_analysis_line(
  state : Ref[@codec.EvidenceTransitWindowAnalysisReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.EvidenceTransitWindowAnalysisReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn transit_windows_line(
  state : Ref[@codec.EvidenceTransitWindowReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.EvidenceTransitWindowReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn evidence_guarded_transit_line(
  state : Ref[@codec.EvidenceGuardedTransitReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.EvidenceGuardedTransitReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn evidence_transit_line(
  state : Ref[@codec.EvidenceTransitReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.EvidenceTransitReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn evidence_transit_analysis_line(
  state : Ref[@codec.EvidenceTransitAnalysisReplay?],
  source : String,
) -> String? raise @types.GroundError {
  match state.val {
    None => {
      state.val = Some(@codec.EvidenceTransitAnalysisReplay::open(source))
      None
    }
    Some(replay) => Some(replay.process_line(source))
  }
}

///|
fn evaluation_line(
  state : Ref[@codec.MeasurementEvaluationReplay?],
  source : String,
) -> Unit raise @types.GroundError {
  match state.val {
    None => state.val = Some(@codec.MeasurementEvaluationReplay::open(source))
    Some(replay) => replay.process_line(source)
  }
}

///|
async fn main {
  let args = @env.args()
  if args.length() == 2 && args[1] == "--version" {
    @stdio.stdout.write("moonground " + cli_version() + "\n")
    return
  }
  if args.length() == 2 && args[1] == "--version-json" {
    @stdio.stdout.write(cli_version_json() + "\n")
    return
  }
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    @stdio.stdout.write(
      "moonground --version | --version-json | (--evaluate-measurements | --stream | --checkpoint | --reframe | --count | --count-checkpoint | --analyze | --analyze-checkpoint | --health | --health-checkpoint | --guarded | --guarded-checkpoint | --transit | --transit-checkpoint | --count-evidence | --evidence-checkpoint | --analyze-evidence | --analyze-evidence-checkpoint | --guarded-evidence | --guarded-evidence-checkpoint | --transit-evidence | --transit-evidence-checkpoint | --analyze-transit-evidence | --analyze-transit-evidence-checkpoint | --guarded-transit-evidence | --guarded-transit-evidence-checkpoint | --transit-windows | --transit-windows-checkpoint | --analyze-transit-windows | --analyze-transit-windows-checkpoint | --guarded-transit-windows | --guarded-transit-windows-checkpoint | --velocity-evidence | --zone-evidence | --zone-intersection | --disk-zone-evidence | --footprint-zone-evidence | --assigned-zone-evidence | --footprint-runs | --footprint-runs-checkpoint | --analyze-footprint-runs | --analyze-footprint-runs-checkpoint | --preview-footprint-run | --guarded-footprint-runs | --guarded-footprint-runs-checkpoint | --preview-guarded-footprint-run | --footprint-run-windows | --footprint-run-windows-checkpoint | --analyze-footprint-run-windows | --analyze-footprint-run-windows-checkpoint | --preview-footprint-run-window | --guarded-footprint-run-windows | --guarded-footprint-run-windows-checkpoint | --preview-guarded-footprint-run-window) [--max-line-bytes N] | --project | --calibrate | --calibration-sensitivity | --calibration-distance | --calibration-angle | --calibration-area\n--evaluate-measurements reads an evaluation configuration, then aligned {measurement,reference} lines; it writes one final accuracy and coverage summary at EOF.\n--calibration-line-offset reads {calibration,modes,comparisons:[{probe_id,line_start,line_end,first_pixel,second_pixel}]} and compares signed offsets against the common directed infinite line, including movement of its anchors. --calibration-area reads one strict shared-parameter convex polygon comparison request (3..64 vertices, at most 64 comparisons). It returns positive ground areas, signed winding, shared cross contributions and first-minus-second differences in square metres and first/second ratios. Contributions are first order only; polygons must be strictly convex in both pixel and represented ground coordinates.\n--calibration-angle reads one strict shared-parameter direction comparison request; its signed second-relative-to-first angle and local tangent contributions use radians. --calibration-distance reads exactly one strict JSON request with calibration, modes and comparisons of two already-undistorted pixel segments. It computes Euclidean distances and shared first-order contributions to their cross covariance, first-minus-second difference and first/second ratio. Zero represented segment length is rejected; observation noise and higher-order effects are excluded.\n--calibration-sensitivity reads exactly one strict JSON request with calibration, modes and already-undistorted pixel-pair probes. Modes use calibration.matrix() normalized coefficients. It returns first-order shared-parameter contributions, cross blocks and relative displacement contributions; no measurement covariance, camera correction or state is inferred.\nStream/checkpoint read configuration or {resume: checkpoint}, then frames. --checkpoint writes only the final state at EOF. --reframe reads {source: configuration_or_resume, transform: {...}}, then original frames, and writes transformed NDJSON. --count reads gate configuration or {resume: gate_checkpoint}, then schema-0.2 measurement frames; --count-checkpoint writes only final gate state at EOF. --analyze reads {measurement: raw_session_source, counting: raw_gate_source} or {resume: analysis_checkpoint}, then original observations. --analyze-checkpoint writes only final joint state. --health reads fixed-landmark calibration configuration or {resume: health_checkpoint}, then landmark observation frames; --health-checkpoint writes only final health state. --guarded reads {analysis: raw_analysis_source, health: raw_health_source} or {resume: guarded_checkpoint}, then {measurement: raw_pixel_frame, health: raw_landmark_frame}. --guarded also accepts {replace_projection: raw_replacement_JSON}; its timestamp_us, calibration and explicit camera (object or null) create a blocked barrier and require new health evidence. --guarded-checkpoint writes only final bound state. --transit reads {counting: raw_gate_source, sections: [...], max_duration_us: optional_string} or {resume: transit_checkpoint}, then schema-0.2 measurement frames. --transit-checkpoint writes only final downstream state; upstream motion must be restored separately. --count-evidence reads {counting: raw_fresh_gate_configuration, sigma_multiplier: optional_number} or {resume: evidence_checkpoint}, then schema-0.2 measurements. --evidence-checkpoint writes only final covariance-evidence state. --analyze-evidence reads {measurement: raw_session_source, counting: raw_evidence_source} or {resume: evidence_analysis_checkpoint}, then original observations. --analyze-evidence-checkpoint writes only the final complete atomic measurement and covariance-evidence state. --guarded-evidence reads {analysis: raw_evidence_analysis_source, health: raw_health_source} or {resume: evidence_guarded_checkpoint}, then the same paired raw observation or replace_projection lines as --guarded. --guarded-evidence-checkpoint writes only the final complete health, motion and evidence state. --transit-evidence reads {counting: raw_evidence_source, sections: [...], max_duration_us: optional_string} or {resume: evidence_transit_checkpoint}, then original schema-0.2 measurement frames. --transit-evidence-checkpoint writes only the final complete downstream evidence and passage state; restore the upstream clock separately. --analyze-transit-evidence reads {measurement: raw_session_source, transit: raw_evidence_transit_source} or {resume: evidence_transit_analysis_checkpoint}, then raw pixel or ground observations. --analyze-transit-evidence-checkpoint writes only the complete joint measurement and evidence-transit state. --guarded-transit-evidence reads {analysis: raw_evidence_transit_analysis_source, health: raw_health_source} or {resume: evidence_guarded_transit_checkpoint}, then paired raw pixel and landmark observation or replace_projection lines. --guarded-transit-evidence-checkpoint writes the complete health, motion, evidence and transit state. --transit-windows reads {transit: raw_evidence_transit_source, window_us: decimal_string, duration_limits_us: [decimal_string], origin_us: optional_decimal_string} or {resume: windows_checkpoint}, then original evidence_transit_frame results. --transit-windows-checkpoint writes only the downstream statistics state; restore the upstream clock separately. --analyze-transit-windows reads {analysis: raw_evidence_transit_analysis_source, windows: raw_window_options_or_resume} or {resume: complete_window_analysis_checkpoint}, then raw pixel or ground observations. --analyze-transit-windows-checkpoint writes the complete joint measurement, transit and window state. --guarded-transit-windows reads {guarded: raw_evidence_guarded_transit_source, windows: raw_window_options_or_resume} or {resume: complete_guarded_transit_windows_checkpoint}, then paired raw observations or original replace_projection control lines. --guarded-transit-windows-checkpoint writes the complete health, measurement, transit and window state. --velocity-evidence reads {session_id, probes: [{probe_id, direction: [dx,dy], threshold_mps, sigma_multiplier?: number}], max_tracks?: integer}, then original schema-0.2 measurement frames. Each frame is independent; only current Ready velocities produce threshold evidence. No checkpoint or event counters. --zone-intersection reads the original zone configuration and schema-0.2 measurements. It bounds the minimum inverse-covariance quadratic over each closed convex zone; disjoint and intersects are certified closed-set relations, while uncertain numerical comparisons remain indeterminate. It has no clock, checkpoint or events. --zone-evidence reads {session_id, zones: [{zone_id, vertices_m: [[x,y],...], sigma_multiplier?: number}], max_tracks?: integer}, then schema-0.2 measurements. Only current Ready positions produce independent convex-zone halfplane evidence. No checkpoint or region events. --disk-zone-evidence reads {position: raw_v22_zone_configuration_string, disk: raw_disk_options_string}, where disk options are {radius_m: nonnegative_finite_number}; then original schema-0.2 measurements. The explicit disk is centered on each modeled ground anchor; statistical position bounds stay separate from physical support. No footprint estimation or checkpoints. --footprint-zone-evidence reads {position: raw_v22_zone_configuration_string, footprint: raw_convex_options_string}, where options contain vertices_offset_m: [[x,y],...] in ground axes relative to the modeled anchor. The 3..32 strictly convex vertices must enclose that anchor (closed boundary allowed). Original position, signed shape support and combined bounds remain separate. No automatic heading, sizing or checkpoint. --assigned-zone-evidence reads the original zone configuration, then {measurement: raw_schema02_frame_string, assignments: raw_assignment_document_string}. Assignments contain timestamp_us and footprints: [{track_id, segment_id, shape: {kind: disk, radius_m} or {kind: convex, vertices_offset_m}}]. Exact current clock and reported target segment must match. Ready without assignment is missing_footprint; no shape map or checkpoint is retained. --footprint-runs reads {position: raw_zone_configuration, options: raw_run_options} or {resume: footprint_run_checkpoint}, then the same wrapped measurement and assignment frames. Options max_gap_us, confirmation_us and min_samples are canonical Int64 strings. Reports same-shape Inside/Outside sample runs; sample span is not continuous occupancy or physical dwell. --footprint-runs-checkpoint writes only complete downstream state; upstream motion is restored separately. --analyze-footprint-runs reads {measurement: raw_measurement_source, runs: raw_run_source} or {resume: complete_joint_checkpoint}, then {measurement: raw_original_observation_frame, assignments: raw_exact_assignment_document}. It commits motion and footprint sample runs together after all checks; --analyze-footprint-runs-checkpoint writes only the final complete joint state. --preview-footprint-run reads the same source and exactly one raw original observation frame, returning actual candidate measurement identities without committing. Preview is not a reservation; assignments must still match the actual commit candidate. --guarded-footprint-runs reads {analysis: raw_v27_source, health: raw_health_source} or {resume: complete_joint_checkpoint}, then {measurement: raw_pixel_frame, health: raw_landmark_frame, assignments: raw_exact_assignment_document}, or original replace_projection controls. Only Healthy permits motion; Blocked closes all active segments and requires an exact-time empty assignment bundle. --guarded-footprint-runs-checkpoint writes only the final complete health, motion and footprint run checkpoint. --preview-guarded-footprint-run reads the same source and exactly one paired {measurement,health} frame without assignments; it returns actual decision, health, candidate measurement and suppressed IDs without committing. --footprint-run-windows reads {runs: raw_v26_run_source, window: raw_window_options} or {resume: complete_window_checkpoint}, then the original schema-0.2 measurement and explicit assignment wrappers. Window options require positive canonical window_us and optional origin_us strings. It owns the original run monitor and counts actual new confirmations and confirmed/unconfirmed endings by their report timestamp; old confirmed runs are not recounted at a window boundary or started baseline. It returns the current and last observed closed window plus unobserved_windows without inventing zero buckets or physical occupancy. --footprint-run-windows-checkpoint writes only the complete original monitor and bounded statistics at EOF. --analyze-footprint-run-windows reads {analysis: raw_v27_source, window: raw_window_options} or {resume: complete_window_analysis_checkpoint}, then original observation and exact assignment wrappers. It commits measurement, visual sample runs and outcome windows together; --analyze-footprint-run-windows-checkpoint writes their complete final checkpoint, preserving the current window and its original baseline. --preview-footprint-run-window accepts the same source and exactly one original observation frame without assignments, returning the actual uncommitted measurement and segment identities. --guarded-footprint-run-windows reads {guarded: raw_v28_source, window: raw_window_options} or {resume: complete_guarded_window_checkpoint}, then original paired pixel/landmark/assignment wrappers or original replace_projection controls. Health, measurement, footprint runs and windows commit together; Blocked and replacement barriers close every active segment and count one actual statistics input, preserving completed bucket counts and next segment identity. --guarded-footprint-run-windows-checkpoint writes only the complete final state. --preview-guarded-footprint-run-window accepts exactly one original paired {measurement,health} frame without assignments and returns the actual guarded preview without committing.\n",
    )
    return
  }
  if args.length() < 2 ||
    (
      args[1] != "--stream" &&
      args[1] != "--evaluate-measurements" &&
      args[1] != "--checkpoint" &&
      args[1] != "--reframe" &&
      args[1] != "--count" &&
      args[1] != "--count-checkpoint" &&
      args[1] != "--analyze" &&
      args[1] != "--analyze-checkpoint" &&
      args[1] != "--health" &&
      args[1] != "--health-checkpoint" &&
      args[1] != "--guarded" &&
      args[1] != "--guarded-checkpoint" &&
      args[1] != "--transit" &&
      args[1] != "--transit-checkpoint" &&
      args[1] != "--count-evidence" &&
      args[1] != "--evidence-checkpoint" &&
      args[1] != "--analyze-evidence" &&
      args[1] != "--analyze-evidence-checkpoint" &&
      args[1] != "--guarded-evidence" &&
      args[1] != "--guarded-evidence-checkpoint" &&
      args[1] != "--transit-evidence" &&
      args[1] != "--transit-evidence-checkpoint" &&
      args[1] != "--analyze-transit-evidence" &&
      args[1] != "--analyze-transit-evidence-checkpoint" &&
      args[1] != "--guarded-transit-evidence" &&
      args[1] != "--guarded-transit-evidence-checkpoint" &&
      args[1] != "--transit-windows" &&
      args[1] != "--transit-windows-checkpoint" &&
      args[1] != "--analyze-transit-windows" &&
      args[1] != "--analyze-transit-windows-checkpoint" &&
      args[1] != "--guarded-transit-windows" &&
      args[1] != "--guarded-transit-windows-checkpoint" &&
      args[1] != "--velocity-evidence" &&
      args[1] != "--zone-evidence" &&
      args[1] != "--zone-intersection" &&
      args[1] != "--disk-zone-evidence" &&
      args[1] != "--footprint-zone-evidence" &&
      args[1] != "--assigned-zone-evidence" &&
      args[1] != "--footprint-run-windows" &&
      args[1] != "--footprint-run-windows-checkpoint" &&
      args[1] != "--footprint-runs" &&
      args[1] != "--footprint-runs-checkpoint" &&
      args[1] != "--analyze-footprint-run-windows" &&
      args[1] != "--analyze-footprint-run-windows-checkpoint" &&
      args[1] != "--preview-footprint-run-window" &&
      args[1] != "--analyze-footprint-runs" &&
      args[1] != "--analyze-footprint-runs-checkpoint" &&
      args[1] != "--preview-footprint-run" &&
      args[1] != "--guarded-footprint-run-windows" &&
      args[1] != "--guarded-footprint-run-windows-checkpoint" &&
      args[1] != "--preview-guarded-footprint-run-window" &&
      args[1] != "--guarded-footprint-runs" &&
      args[1] != "--guarded-footprint-runs-checkpoint" &&
      args[1] != "--preview-guarded-footprint-run" &&
      args[1] != "--calibration-angle" &&
      args[1] != "--calibration-area" &&
      args[1] != "--calibration-line-offset" &&
      args[1] != "--calibration-distance" &&
      args[1] != "--calibration-sensitivity" &&
      args[1] != "--project" &&
      args[1] != "--calibrate"
    ) {
    diagnostic(
      "usage: moonground --version | --version-json | (--evaluate-measurements | --stream | --checkpoint | --reframe | --count | --count-checkpoint | --analyze | --analyze-checkpoint | --health | --health-checkpoint | --guarded | --guarded-checkpoint | --transit | --transit-checkpoint | --count-evidence | --evidence-checkpoint | --analyze-evidence | --analyze-evidence-checkpoint | --guarded-evidence | --guarded-evidence-checkpoint | --transit-evidence | --transit-evidence-checkpoint | --analyze-transit-evidence | --analyze-transit-evidence-checkpoint | --guarded-transit-evidence | --guarded-transit-evidence-checkpoint | --transit-windows | --transit-windows-checkpoint | --analyze-transit-windows | --analyze-transit-windows-checkpoint | --guarded-transit-windows | --guarded-transit-windows-checkpoint | --velocity-evidence | --zone-evidence | --zone-intersection | --disk-zone-evidence | --footprint-zone-evidence | --assigned-zone-evidence | --footprint-runs | --footprint-runs-checkpoint | --analyze-footprint-runs | --analyze-footprint-runs-checkpoint | --preview-footprint-run | --guarded-footprint-runs | --guarded-footprint-runs-checkpoint | --preview-guarded-footprint-run | --footprint-run-windows | --footprint-run-windows-checkpoint | --analyze-footprint-run-windows | --analyze-footprint-run-windows-checkpoint | --preview-footprint-run-window | --guarded-footprint-run-windows | --guarded-footprint-run-windows-checkpoint | --preview-guarded-footprint-run-window) [--max-line-bytes N] | --project | --calibrate | --calibration-sensitivity | --calibration-distance | --calibration-angle | --calibration-area | --calibration-line-offset",
    )
    return
  }
  let mut max_bytes = 1048576
  let evaluation_mode = args[1] == "--evaluate-measurements"
  let count_mode = args[1] == "--count" || args[1] == "--count-checkpoint"
  let analysis_mode = args[1] == "--analyze" ||
    args[1] == "--analyze-checkpoint"
  let health_mode = args[1] == "--health" || args[1] == "--health-checkpoint"
  let footprint_run_window_guarded_mode = args[1] ==
    "--guarded-footprint-run-windows" ||
    args[1] == "--guarded-footprint-run-windows-checkpoint" ||
    args[1] == "--preview-guarded-footprint-run-window"
  let footprint_run_guarded_mode = args[1] == "--guarded-footprint-runs" ||
    args[1] == "--guarded-footprint-runs-checkpoint" ||
    args[1] == "--preview-guarded-footprint-run"
  let footprint_run_window_analysis_mode = args[1] ==
    "--analyze-footprint-run-windows" ||
    args[1] == "--analyze-footprint-run-windows-checkpoint" ||
    args[1] == "--preview-footprint-run-window"
  let footprint_run_analysis_mode = args[1] == "--analyze-footprint-runs" ||
    args[1] == "--analyze-footprint-runs-checkpoint" ||
    args[1] == "--preview-footprint-run"
  let footprint_run_windows_mode = args[1] == "--footprint-run-windows" ||
    args[1] == "--footprint-run-windows-checkpoint"
  let footprint_runs_mode = args[1] == "--footprint-runs" ||
    args[1] == "--footprint-runs-checkpoint"
  let assigned_zone_evidence_mode = args[1] == "--assigned-zone-evidence"
  let footprint_zone_evidence_mode = args[1] == "--footprint-zone-evidence"
  let disk_zone_evidence_mode = args[1] == "--disk-zone-evidence"
  let zone_evidence_mode = args[1] == "--zone-evidence"
  let zone_intersection_mode = args[1] == "--zone-intersection"
  let velocity_evidence_mode = args[1] == "--velocity-evidence"
  let guarded_transit_windows_mode = args[1] == "--guarded-transit-windows" ||
    args[1] == "--guarded-transit-windows-checkpoint"
  let transit_window_analysis_mode = args[1] == "--analyze-transit-windows" ||
    args[1] == "--analyze-transit-windows-checkpoint"
  let transit_windows_mode = args[1] == "--transit-windows" ||
    args[1] == "--transit-windows-checkpoint"
  let evidence_guarded_transit_mode = args[1] == "--guarded-transit-evidence" ||
    args[1] == "--guarded-transit-evidence-checkpoint"
  let evidence_transit_analysis_mode = args[1] == "--analyze-transit-evidence" ||
    args[1] == "--analyze-transit-evidence-checkpoint"
  let evidence_transit_mode = args[1] == "--transit-evidence" ||
    args[1] == "--transit-evidence-checkpoint"
  let evidence_guarded_mode = args[1] == "--guarded-evidence" ||
    args[1] == "--guarded-evidence-checkpoint"
  let evidence_analysis_mode = args[1] == "--analyze-evidence" ||
    args[1] == "--analyze-evidence-checkpoint"
  let evidence_mode = args[1] == "--count-evidence" ||
    args[1] == "--evidence-checkpoint"
  let transit_mode = args[1] == "--transit" || args[1] == "--transit-checkpoint"
  let guarded_mode = args[1] == "--guarded" || args[1] == "--guarded-checkpoint"
  let stream_mode = evaluation_mode ||
    args[1] == "--stream" ||
    args[1] == "--checkpoint" ||
    args[1] == "--reframe" ||
    count_mode ||
    analysis_mode ||
    health_mode ||
    guarded_mode ||
    transit_mode ||
    evidence_mode ||
    evidence_analysis_mode ||
    evidence_guarded_mode ||
    evidence_transit_mode ||
    evidence_transit_analysis_mode ||
    evidence_guarded_transit_mode ||
    transit_windows_mode ||
    transit_window_analysis_mode ||
    guarded_transit_windows_mode ||
    velocity_evidence_mode ||
    zone_evidence_mode ||
    zone_intersection_mode ||
    disk_zone_evidence_mode ||
    footprint_zone_evidence_mode ||
    assigned_zone_evidence_mode ||
    footprint_runs_mode ||
    footprint_run_window_analysis_mode ||
    footprint_run_analysis_mode ||
    footprint_run_window_guarded_mode ||
    footprint_run_guarded_mode ||
    footprint_run_windows_mode
  if args.length() == 4 && stream_mode && args[2] == "--max-line-bytes" {
    max_bytes = @string.parse_int(args[3], base=10) catch {
      _ => {
        diagnostic("max-line-bytes must be a positive integer")
        return
      }
    }
    if max_bytes <= 0 || max_bytes > 16777216 {
      diagnostic("max-line-bytes must be in [1,16777216]")
      return
    }
  } else if args.length() != 2 {
    diagnostic(
      "usage: moonground --version | --version-json | (--evaluate-measurements | --stream | --checkpoint | --reframe | --count | --count-checkpoint | --analyze | --analyze-checkpoint | --health | --health-checkpoint | --guarded | --guarded-checkpoint | --transit | --transit-checkpoint | --count-evidence | --evidence-checkpoint | --analyze-evidence | --analyze-evidence-checkpoint | --guarded-evidence | --guarded-evidence-checkpoint | --transit-evidence | --transit-evidence-checkpoint | --analyze-transit-evidence | --analyze-transit-evidence-checkpoint | --guarded-transit-evidence | --guarded-transit-evidence-checkpoint | --transit-windows | --transit-windows-checkpoint | --analyze-transit-windows | --analyze-transit-windows-checkpoint | --guarded-transit-windows | --guarded-transit-windows-checkpoint | --velocity-evidence | --zone-evidence | --zone-intersection | --disk-zone-evidence | --footprint-zone-evidence | --assigned-zone-evidence | --footprint-runs | --footprint-runs-checkpoint | --analyze-footprint-runs | --analyze-footprint-runs-checkpoint | --preview-footprint-run | --guarded-footprint-runs | --guarded-footprint-runs-checkpoint | --preview-guarded-footprint-run | --footprint-run-windows | --footprint-run-windows-checkpoint | --analyze-footprint-run-windows | --analyze-footprint-run-windows-checkpoint | --preview-footprint-run-window | --guarded-footprint-run-windows | --guarded-footprint-run-windows-checkpoint | --preview-guarded-footprint-run-window) [--max-line-bytes N] | --project | --calibrate | --calibration-sensitivity | --calibration-distance | --calibration-angle | --calibration-area | --calibration-line-offset",
    )
    return
  }
  let chunk = FixedArray::make(4096, b'\x00')
  let pending : Array[Byte] = []
  let mut session : @codec.ReplaySession? = None
  let evaluation : Ref[@codec.MeasurementEvaluationReplay?] = Ref(None)
  let reframer : Ref[@codec.ReplayReframer?] = Ref(None)
  let counter : Ref[@codec.GateReplay?] = Ref(None)
  let analysis : Ref[@codec.AnalysisReplay?] = Ref(None)
  let health : Ref[@codec.HealthReplay?] = Ref(None)
  let footprint_zone_evidence : Ref[@codec.FootprintZoneEvidenceReplay?] = Ref(
    None,
  )
  let footprint_run_window_guarded : Ref[
    @codec.FootprintRunWindowGuardedReplay?,
  ] = Ref(None)
  let footprint_run_window_guarded_preview_seen : Ref[Bool] = Ref(false)
  let footprint_run_guarded : Ref[@codec.FootprintRunGuardedReplay?] = Ref(None)
  let footprint_run_guarded_preview_seen : Ref[Bool] = Ref(false)
  let footprint_run_window_analysis : Ref[
    @codec.FootprintRunWindowAnalysisReplay?,
  ] = Ref(None)
  let footprint_run_window_preview_seen : Ref[Bool] = Ref(false)
  let footprint_run_analysis : Ref[@codec.FootprintRunAnalysisReplay?] = Ref(
    None,
  )
  let footprint_run_preview_seen : Ref[Bool] = Ref(false)
  let footprint_run_windows : Ref[@codec.FootprintRunWindowReplay?] = Ref(None)
  let footprint_runs : Ref[@codec.FootprintRunReplay?] = Ref(None)
  let assigned_zone_evidence : Ref[@codec.AssignedZoneEvidenceReplay?] = Ref(
    None,
  )
  let disk_zone_evidence : Ref[@codec.DiskZoneEvidenceReplay?] = Ref(None)
  let zone_evidence : Ref[@codec.ZoneEvidenceReplay?] = Ref(None)
  let zone_intersection : Ref[@codec.ZoneIntersectionReplay?] = Ref(None)
  let velocity_evidence : Ref[@codec.VelocityEvidenceReplay?] = Ref(None)
  let guarded_transit_windows : Ref[@codec.EvidenceGuardedTransitWindowReplay?] = Ref(
    None,
  )
  let transit_window_analysis : Ref[@codec.EvidenceTransitWindowAnalysisReplay?] = Ref(
    None,
  )
  let transit_windows : Ref[@codec.EvidenceTransitWindowReplay?] = Ref(None)
  let evidence_guarded_transit : Ref[@codec.EvidenceGuardedTransitReplay?] = Ref(
    None,
  )
  let evidence_transit_analysis : Ref[@codec.EvidenceTransitAnalysisReplay?] = Ref(
    None,
  )
  let evidence_transit : Ref[@codec.EvidenceTransitReplay?] = Ref(None)
  let evidence_guarded : Ref[@codec.EvidenceGuardedReplay?] = Ref(None)
  let evidence_analysis : Ref[@codec.EvidenceAnalysisReplay?] = Ref(None)
  let evidence : Ref[@codec.EvidenceGateReplay?] = Ref(None)
  let transit : Ref[@codec.TransitReplay?] = Ref(None)
  let guarded : Ref[@codec.GuardedReplay?] = Ref(None)
  let mut line_number = 1
  let mut projection_done = false
  while true {
    let count = @stdio.stdin.read(chunk)
    if count == 0 {
      break
    }
    for index in 0..<count {
      let byte = chunk[index]
      if byte == b'\n' {
        let line = @utf8.decode(Bytes::from_array(pending[:])) catch {
          _ => {
            diagnostic("line \{line_number}: invalid UTF-8")
            return
          }
        }
        if evaluation_mode {
          evaluation_line(evaluation, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
        } else if footprint_run_window_guarded_mode {
          let output = footprint_run_window_guarded_line(
            footprint_run_window_guarded,
            line,
            args[1] == "--preview-guarded-footprint-run-window",
            footprint_run_window_guarded_preview_seen,
          ) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] != "--guarded-footprint-run-windows-checkpoint" &&
            output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if footprint_run_guarded_mode {
          let output = footprint_run_guarded_line(
            footprint_run_guarded,
            line,
            args[1] == "--preview-guarded-footprint-run",
            footprint_run_guarded_preview_seen,
          ) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] != "--guarded-footprint-runs-checkpoint" &&
            output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if footprint_run_window_analysis_mode {
          let output = footprint_run_window_analysis_line(
            footprint_run_window_analysis,
            line,
            args[1] == "--preview-footprint-run-window",
            footprint_run_window_preview_seen,
          ) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] != "--analyze-footprint-run-windows-checkpoint" &&
            output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if footprint_run_analysis_mode {
          let output = footprint_run_analysis_line(
            footprint_run_analysis,
            line,
            args[1] == "--preview-footprint-run",
            footprint_run_preview_seen,
          ) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] != "--analyze-footprint-runs-checkpoint" &&
            output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if footprint_run_windows_mode {
          let output = footprint_run_windows_line(footprint_run_windows, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--footprint-run-windows" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if footprint_runs_mode {
          let output = footprint_runs_line(footprint_runs, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--footprint-runs" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if assigned_zone_evidence_mode {
          let output = assigned_zone_evidence_line(assigned_zone_evidence, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--assigned-zone-evidence" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if footprint_zone_evidence_mode {
          let output = footprint_zone_evidence_line(
            footprint_zone_evidence, line,
          ) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--footprint-zone-evidence" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if disk_zone_evidence_mode {
          let output = disk_zone_evidence_line(disk_zone_evidence, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--disk-zone-evidence" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if zone_intersection_mode {
          let output = zone_intersection_line(zone_intersection, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--zone-intersection" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if zone_evidence_mode {
          let output = zone_evidence_line(zone_evidence, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--zone-evidence" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if velocity_evidence_mode {
          let output = velocity_evidence_line(velocity_evidence, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--velocity-evidence" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if guarded_transit_windows_mode {
          let output = guarded_transit_windows_line(
            guarded_transit_windows, line,
          ) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--guarded-transit-windows" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if transit_window_analysis_mode {
          let output = transit_window_analysis_line(
            transit_window_analysis, line,
          ) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--analyze-transit-windows" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if transit_windows_mode {
          let output = transit_windows_line(transit_windows, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--transit-windows" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if evidence_guarded_transit_mode {
          let output = evidence_guarded_transit_line(
            evidence_guarded_transit, line,
          ) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--guarded-transit-evidence" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if evidence_transit_analysis_mode {
          let output = evidence_transit_analysis_line(
            evidence_transit_analysis, line,
          ) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--analyze-transit-evidence" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if evidence_transit_mode {
          let output = evidence_transit_line(evidence_transit, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--transit-evidence" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if evidence_guarded_mode {
          let output = evidence_guarded_line(evidence_guarded, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--guarded-evidence" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if evidence_analysis_mode {
          let output = evidence_analysis_line(evidence_analysis, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--analyze-evidence" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if evidence_mode {
          let output = evidence_line(evidence, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--count-evidence" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if transit_mode {
          let output = transit_line(transit, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--transit" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if guarded_mode {
          let output = guarded_line(guarded, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--guarded" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if health_mode {
          let output = health_line(health, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--health" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if analysis_mode {
          let output = analysis_line(analysis, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--analyze" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if count_mode {
          let output = count_line(counter, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--count" && output is Some(output) {
            @stdio.stdout.write(output + "\n")
          }
        } else if args[1] == "--reframe" {
          let output = reframe_line(reframer, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          @stdio.stdout.write(output + "\n")
        } else if !stream_mode {
          if projection_done {
            diagnostic("stateless mode accepts exactly one line")
            return
          }
          let output = try {
            if args[1] == "--calibrate" {
              @codec.calibrate_json(line)
            } else if args[1] == "--calibration-sensitivity" {
              @codec.calibration_sensitivity_json(line)
            } else if args[1] == "--calibration-distance" {
              @codec.calibration_distance_json(line)
            } else if args[1] == "--calibration-angle" {
              @codec.calibration_angle_json(line)
            } else if args[1] == "--calibration-line-offset" {
              @codec.calibration_line_offset_json(line)
            } else if args[1] == "--calibration-area" {
              @codec.calibration_area_json(line)
            } else {
              @codec.project_json(line)
            }
          } catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          @stdio.stdout.write(output + "\n")
          projection_done = true
        } else {
          match session {
            None =>
              session = Some(
                @codec.ReplaySession::open(line) catch {
                  error => {
                    diagnostic("line \{line_number}: " + error.message())
                    return
                  }
                },
              )
            Some(replay) => {
              let output = replay.process_line(line) catch {
                error => {
                  diagnostic("line \{line_number}: " + error.message())
                  return
                }
              }
              if args[1] == "--stream" {
                @stdio.stdout.write(output + "\n")
              }
            }
          }
        }
        line_number += 1
        pending.clear()
      } else {
        if pending.length() >= max_bytes {
          diagnostic("line \{line_number}: line byte limit exceeded")
          return
        }
        pending.push(byte)
      }
    }
  }
  if pending.length() > 0 {
    let line = @utf8.decode(Bytes::from_array(pending[:])) catch {
      _ => {
        diagnostic("line \{line_number}: invalid UTF-8")
        return
      }
    }
    if evaluation_mode {
      evaluation_line(evaluation, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
    } else if footprint_run_window_guarded_mode {
      let output = footprint_run_window_guarded_line(
        footprint_run_window_guarded,
        line,
        args[1] == "--preview-guarded-footprint-run-window",
        footprint_run_window_guarded_preview_seen,
      ) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] != "--guarded-footprint-run-windows-checkpoint" &&
        output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if footprint_run_guarded_mode {
      let output = footprint_run_guarded_line(
        footprint_run_guarded,
        line,
        args[1] == "--preview-guarded-footprint-run",
        footprint_run_guarded_preview_seen,
      ) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] != "--guarded-footprint-runs-checkpoint" &&
        output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if footprint_run_window_analysis_mode {
      let output = footprint_run_window_analysis_line(
        footprint_run_window_analysis,
        line,
        args[1] == "--preview-footprint-run-window",
        footprint_run_window_preview_seen,
      ) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] != "--analyze-footprint-run-windows-checkpoint" &&
        output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if footprint_run_analysis_mode {
      let output = footprint_run_analysis_line(
        footprint_run_analysis,
        line,
        args[1] == "--preview-footprint-run",
        footprint_run_preview_seen,
      ) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] != "--analyze-footprint-runs-checkpoint" &&
        output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if footprint_run_windows_mode {
      let output = footprint_run_windows_line(footprint_run_windows, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--footprint-run-windows" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if footprint_runs_mode {
      let output = footprint_runs_line(footprint_runs, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--footprint-runs" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if assigned_zone_evidence_mode {
      let output = assigned_zone_evidence_line(assigned_zone_evidence, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--assigned-zone-evidence" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if footprint_zone_evidence_mode {
      let output = footprint_zone_evidence_line(footprint_zone_evidence, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--footprint-zone-evidence" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if disk_zone_evidence_mode {
      let output = disk_zone_evidence_line(disk_zone_evidence, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--disk-zone-evidence" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if zone_intersection_mode {
      let output = zone_intersection_line(zone_intersection, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--zone-intersection" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if zone_evidence_mode {
      let output = zone_evidence_line(zone_evidence, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--zone-evidence" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if velocity_evidence_mode {
      let output = velocity_evidence_line(velocity_evidence, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--velocity-evidence" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if guarded_transit_windows_mode {
      let output = guarded_transit_windows_line(guarded_transit_windows, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--guarded-transit-windows" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if transit_window_analysis_mode {
      let output = transit_window_analysis_line(transit_window_analysis, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--analyze-transit-windows" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if transit_windows_mode {
      let output = transit_windows_line(transit_windows, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--transit-windows" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if evidence_guarded_transit_mode {
      let output = evidence_guarded_transit_line(evidence_guarded_transit, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--guarded-transit-evidence" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if evidence_transit_analysis_mode {
      let output = evidence_transit_analysis_line(
        evidence_transit_analysis, line,
      ) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--analyze-transit-evidence" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if evidence_transit_mode {
      let output = evidence_transit_line(evidence_transit, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--transit-evidence" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if evidence_guarded_mode {
      let output = evidence_guarded_line(evidence_guarded, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--guarded-evidence" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if evidence_analysis_mode {
      let output = evidence_analysis_line(evidence_analysis, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--analyze-evidence" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if evidence_mode {
      let output = evidence_line(evidence, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--count-evidence" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if transit_mode {
      let output = transit_line(transit, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--transit" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if guarded_mode {
      let output = guarded_line(guarded, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--guarded" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if health_mode {
      let output = health_line(health, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--health" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if analysis_mode {
      let output = analysis_line(analysis, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--analyze" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if count_mode {
      let output = count_line(counter, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      if args[1] == "--count" && output is Some(output) {
        @stdio.stdout.write(output + "\n")
      }
    } else if args[1] == "--reframe" {
      let output = reframe_line(reframer, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      @stdio.stdout.write(output + "\n")
    } else if !stream_mode {
      if projection_done {
        diagnostic("stateless mode accepts exactly one line")
        return
      }
      let output = try {
        if args[1] == "--calibrate" {
          @codec.calibrate_json(line)
        } else if args[1] == "--calibration-sensitivity" {
          @codec.calibration_sensitivity_json(line)
        } else if args[1] == "--calibration-distance" {
          @codec.calibration_distance_json(line)
        } else if args[1] == "--calibration-angle" {
          @codec.calibration_angle_json(line)
        } else if args[1] == "--calibration-line-offset" {
          @codec.calibration_line_offset_json(line)
        } else if args[1] == "--calibration-area" {
          @codec.calibration_area_json(line)
        } else {
          @codec.project_json(line)
        }
      } catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      @stdio.stdout.write(output + "\n")
      projection_done = true
    } else {
      match session {
        None =>
          session = Some(
            @codec.ReplaySession::open(line) catch {
              error => {
                diagnostic("line \{line_number}: " + error.message())
                return
              }
            },
          )
        Some(replay) => {
          let output = replay.process_line(line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--stream" {
            @stdio.stdout.write(output + "\n")
          }
        }
      }
    }
  }
  if evaluation_mode {
    if evaluation.val is None {
      diagnostic("missing measurement evaluation configuration")
    }
  } else if footprint_run_window_guarded_mode {
    if footprint_run_window_guarded.val is None {
      diagnostic("missing footprint run window guarded source")
    }
    if args[1] == "--preview-guarded-footprint-run-window" &&
      !footprint_run_window_guarded_preview_seen.val {
      diagnostic(
        "missing guarded footprint run window preview observation frame",
      )
    }
  } else if footprint_run_guarded_mode {
    if footprint_run_guarded.val is None {
      diagnostic("missing footprint run analysis source")
    }
    if args[1] == "--preview-guarded-footprint-run" &&
      !footprint_run_guarded_preview_seen.val {
      diagnostic("missing guarded footprint run preview observation frame")
    }
  } else if footprint_run_window_analysis_mode {
    if footprint_run_window_analysis.val is None {
      diagnostic("missing footprint run window analysis source")
    }
    if args[1] == "--preview-footprint-run-window" &&
      !footprint_run_window_preview_seen.val {
      diagnostic("missing footprint run window preview observation frame")
    }
  } else if footprint_run_analysis_mode {
    if footprint_run_analysis.val is None {
      diagnostic("missing footprint run analysis source")
    }
    if args[1] == "--preview-footprint-run" && !footprint_run_preview_seen.val {
      diagnostic("missing footprint run preview observation frame")
    }
  } else if footprint_run_windows_mode {
    if footprint_run_windows.val is None {
      diagnostic("missing footprint run windows source")
    }
  } else if footprint_runs_mode {
    if footprint_runs.val is None {
      diagnostic("missing footprint run source")
    }
  } else if assigned_zone_evidence_mode {
    if assigned_zone_evidence.val is None {
      diagnostic("missing disk zone evidence source")
    }
  } else if footprint_zone_evidence_mode {
    if footprint_zone_evidence.val is None {
      diagnostic("missing disk zone evidence source")
    }
  } else if disk_zone_evidence_mode {
    if disk_zone_evidence.val is None {
      diagnostic("missing disk zone evidence source")
    }
  } else if zone_intersection_mode {
    if zone_intersection.val is None {
      diagnostic("missing zone intersection source")
    }
  } else if zone_evidence_mode {
    if zone_evidence.val is None {
      diagnostic("missing zone evidence source")
    }
  } else if velocity_evidence_mode {
    if velocity_evidence.val is None {
      diagnostic("missing velocity evidence source")
    }
  } else if guarded_transit_windows_mode {
    if guarded_transit_windows.val is None {
      diagnostic("missing guarded transit windows source")
    }
  } else if transit_window_analysis_mode {
    if transit_window_analysis.val is None {
      diagnostic("missing transit window analysis source")
    }
  } else if transit_windows_mode {
    if transit_windows.val is None {
      diagnostic("missing transit windows source")
    }
  } else if evidence_guarded_transit_mode {
    if evidence_guarded_transit.val is None {
      diagnostic("missing evidence guarded transit source")
    }
  } else if evidence_transit_analysis_mode {
    if evidence_transit_analysis.val is None {
      diagnostic("missing evidence transit analysis source")
    }
  } else if evidence_transit_mode {
    if evidence_transit.val is None {
      diagnostic("missing evidence transit source")
    }
  } else if evidence_guarded_mode {
    if evidence_guarded.val is None {
      diagnostic("missing evidence guarded source")
    }
  } else if evidence_analysis_mode {
    if evidence_analysis.val is None {
      diagnostic("missing evidence analysis source")
    }
  } else if evidence_mode {
    if evidence.val is None {
      diagnostic("missing gate evidence source")
    }
  } else if transit_mode {
    if transit.val is None {
      diagnostic("missing transit source")
    }
  } else if guarded_mode {
    if guarded.val is None {
      diagnostic("missing guarded source")
    }
  } else if health_mode {
    if health.val is None {
      diagnostic("missing health configuration")
    }
  } else if analysis_mode {
    if analysis.val is None {
      diagnostic("missing analysis source")
    }
  } else if count_mode {
    if counter.val is None {
      diagnostic("missing gate configuration")
    }
  } else if args[1] == "--reframe" {
    if reframer.val is None {
      diagnostic("missing reframing header")
    }
  } else if stream_mode && session is None {
    diagnostic("missing configuration line")
  } else if !stream_mode && !projection_done {
    diagnostic("missing stateless request")
  }
  if args[1] == "--guarded-footprint-run-windows-checkpoint" &&
    footprint_run_window_guarded.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic(
          "footprint run window guarded checkpoint: " + error.message(),
        )
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--guarded-footprint-runs-checkpoint" &&
    footprint_run_guarded.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("footprint run analysis checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--analyze-footprint-run-windows-checkpoint" &&
    footprint_run_window_analysis.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic(
          "footprint run window analysis checkpoint: " + error.message(),
        )
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--analyze-footprint-runs-checkpoint" &&
    footprint_run_analysis.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("footprint run analysis checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--footprint-run-windows-checkpoint" &&
    footprint_run_windows.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("footprint run windows checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--footprint-runs-checkpoint" &&
    footprint_runs.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("footprint run checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--checkpoint" && session is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--count-checkpoint" && counter.val is Some(counter) {
    let checkpoint = counter.checkpoint_json() catch {
      error => {
        diagnostic("gate checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--analyze-checkpoint" && analysis.val is Some(analysis) {
    let checkpoint = analysis.checkpoint_json() catch {
      error => {
        diagnostic("analysis checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--health-checkpoint" && health.val is Some(health) {
    let checkpoint = health.checkpoint_json() catch {
      error => {
        diagnostic("health checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--guarded-checkpoint" && guarded.val is Some(guarded) {
    let checkpoint = guarded.checkpoint_json() catch {
      error => {
        diagnostic("guarded checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--transit-checkpoint" && transit.val is Some(transit) {
    let checkpoint = transit.checkpoint_json() catch {
      error => {
        diagnostic("transit checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--guarded-evidence-checkpoint" &&
    evidence_guarded.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("evidence guarded checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--analyze-evidence-checkpoint" &&
    evidence_analysis.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("evidence analysis checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--evidence-checkpoint" && evidence.val is Some(evidence) {
    let checkpoint = evidence.checkpoint_json() catch {
      error => {
        diagnostic("evidence checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--transit-evidence-checkpoint" &&
    evidence_transit.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("evidence transit checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--analyze-transit-evidence-checkpoint" &&
    evidence_transit_analysis.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("evidence transit analysis checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--guarded-transit-evidence-checkpoint" &&
    evidence_guarded_transit.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("evidence guarded transit checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--transit-windows-checkpoint" &&
    transit_windows.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("transit windows checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--analyze-transit-windows-checkpoint" &&
    transit_window_analysis.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("transit window analysis checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if args[1] == "--guarded-transit-windows-checkpoint" &&
    guarded_transit_windows.val is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("guarded transit windows checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
  if evaluation.val is Some(replay) {
    @stdio.stdout.write(replay.report_json() + "\n")
  }
}
