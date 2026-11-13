///|
fn add_health_window_time(
  timestamp_us : Int64,
  windows : @transit.EvidenceTransitWindowCheckpoint,
  known : Map[Int64, Bool],
) -> Unit raise @types.GroundError {
  if windows.baseline_timestamp_us is None && timestamp_us < windows.origin_us {
    raise @types.InvalidInput(
      "guarded health evidence predates the statistics origin",
    )
  }
  if windows.baseline_timestamp_us is Some(baseline) && timestamp_us <= baseline {
    return
  }
  if windows.current_window is Some(current) &&
    timestamp_us >= current.start_us &&
    timestamp_us <= current.last_timestamp_us {
    if timestamp_us < current.first_timestamp_us {
      raise @types.InvalidInput(
        "guarded window omits a saved health observation",
      )
    }
    known[timestamp_us] = true
    if Int64::from_int(known.length()) > current.input_frames {
      raise @types.InvalidInput(
        "guarded window has fewer frames than saved observation times",
      )
    }
  }
}

///|
/// The original owners validate their geometry and histories first. This
/// collector only joins their saved sample times with current health evidence.
fn validate_health_window_samples(
  guarded : EvidenceGuardedTransitCheckpoint,
  windows : @transit.EvidenceTransitWindowCheckpoint,
) -> Unit raise @types.GroundError {
  guard guarded.health.streak is Some(streak) else { return }
  let known : Map[Int64, Bool] = Map([])
  add_health_window_time(streak.since_us, windows, known)
  guard windows.current_window is Some(current) else { return }
  add_health_window_time(current.first_timestamp_us, windows, known)
  add_health_window_time(current.last_timestamp_us, windows, known)
  guard guarded.analysis.measurement is @analysis.Pixel(pixel) else {
    raise @types.InvalidInput(
      "guarded transit windows require pixel measurements",
    )
  }
  for track in pixel.motion.tracks {
    add_health_window_time(track.first_timestamp_us, windows, known)
    add_health_window_time(track.last_timestamp_us, windows, known)
  }
  for track in guarded.analysis.transit.counting.tracks {
    for anchor in track.anchors {
      if anchor is Some(anchor) {
        add_health_window_time(anchor.timestamp_us, windows, known)
      }
    }
  }
  for pending in guarded.analysis.transit.pending {
    add_health_window_time(pending.entry.from_timestamp_us, windows, known)
    add_health_window_time(pending.entry.to_timestamp_us, windows, known)
  }
  let cutoff = match windows.baseline_timestamp_us {
    Some(baseline) if baseline >= current.start_us => baseline + 1L
    _ => current.start_us
  }
  let outside = if cutoff > streak.since_us {
    cutoff - streak.since_us
  } else {
    0L
  }
  let observations = Int64::from_int(streak.observations)
  let mut known_before_streak = 0L
  for timestamp, _ in known {
    if timestamp < streak.since_us {
      known_before_streak += 1L
    }
  }
  if observations > outside &&
    observations - outside > current.input_frames - known_before_streak {
    raise @types.InvalidInput(
      "guarded window cannot contain the saved health samples",
    )
  }
  let gap = guarded.health.config.max_gap_us - 1L
  if gap == 0L {
    return
  }
  if streak.since_us < cutoff && current.first_timestamp_us - cutoff >= gap {
    raise @types.InvalidInput(
      "guarded window starts after an impossible health continuity gap",
    )
  }
  let times = known.keys().collect()
  times.sort()
  let mut remaining = current.input_frames - Int64::from_int(times.length())
  for index in 1..<times.length() {
    let previous = times[index - 1]
    let next = times[index]
    if previous >= streak.since_us {
      let additional = (next - previous - 1L) / gap
      if additional > remaining {
        raise @types.InvalidInput(
          "guarded window lacks frames to sustain health continuity",
        )
      }
      remaining = remaining - additional
    }
  }
  if streak.observations < guarded.health.config.min_observations {
    // Before saturation the count is exact. Other known frames cannot be
    // silently assigned to this same consecutive evidence streak.
    if streak.since_us >= current.first_timestamp_us {
      let preceding_slots = streak.since_us - current.first_timestamp_us
      if current.input_frames > preceding_slots &&
        current.input_frames - preceding_slots > observations {
        raise @types.InvalidInput(
          "guarded window exceeds the exact health sample count",
        )
      }
    } else {
      let span = current.first_timestamp_us - streak.since_us
      let quotient = span / gap
      let preceding_samples = quotient +
        (if span % gap == 0L { 0L } else { 1L })
      if preceding_samples > observations ||
        current.input_frames > observations - preceding_samples {
        raise @types.InvalidInput(
          "guarded window and preceding health samples exceed the exact count",
        )
      }
    }
  }
}

///|
/// Restore the old guarded policy and original joint statistics relationship,
/// then check the saved health samples against those same supplied frames.
pub fn EvidenceGuardedTransitWindowSession::from_checkpoint(
  checkpoint : EvidenceGuardedTransitWindowCheckpoint,
) -> EvidenceGuardedTransitWindowSession raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput(
      "unsupported guarded transit window checkpoint version",
    )
  }
  let guarded = EvidenceGuardedTransitSession::from_checkpoint(
    checkpoint.guarded,
  )
  let saved = guarded.checkpoint()
  let analysis = @analysis.EvidenceTransitWindowSession::from_checkpoint({
    version: 1,
    analysis: saved.analysis,
    windows: checkpoint.windows,
  })
  validate_health_window_samples(saved, analysis.checkpoint().windows)
  { analysis, health: guarded.health, max_tracks: guarded.max_tracks, }
}
