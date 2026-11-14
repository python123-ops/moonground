///|
// Match motion.maximum_direction_std's exact operation order on the upper
// velocity block, just as position_deviation does for the position block.
fn footprint_run_velocity_deviation(track : @motion.TrackCheckpoint) -> Double {
  let scale = track.covariance[10].max(track.covariance[15])
  let xx = track.covariance[10] / scale
  let yy = track.covariance[15] / scale
  let xy = track.covariance[11] / scale
  let dx = (xx - yy) / 2.0
  let radial_scale = dx.abs().max(xy.abs())
  let radius = if radial_scale == 0.0 {
    0.0
  } else {
    let nx = dx / radial_scale
    let ny = xy / radial_scale
    radial_scale * (nx * nx + ny * ny).sqrt()
  }
  scale.sqrt() * ((xx + yy) / 2.0 + radius).sqrt()
}

///|
fn validate_footprint_run_pair(
  motion : @motion.MotionCheckpoint,
  runs : @zones.FootprintRunCheckpoint,
) -> Unit raise @types.GroundError {
  if motion.session_id != runs.session_id ||
    motion.last_timestamp_us != runs.last_timestamp_us {
    raise @types.InvalidInput(
      "footprint run session or committed watermark differs",
    )
  }
  let tracks : Map[Int32, @motion.TrackCheckpoint] = Map([])
  for track in motion.tracks {
    tracks[track.track_id] = track
  }
  let known : Map[Int32, Map[Int64, Bool]] = Map([])
  for state in runs.states {
    let run = state.run
    guard tracks.get(run.track_id) is Some(track) &&
      motion.last_timestamp_us == Some(track.last_timestamp_us) else {
      raise @types.InvalidInput(
        "footprint run does not have a current accepted motion sample",
      )
    }
    let config = motion.config
    if run.segment_id != track.segment_id.to_string() ||
      track.accepted_count < config.min_observations ||
      track.last_timestamp_us - track.first_timestamp_us < config.min_span_us ||
      (
        config.max_position_std_m is Some(limit) &&
        position_deviation(track) > limit
      ) ||
      (
        config.max_velocity_std_mps is Some(limit) &&
        footprint_run_velocity_deviation(track) > limit
      ) {
      raise @types.InvalidInput(
        "footprint run motion is not Ready or has a different segment",
      )
    }
    let covariance = track.covariance
    if !same_point(state.last_position_m, track.last_filtered) ||
      state.last_position_covariance.xx != covariance[0] ||
      state.last_position_covariance.xy != covariance[1] ||
      state.last_position_covariance.yy != covariance[5] {
      raise @types.InvalidInput(
        "footprint run current point or upper covariance differs from motion",
      )
    }
    let warmup = (config.min_observations - 1).to_int64()
    if run.first_timestamp_us < track.first_timestamp_us ||
      run.first_timestamp_us > track.last_timestamp_us ||
      run.first_timestamp_us - track.first_timestamp_us < config.min_span_us ||
      run.first_timestamp_us - track.first_timestamp_us < warmup {
      raise @types.InvalidInput(
        "footprint run begins before its segment could be Ready",
      )
    }
    let times = match known.get(run.track_id) {
      Some(times) => times
      None => {
        let times : Map[Int64, Bool] = Map([])
        times[track.first_timestamp_us] = true
        times[track.last_timestamp_us] = true
        known[run.track_id] = times
        times
      }
    }
    times[run.first_timestamp_us] = true
  }
  for track_id, times in known {
    if times.length() > tracks[track_id].accepted_count {
      raise @types.InvalidInput(
        "footprint run witnesses exceed accepted motion samples",
      )
    }
  }
  for state in runs.states {
    let run = state.run
    let track = tracks[run.track_id]
    let mut earlier = 0L
    let mut included = 0L
    for timestamp, _ in known[run.track_id] {
      if timestamp < run.first_timestamp_us {
        earlier += 1L
      } else {
        included += 1L
      }
    }
    let warmup = (motion.config.min_observations - 1).to_int64()
    let prefix = earlier.max(warmup)
    if run.sample_count < included ||
      run.sample_count > track.accepted_count.to_int64() - prefix {
      raise @types.InvalidInput(
        "footprint run samples exceed the remaining accepted sample budget",
      )
    }
  }
}

///|
/// Validate saved local relationships, not an authenticated observation history.
pub fn FootprintRunSession::from_checkpoint(
  checkpoint : FootprintRunSessionCheckpoint,
) -> FootprintRunSession raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput(
      "unsupported footprint run session checkpoint version",
    )
  }
  let runs = @zones.FootprintRunMonitor::from_checkpoint(checkpoint.runs)
  let (measurement, motion) = match checkpoint.measurement {
    Pixel(snapshot) => {
      let session = @moonground.MeasurementSession::from_checkpoint(snapshot)
      (MeasurementEngine::Pixel(session), session.checkpoint().motion)
    }
    Ground(snapshot) => {
      let estimator = @motion.MotionEstimator::from_checkpoint(snapshot)
      (MeasurementEngine::Ground(estimator), estimator.checkpoint())
    }
  }
  validate_footprint_run_pair(motion, runs.checkpoint())
  { measurement, runs, last_timestamp: motion.last_timestamp_us, }
}
