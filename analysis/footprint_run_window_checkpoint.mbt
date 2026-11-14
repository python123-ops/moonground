///|
fn add_footprint_window_time(
  timestamp : Int64,
  windows : @zones.FootprintRunWindowCheckpoint,
  known : Map[Int64, Bool],
) -> Unit raise @types.GroundError {
  if windows.baseline_timestamp_us is None && timestamp < windows.origin_us {
    raise @types.InvalidInput(
      "accepted footprint observation predates the window origin",
    )
  }
  if windows.baseline_timestamp_us is Some(baseline) && timestamp <= baseline {
    return
  }
  if windows.current_window is Some(current) && timestamp >= current.start_us {
    if timestamp < current.first_timestamp_us {
      raise @types.InvalidInput("footprint window omits a saved accepted input")
    }
    known[timestamp] = true
    if known.length().to_int64() > current.input_frames {
      raise @types.InvalidInput(
        "footprint window has fewer frames than saved accepted times",
      )
    }
  }
}

///|
fn validate_footprint_window_inputs(
  motion : @motion.MotionCheckpoint,
  windows : @zones.FootprintRunWindowCheckpoint,
) -> Unit raise @types.GroundError {
  let known : Map[Int64, Bool] = Map([])
  let anchors : Map[Int64, Int64] = Map([])
  if windows.current_window is Some(current) {
    known[current.first_timestamp_us] = true
    known[current.last_timestamp_us] = true
    anchors[current.first_timestamp_us] = current.input_frames
    anchors[current.last_timestamp_us] = 1L
  }
  for track in motion.tracks {
    add_footprint_window_time(track.first_timestamp_us, windows, known)
    add_footprint_window_time(track.last_timestamp_us, windows, known)
  }
  for state in windows.runs.states {
    add_footprint_window_time(state.run.first_timestamp_us, windows, known)
    if windows.current_window is Some(current) &&
      state.run.first_timestamp_us >= current.first_timestamp_us {
      anchors[state.run.first_timestamp_us] = state.run.sample_count
    }
  }
  guard windows.current_window is Some(current) else { return }
  let times = known.keys().collect()
  times.sort()
  let indices : Map[Int64, Int32] = Map([])
  // For each known time, bound its suffix above and the suffix after it below.
  // Only v29 anchors give exact suffix counts; other witnesses merely prove
  // that one input occupies that timestamp.
  let left_upper : Array[Int64] = Array::make(times.length(), 0L)
  let after_lower : Array[Int64] = Array::make(times.length(), 0L)
  let mut previous_count = current.input_frames
  let mut previous_index = 0
  for index, timestamp in times {
    indices[timestamp] = index
    match anchors.get(timestamp) {
      Some(count) => {
        if index > previous_index &&
          previous_count - count < (index - previous_index).to_int64() {
          raise @types.InvalidInput(
            "saved accepted inputs exceed a footprint window suffix interval",
          )
        }
        previous_count = count
        previous_index = index
        left_upper[index] = count
      }
      None => left_upper[index] = previous_count - 1L
    }
  }
  let mut following_count = 1L
  for index = times.length() - 1; index >= 0; index = index - 1 {
    match anchors.get(times[index]) {
      Some(count) => {
        following_count = count
        after_lower[index] = count - 1L
      }
      None => after_lower[index] = following_count
    }
  }
  let cutoff = match windows.baseline_timestamp_us {
    Some(baseline) if baseline >= current.start_us => baseline + 1L
    _ => current.start_us
  }
  for track in motion.tracks {
    if track.last_timestamp_us < cutoff {
      continue
    }
    let outside_slots = if cutoff > track.first_timestamp_us {
      cutoff - track.first_timestamp_us
    } else {
      0L
    }
    let accepted = track.accepted_count.to_int64()
    if accepted <= outside_slots {
      continue
    }
    let necessary = accepted - outside_slots
    let left = track.first_timestamp_us.max(current.first_timestamp_us)
    let right = track.last_timestamp_us
    let upper = left_upper[indices[left]]
    let lower = after_lower[indices[right]]
    if upper < lower {
      raise @types.InvalidInput(
        "footprint window accepted interval has no possible input budget",
      )
    }
    let mut capacity = upper - lower
    let span = right - left
    // Avoid forming span+1 when the represented interval is [0, Int64MAX].
    if capacity > 0L && capacity - 1L > span {
      capacity = span + 1L
    }
    if necessary > capacity {
      raise @types.InvalidInput(
        "accepted footprint samples exceed their window interval budget",
      )
    }
  }
}

///|
/// Restore each original component, then validate saved accepted samples against
/// the window's exact suffix counts. Historical observations are not replayed.
pub fn FootprintRunWindowSession::from_checkpoint(
  saved : FootprintRunWindowSessionCheckpoint,
) -> FootprintRunWindowSession raise @types.GroundError {
  if saved.version != 1 {
    raise @types.InvalidInput(
      "unsupported footprint run window session checkpoint version",
    )
  }
  let windows = @zones.FootprintRunWindowMonitor::from_checkpoint(saved.windows)
  let (measurement, motion) = match saved.measurement {
    Pixel(snapshot) => {
      let session = @moonground.MeasurementSession::from_checkpoint(snapshot)
      (MeasurementEngine::Pixel(session), session.checkpoint().motion)
    }
    Ground(snapshot) => {
      let estimator = @motion.MotionEstimator::from_checkpoint(snapshot)
      (MeasurementEngine::Ground(estimator), estimator.checkpoint())
    }
  }
  let canonical = windows.checkpoint()
  validate_footprint_run_pair(motion, canonical.runs)
  validate_footprint_window_inputs(motion, canonical)
  { measurement, windows, last_timestamp: motion.last_timestamp_us, }
}
