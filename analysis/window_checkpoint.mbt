///|
fn validate_window_definitions(
  analysis : EvidenceTransitSessionCheckpoint,
  windows : @transit.EvidenceTransitWindowCheckpoint,
) -> Unit raise @types.GroundError {
  let source = analysis.transit
  let gate = source.counting
  if gate.session_id != windows.session_id ||
    gate.last_timestamp_us != windows.last_timestamp_us ||
    gate.gates.length() != windows.gates.length() ||
    source.sections.length() != windows.sections.length() ||
    source.counts.length() != windows.counts.length() ||
    gate.config.max_gap_us != windows.config.max_gap_us ||
    gate.config.max_tracks != windows.config.max_tracks ||
    gate.config.max_position_std_m != windows.config.max_position_std_m ||
    gate.sigma_multiplier != windows.sigma_multiplier {
    raise @types.InvalidInput(
      "joint transit windows source definitions or watermark differ",
    )
  }
  for index, expected in gate.gates {
    let actual = windows.gates[index]
    if expected.gate_id != actual.gate_id ||
      !same_point(expected.start_m, actual.start_m) ||
      !same_point(expected.end_m, actual.end_m) ||
      expected.deadband_m != actual.deadband_m {
      raise @types.InvalidInput(
        "joint transit window gate definitions or order differ",
      )
    }
  }
  for index, expected in source.sections {
    let actual = windows.sections[index]
    if expected.section_id != actual.section_id ||
      expected.entry_gate_id != actual.entry_gate_id ||
      expected.exit_gate_id != actual.exit_gate_id ||
      expected.entry_direction != actual.entry_direction ||
      expected.exit_direction != actual.exit_direction ||
      source.counts[index].section_id != windows.counts[index].section_id ||
      source.counts[index].completed != windows.counts[index].completed {
      raise @types.InvalidInput(
        "joint transit window sections or completed totals differ",
      )
    }
  }
}

///|
fn add_joint_window_time(
  timestamp : Int64,
  windows : @transit.EvidenceTransitWindowCheckpoint,
  known : Map[Int64, Bool],
) -> Unit raise @types.GroundError {
  if windows.baseline_timestamp_us is None && timestamp < windows.origin_us {
    raise @types.InvalidInput(
      "joint accepted observation predates the statistics origin",
    )
  }
  if windows.baseline_timestamp_us is Some(baseline) && timestamp <= baseline {
    return
  }
  if windows.current_window is Some(current) &&
    timestamp >= current.start_us &&
    timestamp <= current.last_timestamp_us {
    if timestamp < current.first_timestamp_us {
      raise @types.InvalidInput(
        "joint window omits a saved accepted observation",
      )
    }
    known[timestamp] = true
    if Int64::from_int(known.length()) > current.input_frames {
      raise @types.InvalidInput(
        "joint window has fewer frames than saved accepted times",
      )
    }
  }
}

///|
fn validate_joint_window_times(
  analysis : EvidenceTransitSessionCheckpoint,
  windows : @transit.EvidenceTransitWindowCheckpoint,
) -> Unit raise @types.GroundError {
  let motion = match analysis.measurement {
    Pixel(pixel) => pixel.motion
    Ground(motion) => motion
  }
  let known : Map[Int64, Bool] = Map([])
  if windows.current_window is Some(current) {
    known[current.first_timestamp_us] = true
    known[current.last_timestamp_us] = true
    if Int64::from_int(known.length()) > current.input_frames {
      raise @types.InvalidInput(
        "joint window endpoints require distinct supplied frames",
      )
    }
  }
  for track in motion.tracks {
    add_joint_window_time(track.first_timestamp_us, windows, known)
    add_joint_window_time(track.last_timestamp_us, windows, known)
    if windows.current_window is Some(current) {
      let cutoff = match windows.baseline_timestamp_us {
        Some(baseline) if baseline >= current.start_us => baseline + 1L
        _ => current.start_us
      }
      let outside = if cutoff > track.first_timestamp_us {
        cutoff - track.first_timestamp_us
      } else {
        0L
      }
      let count = Int64::from_int(track.accepted_count)
      if count > outside && count - outside > current.input_frames {
        raise @types.InvalidInput(
          "joint window frame count cannot contain the saved accepted observations",
        )
      }
    }
  }
  for track in analysis.transit.counting.tracks {
    for anchor in track.anchors {
      if anchor is Some(anchor) {
        add_joint_window_time(anchor.timestamp_us, windows, known)
      }
    }
  }
  for pending in analysis.transit.pending {
    add_joint_window_time(pending.entry.from_timestamp_us, windows, known)
    add_joint_window_time(pending.entry.to_timestamp_us, windows, known)
  }
}

///|
fn validate_joint_window_totals(
  analysis : EvidenceTransitSessionCheckpoint,
  windows : @transit.EvidenceTransitWindowCheckpoint,
) -> Unit raise @types.GroundError {
  guard windows.current_window is Some(current) else { return }
  let all_in_current = match windows.baseline_timestamp_us {
    None => current.start_us == windows.origin_us
    Some(baseline) =>
      baseline >= current.start_us || current.start_us - baseline == 1L
  }
  let pending_counts : Map[String, Int64] = Map([])
  for pending in analysis.transit.pending {
    let previous = match pending_counts.get(pending.section_id) {
      Some(value) => value
      None => 0L
    }
    pending_counts[pending.section_id] = previous + 1L
  }
  for index, section in analysis.transit.sections {
    if all_in_current &&
      current.sections[index].completed !=
      windows.counts[index].completed - windows.baseline_counts[index].completed {
      raise @types.InvalidInput(
        "joint first statistics bucket lost completed outcomes",
      )
    }
    let mut entry_index = -1
    for gate_index, gate in analysis.transit.counting.gates {
      if gate.gate_id == section.entry_gate_id {
        entry_index = gate_index
        break
      }
    }
    let entry = analysis.transit.counting.counts[entry_index]
    let mut remaining = match section.entry_direction {
      @events.NegativeToPositive => entry.negative_to_positive
      @events.PositiveToNegative => entry.positive_to_negative
    }
    let completed = analysis.transit.counts[index].completed
    let pending = match pending_counts.get(section.section_id) {
      Some(value) => value
      None => 0L
    }
    if completed > remaining {
      raise @types.InvalidInput("joint window completions exceed entry budget")
    }
    remaining = remaining - completed
    if pending > remaining {
      raise @types.InvalidInput(
        "joint window pending entries exceed entry budget",
      )
    }
    remaining = remaining - pending
    for row in current.sections[index].cancellations {
      if row.count > remaining {
        raise @types.InvalidInput(
          "joint window cancellations exceed unused entry budget",
        )
      }
      remaining = remaining - row.count
    }
  }
}

///|
/// Restore both original components, then validate their shared definitions,
/// sparse accepted times and entry budget. No observation history is replayed.
pub fn EvidenceTransitWindowSession::from_checkpoint(
  checkpoint : EvidenceTransitWindowSessionCheckpoint,
) -> EvidenceTransitWindowSession raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput(
      "unsupported evidence transit window session checkpoint version",
    )
  }
  let analysis = EvidenceTransitSession::from_checkpoint(checkpoint.analysis)
  let windows = @transit.EvidenceTransitWindowCounter::from_checkpoint(
    checkpoint.windows,
  )
  let original = analysis.checkpoint()
  let aggregates = windows.checkpoint()
  validate_window_definitions(original, aggregates)
  validate_joint_window_times(original, aggregates)
  validate_joint_window_totals(original, aggregates)
  { analysis, windows, }
}
