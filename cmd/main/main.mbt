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
async fn main {
  let args = @env.args()
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    @stdio.stdout.write(
      "moonground (--stream | --checkpoint | --reframe | --count | --count-checkpoint | --analyze | --analyze-checkpoint | --health | --health-checkpoint | --guarded | --guarded-checkpoint | --transit | --transit-checkpoint | --count-evidence | --evidence-checkpoint | --analyze-evidence | --analyze-evidence-checkpoint | --guarded-evidence | --guarded-evidence-checkpoint | --transit-evidence | --transit-evidence-checkpoint | --analyze-transit-evidence | --analyze-transit-evidence-checkpoint | --guarded-transit-evidence | --guarded-transit-evidence-checkpoint | --transit-windows | --transit-windows-checkpoint | --analyze-transit-windows | --analyze-transit-windows-checkpoint | --guarded-transit-windows | --guarded-transit-windows-checkpoint | --velocity-evidence | --zone-evidence) [--max-line-bytes N] | --project | --calibrate\nStream/checkpoint read configuration or {resume: checkpoint}, then frames. --checkpoint writes only the final state at EOF. --reframe reads {source: configuration_or_resume, transform: {...}}, then original frames, and writes transformed NDJSON. --count reads gate configuration or {resume: gate_checkpoint}, then schema-0.2 measurement frames; --count-checkpoint writes only final gate state at EOF. --analyze reads {measurement: raw_session_source, counting: raw_gate_source} or {resume: analysis_checkpoint}, then original observations. --analyze-checkpoint writes only final joint state. --health reads fixed-landmark calibration configuration or {resume: health_checkpoint}, then landmark observation frames; --health-checkpoint writes only final health state. --guarded reads {analysis: raw_analysis_source, health: raw_health_source} or {resume: guarded_checkpoint}, then {measurement: raw_pixel_frame, health: raw_landmark_frame}. --guarded also accepts {replace_projection: raw_replacement_JSON}; its timestamp_us, calibration and explicit camera (object or null) create a blocked barrier and require new health evidence. --guarded-checkpoint writes only final bound state. --transit reads {counting: raw_gate_source, sections: [...], max_duration_us: optional_string} or {resume: transit_checkpoint}, then schema-0.2 measurement frames. --transit-checkpoint writes only final downstream state; upstream motion must be restored separately. --count-evidence reads {counting: raw_fresh_gate_configuration, sigma_multiplier: optional_number} or {resume: evidence_checkpoint}, then schema-0.2 measurements. --evidence-checkpoint writes only final covariance-evidence state. --analyze-evidence reads {measurement: raw_session_source, counting: raw_evidence_source} or {resume: evidence_analysis_checkpoint}, then original observations. --analyze-evidence-checkpoint writes only the final complete atomic measurement and covariance-evidence state. --guarded-evidence reads {analysis: raw_evidence_analysis_source, health: raw_health_source} or {resume: evidence_guarded_checkpoint}, then the same paired raw observation or replace_projection lines as --guarded. --guarded-evidence-checkpoint writes only the final complete health, motion and evidence state. --transit-evidence reads {counting: raw_evidence_source, sections: [...], max_duration_us: optional_string} or {resume: evidence_transit_checkpoint}, then original schema-0.2 measurement frames. --transit-evidence-checkpoint writes only the final complete downstream evidence and passage state; restore the upstream clock separately. --analyze-transit-evidence reads {measurement: raw_session_source, transit: raw_evidence_transit_source} or {resume: evidence_transit_analysis_checkpoint}, then raw pixel or ground observations. --analyze-transit-evidence-checkpoint writes only the complete joint measurement and evidence-transit state. --guarded-transit-evidence reads {analysis: raw_evidence_transit_analysis_source, health: raw_health_source} or {resume: evidence_guarded_transit_checkpoint}, then paired raw pixel and landmark observation or replace_projection lines. --guarded-transit-evidence-checkpoint writes the complete health, motion, evidence and transit state. --transit-windows reads {transit: raw_evidence_transit_source, window_us: decimal_string, duration_limits_us: [decimal_string], origin_us: optional_decimal_string} or {resume: windows_checkpoint}, then original evidence_transit_frame results. --transit-windows-checkpoint writes only the downstream statistics state; restore the upstream clock separately. --analyze-transit-windows reads {analysis: raw_evidence_transit_analysis_source, windows: raw_window_options_or_resume} or {resume: complete_window_analysis_checkpoint}, then raw pixel or ground observations. --analyze-transit-windows-checkpoint writes the complete joint measurement, transit and window state. --guarded-transit-windows reads {guarded: raw_evidence_guarded_transit_source, windows: raw_window_options_or_resume} or {resume: complete_guarded_transit_windows_checkpoint}, then paired raw observations or original replace_projection control lines. --guarded-transit-windows-checkpoint writes the complete health, measurement, transit and window state. --velocity-evidence reads {session_id, probes: [{probe_id, direction: [dx,dy], threshold_mps, sigma_multiplier?: number}], max_tracks?: integer}, then original schema-0.2 measurement frames. Each frame is independent; only current Ready velocities produce threshold evidence. No checkpoint or event counters. --zone-evidence reads {session_id, zones: [{zone_id, vertices_m: [[x,y],...], sigma_multiplier?: number}], max_tracks?: integer}, then schema-0.2 measurements. Only current Ready positions produce independent convex-zone halfplane evidence. No checkpoint or region events.\n",
    )
    return
  }
  if args.length() < 2 ||
    (
      args[1] != "--stream" &&
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
      args[1] != "--project" &&
      args[1] != "--calibrate"
    ) {
    diagnostic(
      "usage: moonground (--stream | --checkpoint | --reframe | --count | --count-checkpoint | --analyze | --analyze-checkpoint | --health | --health-checkpoint | --guarded | --guarded-checkpoint | --transit | --transit-checkpoint | --count-evidence | --evidence-checkpoint | --analyze-evidence | --analyze-evidence-checkpoint | --guarded-evidence | --guarded-evidence-checkpoint | --transit-evidence | --transit-evidence-checkpoint | --analyze-transit-evidence | --analyze-transit-evidence-checkpoint | --guarded-transit-evidence | --guarded-transit-evidence-checkpoint | --transit-windows | --transit-windows-checkpoint | --analyze-transit-windows | --analyze-transit-windows-checkpoint | --guarded-transit-windows | --guarded-transit-windows-checkpoint | --velocity-evidence | --zone-evidence) [--max-line-bytes N] | --project | --calibrate",
    )
    return
  }
  let mut max_bytes = 1048576
  let count_mode = args[1] == "--count" || args[1] == "--count-checkpoint"
  let analysis_mode = args[1] == "--analyze" ||
    args[1] == "--analyze-checkpoint"
  let health_mode = args[1] == "--health" || args[1] == "--health-checkpoint"
  let zone_evidence_mode = args[1] == "--zone-evidence"
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
  let stream_mode = args[1] == "--stream" ||
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
    zone_evidence_mode
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
      "usage: moonground (--stream | --checkpoint | --reframe | --count | --count-checkpoint | --analyze | --analyze-checkpoint | --health | --health-checkpoint | --guarded | --guarded-checkpoint | --transit | --transit-checkpoint | --count-evidence | --evidence-checkpoint | --analyze-evidence | --analyze-evidence-checkpoint | --guarded-evidence | --guarded-evidence-checkpoint | --transit-evidence | --transit-evidence-checkpoint | --analyze-transit-evidence | --analyze-transit-evidence-checkpoint | --guarded-transit-evidence | --guarded-transit-evidence-checkpoint | --transit-windows | --transit-windows-checkpoint | --analyze-transit-windows | --analyze-transit-windows-checkpoint | --guarded-transit-windows | --guarded-transit-windows-checkpoint | --velocity-evidence | --zone-evidence) [--max-line-bytes N] | --project | --calibrate",
    )
    return
  }
  let chunk = FixedArray::make(4096, b'\x00')
  let pending : Array[Byte] = []
  let mut session : @codec.ReplaySession? = None
  let reframer : Ref[@codec.ReplayReframer?] = Ref(None)
  let counter : Ref[@codec.GateReplay?] = Ref(None)
  let analysis : Ref[@codec.AnalysisReplay?] = Ref(None)
  let health : Ref[@codec.HealthReplay?] = Ref(None)
  let zone_evidence : Ref[@codec.ZoneEvidenceReplay?] = Ref(None)
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
        if zone_evidence_mode {
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
    if zone_evidence_mode {
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
  if zone_evidence_mode {
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
}
