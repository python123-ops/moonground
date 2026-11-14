///|
pub fn FootprintRunMonitor::checkpoint(
  self : FootprintRunMonitor,
) -> FootprintRunCheckpoint {
  {
    version: 1,
    session_id: self.projector.session_id,
    zones: self.projector.zones.copy(),
    max_tracks: self.projector.max_tracks,
    config: self.config,
    last_timestamp_us: self.last_timestamp,
    states: self.states.copy(),
  }
}

///|
pub fn FootprintRunMonitor::fork(
  self : FootprintRunMonitor,
) -> FootprintRunMonitor {
  {
    projector: self.projector,
    config: self.config,
    last_timestamp: self.last_timestamp,
    states: self.states.copy(),
  }
}

///|
fn same_run_anchor(a : FootprintRunState, b : FootprintRunState) -> Bool {
  a.last_position_m.x == b.last_position_m.x &&
  a.last_position_m.y == b.last_position_m.y &&
  a.last_position_covariance.xx == b.last_position_covariance.xx &&
  a.last_position_covariance.xy == b.last_position_covariance.xy &&
  a.last_position_covariance.yy == b.last_position_covariance.yy
}

///|
fn validate_run_samples(
  run : FootprintRun,
  timestamp : Int64,
  config : FootprintRunConfig,
) -> Unit raise @types.GroundError {
  if run.track_id <= 0 ||
    run.first_timestamp_us < 0L ||
    run.first_timestamp_us > run.last_timestamp_us ||
    run.last_timestamp_us != timestamp ||
    run.sample_count <= 0L ||
    run.decision is Indeterminate {
    raise @types.InvalidInput("invalid footprint run identity time or decision")
  }
  validate_zone_segment(run.segment_id)
  let span = run.last_timestamp_us - run.first_timestamp_us
  let intervals = run.sample_count - 1L
  if run.sample_span_us != span ||
    intervals > span ||
    run.confirmed !=
    (run.sample_count >= config.min_samples && span >= config.confirmation_us) {
    raise @types.InvalidInput("inconsistent footprint run span or confirmation")
  }
  if intervals == 0L {
    if span != 0L {
      raise @types.InvalidInput("one footprint run sample must have zero span")
    }
  } else {
    let gap = config.max_gap_us - 1L
    // ceil(span / intervals) <= gap, without an overflowing product or sum.
    if gap == 0L ||
      span / intervals > gap ||
      (span / intervals == gap && span % intervals != 0L) {
      raise @types.InvalidInput(
        "footprint run samples cannot satisfy the maximum gap",
      )
    }
  }
}

///|
pub fn FootprintRunMonitor::from_checkpoint(
  checkpoint : FootprintRunCheckpoint,
) -> FootprintRunMonitor raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput("unsupported footprint run checkpoint version")
  }
  let config = FootprintRunConfig::new(
    max_gap_us=checkpoint.config.max_gap_us,
    confirmation_us=checkpoint.config.confirmation_us,
    min_samples=checkpoint.config.min_samples,
  )
  let restored = FootprintRunMonitor::new(
    checkpoint.session_id,
    checkpoint.zones,
    config,
    max_tracks=checkpoint.max_tracks,
  )
  if checkpoint.states.length() >
    checkpoint.max_tracks * checkpoint.zones.length() {
    raise @types.InvalidInput(
      "footprint run checkpoint exceeds its state capacity",
    )
  }
  let timestamp = match checkpoint.last_timestamp_us {
    None => {
      if !checkpoint.states.is_empty() {
        raise @types.InvalidInput(
          "unstarted footprint run checkpoint has retained states",
        )
      }
      return restored
    }
    Some(timestamp) => {
      if timestamp < 0L {
        raise @types.InvalidInput("negative footprint run checkpoint timestamp")
      }
      timestamp
    }
  }
  let zone_order : Map[String, Int32] = Map([])
  for index, zone in restored.projector.zones {
    zone_order[zone.zone_id] = index
  }
  let states : Map[String, FootprintRunState] = Map([])
  let targets : Map[Int32, FootprintRunState] = Map([])
  let segments : Map[String, Int32] = Map([])
  for state in checkpoint.states {
    let run = state.run
    validate_run_samples(run, timestamp, config)
    let key = footprint_run_key(run.track_id, run.zone_id)
    if !zone_order.contains(run.zone_id) || states.contains(key) {
      raise @types.InvalidInput(
        "unknown or duplicate footprint run zone identity",
      )
    }
    match segments.get(run.segment_id) {
      Some(track_id) if track_id != run.track_id =>
        raise @types.InvalidInput(
          "footprint run segment belongs to multiple targets",
        )
      _ => segments[run.segment_id] = run.track_id
    }
    match targets.get(run.track_id) {
      Some(previous) =>
        if previous.run.segment_id != run.segment_id ||
          !same_run_anchor(previous, state) ||
          !same_run_shape(previous.shape, state.shape) {
          raise @types.InvalidInput(
            "footprint run target has inconsistent shape or current anchor",
          )
        }
      None => {
        if targets.length() >= checkpoint.max_tracks {
          raise @types.InvalidInput(
            "footprint run checkpoint exceeds its target capacity",
          )
        }
        targets[run.track_id] = state
      }
    }
    states[key] = state
  }
  // A saved target's current anchor must account for every definite zone.
  // This validates local evidence, without reconstructing its historical samples.
  for track_id, anchor in targets {
    for zone in restored.projector.zones {
      let decision = match anchor.shape {
        Disk(shape) =>
          zone.evaluate_disk(
            anchor.last_position_m,
            anchor.last_position_covariance,
            shape,
          ).decision
        Convex(shape) =>
          zone.evaluate_footprint(
            anchor.last_position_m,
            anchor.last_position_covariance,
            shape,
          ).decision
      }
      let stored = states.get(footprint_run_key(track_id, zone.zone_id))
      match (decision, stored) {
        (Indeterminate, None) => ()
        (Indeterminate, Some(_)) =>
          raise @types.InvalidInput(
            "indeterminate footprint evidence cannot retain a run",
          )
        (_, Some(state)) if state.run.decision == decision => ()
        _ =>
          raise @types.InvalidInput(
            "footprint run checkpoint omits or contradicts current evidence",
          )
      }
    }
  }
  let detached = checkpoint.states.copy()
  detached.sort_by((a, b) => {
    let order = a.run.track_id.compare(b.run.track_id)
    if order == 0 {
      zone_order[a.run.zone_id].compare(zone_order[b.run.zone_id])
    } else {
      order
    }
  })
  restored.states = detached
  restored.last_timestamp = Some(timestamp)
  restored
}
