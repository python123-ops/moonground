///|
fn validate_guarded_run_history(
  pixel : @moonground.MeasurementCheckpoint,
  health : @health.HealthCheckpoint,
  runs : @zones.FootprintRunCheckpoint,
) -> Unit raise @types.GroundError {
  let accepted : Map[Int32, Int64] = Map([])
  let known : Map[Int32, Map[Int64, Bool]] = Map([])
  for track in pixel.motion.tracks {
    accepted[track.track_id] = track.accepted_count.to_int64()
    let times : Map[Int64, Bool] = Map([])
    times[track.first_timestamp_us] = true
    times[track.last_timestamp_us] = true
    known[track.track_id] = times
  }
  for state in runs.states {
    let run = state.run
    validate_guard_accepted_time(
      run.first_timestamp_us,
      health,
      pixel.motion.config.max_gap_us,
    )
    validate_guard_accepted_time(
      run.last_timestamp_us,
      health,
      pixel.motion.config.max_gap_us,
    )
    // The v27 restore already bound this target to a current Ready segment.
    let times = known[run.track_id]
    times[run.first_timestamp_us] = true
    if health.streak is Some(streak) &&
      run.first_timestamp_us <= streak.since_us {
      // This particular retained run proves that the target was accepted at
      // the health restart frame. A merely retained motion segment does not.
      times[streak.since_us] = true
      if run.first_timestamp_us < streak.since_us {
        let health_gap = health.config.max_gap_us
        if runs.config.max_gap_us <= health_gap ||
          run.sample_count < 2L ||
          run.sample_count - 2L > run.sample_span_us - health_gap {
          raise @types.InvalidInput(
            "guarded footprint run cannot cross the saved health restart gap",
          )
        }
      }
    }
  }
  for track_id, times in known {
    if times.length().to_int64() > accepted[track_id] {
      raise @types.InvalidInput(
        "guarded footprint run health witnesses exceed accepted motion samples",
      )
    }
  }
  let warmup = (pixel.motion.config.min_observations - 1).to_int64()
  for state in runs.states {
    let run = state.run
    let mut before = 0L
    let mut included = 0L
    for timestamp, _ in known[run.track_id] {
      if timestamp < run.first_timestamp_us {
        before += 1L
      } else {
        included += 1L
      }
    }
    if run.sample_count < included ||
      run.sample_count > accepted[run.track_id] - before.max(warmup) {
      raise @types.InvalidInput(
        "guarded footprint run samples contradict saved accepted health witnesses",
      )
    }
  }
}

///|
pub fn FootprintRunGuardedSession::from_checkpoint(
  checkpoint : FootprintRunGuardedCheckpoint,
) -> FootprintRunGuardedSession raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput(
      "unsupported guarded footprint run checkpoint version",
    )
  }
  let analysis = @analysis.FootprintRunSession::from_checkpoint(
    checkpoint.analysis,
  )
  let health = @health.CalibrationMonitor::from_checkpoint(checkpoint.health)
  guard checkpoint.analysis.measurement is @analysis.Pixel(pixel) else {
    raise @types.InvalidInput(
      "guarded footprint runs require pixel measurement",
    )
  }
  let max_tracks = validate_guard_binding(
    pixel,
    checkpoint.health,
    health.status(),
    checkpoint.analysis.runs.max_tracks,
    checkpoint.analysis.runs.states.length(),
  )
  validate_guarded_run_history(
    pixel,
    checkpoint.health,
    checkpoint.analysis.runs,
  )
  {
    analysis,
    health,
    max_tracks,
    last_timestamp: checkpoint.health.last_timestamp_us,
  }
}
