///|
fn footprint_guard_window_anchor(
  anchors : Map[Int64, Int64],
  timestamp : Int64,
  count : Int64,
) -> Unit raise @types.GroundError {
  match anchors.get(timestamp) {
    Some(previous) if previous != count =>
      raise @types.InvalidInput(
        "health and footprint window suffix counts differ at the same input",
      )
    _ => anchors[timestamp] = count
  }
}

///|
fn footprint_guard_window_time(
  timestamp : Int64,
  windows : @zones.FootprintRunWindowCheckpoint,
  known : Map[Int64, Bool],
  forbidden : (Int64, Int64)?,
) -> Unit raise @types.GroundError {
  if forbidden is Some((lower, upper)) && timestamp > lower && timestamp < upper {
    raise @types.InvalidInput(
      "paired window input lies inside the saved health restart gap",
    )
  }
  if windows.baseline_timestamp_us is None && timestamp < windows.origin_us {
    raise @types.InvalidInput(
      "health-controlled input predates the window origin",
    )
  }
  if windows.baseline_timestamp_us is Some(baseline) && timestamp <= baseline {
    return
  }
  if windows.current_window is Some(current) && timestamp >= current.start_us {
    if timestamp < current.first_timestamp_us {
      raise @types.InvalidInput(
        "footprint window omits a saved paired health input",
      )
    }
    known[timestamp] = true
    if known.length().to_int64() > current.input_frames {
      raise @types.InvalidInput(
        "footprint window has fewer frames than saved paired inputs",
      )
    }
  }
}

