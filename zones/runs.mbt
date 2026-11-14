///|
pub fn FootprintRunMonitor::new(
  session_id : String,
  zones : Array[ConvexZone],
  config : FootprintRunConfig,
  max_tracks~ : Int32 = 1000,
) -> FootprintRunMonitor raise @types.GroundError {
  {
    projector: ZoneProjector::new(session_id, zones, max_tracks~),
    config,
    last_timestamp: None,
    states: [],
  }
}

///|
fn footprint_run_key(track_id : Int32, zone_id : String) -> String {
  track_id.to_string() + ":" + zone_id
}

///|
fn same_run_shape(a : FootprintShape, b : FootprintShape) -> Bool {
  match (a, b) {
    (Disk(x), Disk(y)) => x.radius_m == y.radius_m
    (Convex(x), Convex(y)) => {
      if x.vertices.length() != y.vertices.length() {
        return false
      }
      for index, point in x.vertices {
        let other = y.vertices[index]
        if point.x != other.x || point.y != other.y {
          return false
        }
      }
      true
    }
    _ => false
  }
}

///|
fn assigned_run_decision(band : AssignedFootprintBand) -> ZoneDecision {
  match band {
    Disk(disk) => disk.decision
    Convex(convex) => convex.decision
  }
}

///|
fn assigned_run_zone(band : AssignedFootprintBand) -> String {
  match band {
    Disk(disk) => disk.zone_id
    Convex(convex) => convex.zone_id
  }
}

///|
fn make_footprint_run(
  zone_id : String,
  track_id : Int32,
  segment_id : String,
  decision : ZoneDecision,
  first_timestamp_us : Int64,
  last_timestamp_us : Int64,
  sample_count : Int64,
  config : FootprintRunConfig,
) -> FootprintRun {
  let sample_span_us = last_timestamp_us - first_timestamp_us
  {
    zone_id,
    track_id,
    segment_id,
    decision,
    first_timestamp_us,
    last_timestamp_us,
    sample_count,
    sample_span_us,
    confirmed: sample_count >= config.min_samples &&
    sample_span_us >= config.confirmation_us,
  }
}

///|
pub fn FootprintRunMonitor::update(
  self : FootprintRunMonitor,
  frame : @motion.FrameResult,
  assignments : FootprintAssignments,
) -> FootprintRunFrame raise @types.GroundError {
  let evidence = self.projector.evaluate_assigned(frame, assignments)
  let timestamp = frame.timestamp_us
  if self.last_timestamp is Some(previous) && timestamp <= previous {
    raise @types.InvalidInput("footprint run timestamps must strictly increase")
  }
  let gap = match self.last_timestamp {
    Some(previous) => timestamp - previous >= self.config.max_gap_us
    None => false
  }
  let reported : Map[Int32, @motion.TrackEstimate] = Map([])
  for track in frame.tracks {
    reported[track.track_id] = track
  }
  let assigned : Map[Int32, FootprintShape] = Map([])
  for assignment in assignments.assignments {
    assigned[assignment.track_id] = assignment.shape
  }
  let current : Map[String, ZoneDecision] = Map([])
  for row in evidence.evidence {
    current[footprint_run_key(row.track_id, assigned_run_zone(row.evidence))] = assigned_run_decision(
      row.evidence,
    )
  }
  let closed_segments : Map[String, Bool] = Map([])
  for segment in frame.closed_segment_ids {
    closed_segments[segment] = true
  }
  let continuing : Map[String, FootprintRunState] = Map([])
  let closed : Array[ClosedFootprintRun] = []
  for state in self.states {
    let run = state.run
    let key = footprint_run_key(run.track_id, run.zone_id)
    let reason : FootprintRunEndReason? = if gap {
      Some(GapExceeded)
    } else if closed_segments.contains(run.segment_id) {
      Some(SegmentClosed)
    } else {
      match reported.get(run.track_id) {
        None => Some(MissingTarget)
        Some(track) =>
          if track.segment_id != run.segment_id {
            Some(SegmentChanged)
          } else if current.get(key) is None {
            Some(UnavailableEvidence)
          } else {
            match assigned.get(run.track_id) {
              None => Some(UnavailableEvidence)
              Some(shape) =>
                if !same_run_shape(state.shape, shape) {
                  Some(ShapeChanged)
                } else {
                  match current.get(key) {
                    Some(Indeterminate) => Some(IndeterminateEvidence)
                    Some(decision) if decision != run.decision =>
                      Some(DecisionChanged)
                    _ => None
                  }
                }
            }
          }
      }
    }
    match reason {
      Some(reason) =>
        closed.push({ run, closed_at_timestamp_us: timestamp, reason, })
      None => continuing[key] = state
    }
  }
  let active : Array[FootprintRun] = []
  let confirmed : Array[FootprintRun] = []
  let states : Array[FootprintRunState] = []
  for row in evidence.evidence {
    let decision = assigned_run_decision(row.evidence)
    if decision is Indeterminate {
      continue
    }
    let zone_id = assigned_run_zone(row.evidence)
    let key = footprint_run_key(row.track_id, zone_id)
    let previous = continuing.get(key)
    let (first_timestamp, sample_count) = match previous {
      None => (timestamp, 1L)
      Some(state) => {
        if state.run.sample_count == 9223372036854775807L {
          raise @types.InvalidInput(
            "footprint run sample count overflows Int64",
          )
        }
        (state.run.first_timestamp_us, state.run.sample_count + 1L)
      }
    }
    let run = make_footprint_run(
      zone_id,
      row.track_id,
      row.segment_id,
      decision,
      first_timestamp,
      timestamp,
      sample_count,
      self.config,
    )
    if run.confirmed && !(previous is Some(state) && state.run.confirmed) {
      confirmed.push(run)
    }
    active.push(run)
    // Ready admission and exact assignments were checked by evaluate_assigned.
    let track = reported[row.track_id]
    guard track.position is Some(point) &&
      track.position_covariance is Some(covariance) else {
      raise @types.InvalidInput("ready footprint run anchor is missing")
    }
    states.push({
      run,
      shape: assigned[row.track_id],
      last_position_m: point,
      last_position_covariance: covariance,
    })
  }
  self.states = states
  self.last_timestamp = Some(timestamp)
  { evidence, active, confirmed, closed, }
}