///|
fn validate_footprint_health_windows(
  pixel : @moonground.MeasurementCheckpoint,
  health : @health.HealthCheckpoint,
  windows : @zones.FootprintRunWindowCheckpoint,
) -> Unit raise @types.GroundError {
  guard health.streak is Some(streak) else { return }
  let since = streak.since_us
  let mut crosses_restart = false
  for track in pixel.motion.tracks {
    if track.first_timestamp_us < since {
      crosses_restart = true
    }
  }
  // Original guard binding permits this only for instant confirmation and a
  // health gap shorter than the surviving motion segment's maximum gap.
  let forbidden = if crosses_restart {
    Some((since - health.config.max_gap_us, since))
  } else {
    None
  }
  if windows.baseline_timestamp_us is Some(baseline) &&
    forbidden is Some((lower, upper)) &&
    baseline > lower &&
    baseline < upper {
    raise @types.InvalidInput(
      "window baseline lies inside the saved health restart gap",
    )
  }
  let known : Map[Int64, Bool] = Map([])
  footprint_guard_window_time(since, windows, known, forbidden)
  guard windows.current_window is Some(current) else { return }
  footprint_guard_window_time(
    current.first_timestamp_us,
    windows,
    known,
    forbidden,
  )
  footprint_guard_window_time(
    current.last_timestamp_us,
    windows,
    known,
    forbidden,
  )
  let anchors : Map[Int64, Int64] = Map([])
  footprint_guard_window_anchor(
    anchors,
    current.first_timestamp_us,
    current.input_frames,
  )
  footprint_guard_window_anchor(anchors, current.last_timestamp_us, 1L)
  for track in pixel.motion.tracks {
    footprint_guard_window_time(
      track.first_timestamp_us,
      windows,
      known,
      forbidden,
    )
    footprint_guard_window_time(
      track.last_timestamp_us,
      windows,
      known,
      forbidden,
    )
  }
  for state in windows.runs.states {
    footprint_guard_window_time(
      state.run.first_timestamp_us,
      windows,
      known,
      forbidden,
    )
    if state.run.first_timestamp_us >= current.first_timestamp_us {
      footprint_guard_window_anchor(
        anchors,
        state.run.first_timestamp_us,
        state.run.sample_count,
      )
    }
  }
  let observations = streak.observations.to_int64()
  let exact = streak.observations < health.config.min_observations
  if exact && since >= current.first_timestamp_us {
    footprint_guard_window_anchor(anchors, since, observations)
  }
  let times = known.keys().collect()
  times.sort()
  let gap = health.config.max_gap_us - 1L
  let mut previous_index = 0
  let mut previous_count = current.input_frames
  let mut additional = 0L
  let mut suffix_upper = current.input_frames
  let left = since.max(current.first_timestamp_us)
  let mut left_upper = current.input_frames
  for index, timestamp in times {
    if index > 0 && times[index - 1] >= since && gap > 0L {
      // Minimum extra samples between consecutive known health inputs.
      additional += (timestamp - times[index - 1] - 1L) / gap
    }
    match anchors.get(timestamp) {
      Some(count) => {
        if count < 1L || count > current.input_frames {
          raise @types.InvalidInput(
            "health suffix exceeds the footprint window input count",
          )
        }
        if index > previous_index {
          let witnesses = (index - previous_index).to_int64()
          if previous_count <= count ||
            witnesses > previous_count - count ||
            additional > previous_count - count - witnesses {
            raise @types.InvalidInput(
              "footprint window suffix lacks inputs to sustain the health evidence",
            )
          }
          if forbidden is Some((lower, upper)) {
            let start = times[previous_index]
            let overlap_start = start.max(lower + 1L)
            let overlap_end = timestamp.min(upper)
            let excluded = if overlap_end > overlap_start {
              overlap_end - overlap_start
            } else {
              0L
            }
            if previous_count - count > timestamp - start - excluded {
              raise @types.InvalidInput(
                "footprint window suffix requires inputs inside the health restart gap",
              )
            }
          }
        }
        suffix_upper = count
        previous_count = count
        previous_index = index
        additional = 0L
        if timestamp == left {
          left_upper = count
        }
      }
      None => if timestamp == left { left_upper = suffix_upper - 1L }
    }
  }
  let cutoff = match windows.baseline_timestamp_us {
    Some(baseline) if baseline >= current.start_us => baseline + 1L
    _ => current.start_us
  }
  let outside_slots = if cutoff > since { cutoff - since } else { 0L }
  let mut known_before = 0L
  for timestamp in times {
    if timestamp < since {
      known_before += 1L
    }
  }
  if observations > outside_slots &&
    (
      observations - outside_slots > current.input_frames - known_before ||
      observations - outside_slots > left_upper
    ) {
    raise @types.InvalidInput(
      "footprint window cannot contain the saved health sample count",
    )
  }
  if gap == 0L {
    return
  }
  if since < cutoff && current.first_timestamp_us - cutoff >= gap {
    raise @types.InvalidInput(
      "footprint window begins after an impossible continuing health gap",
    )
  }
  if exact {
    if since >= current.first_timestamp_us {
      let before_slots = since - current.first_timestamp_us
      if current.input_frames > before_slots &&
        current.input_frames - before_slots > observations {
        raise @types.InvalidInput(
          "footprint window exceeds the exact health sample count",
        )
      }
    } else {
      let span = current.first_timestamp_us - since
      let preceding = span / gap + (if span % gap == 0L { 0L } else { 1L })
      if preceding > observations ||
        current.input_frames > observations - preceding {
        raise @types.InvalidInput(
          "footprint window and preceding health samples exceed the exact count",
        )
      }
    }
  }
}

///|
/// Join original guard, run and window invariants with saved paired health
/// samples. These are necessary local facts, not authenticated full history.
pub fn FootprintRunWindowGuardedSession::from_checkpoint(
  saved : FootprintRunWindowGuardedCheckpoint,
) -> FootprintRunWindowGuardedSession raise @types.GroundError {
  if saved.version != 1 {
    raise @types.InvalidInput(
      "unsupported guarded footprint run window checkpoint version",
    )
  }
  let analysis = @analysis.FootprintRunWindowSession::from_checkpoint(
    saved.analysis,
  )
  let health = @health.CalibrationMonitor::from_checkpoint(saved.health)
  let original = analysis.checkpoint()
  let evidence = health.checkpoint()
  guard original.measurement is @analysis.Pixel(pixel) else {
    raise @types.InvalidInput(
      "guarded footprint windows require pixel measurement",
    )
  }
  let max_tracks = validate_guard_binding(
    pixel,
    evidence,
    health.status(),
    original.windows.runs.max_tracks,
    original.windows.runs.states.length(),
  )
  validate_guarded_run_history(pixel, evidence, original.windows.runs)
  validate_footprint_health_windows(pixel, evidence, original.windows)
  { analysis, health, max_tracks, last_timestamp: evidence.last_timestamp_us, }
}
