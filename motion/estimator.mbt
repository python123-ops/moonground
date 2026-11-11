///|
struct TrackState {
  track_id : Int32
  segment_id : Int64
  first_timestamp_us : Int64
  last_timestamp_us : Int64
  accepted_count : Int32
  state : Array[Double]
  covariance : @kalman.Matrix
  first_filtered : @types.Point2
  last_filtered : @types.Point2
  observed_path_length_m : Double
}

///|
/// Bounded per-session state. Frame validation precedes all mutable work;
/// candidates are committed only after the complete frame succeeds.
pub struct MotionEstimator {
  session_id : String
  config : MotionConfig
  mut tracks : Map[Int32, TrackState]
  mut last_timestamp : Int64?
  mut next_segment : Int64
}

///|
pub fn MotionEstimator::new(
  session_id : String,
  config : MotionConfig,
) -> MotionEstimator raise @types.GroundError {
  if session_id.length() == 0 {
    raise @types.InvalidInput("session_id must not be empty")
  }
  {
    session_id,
    config,
    tracks: Map([]),
    last_timestamp: None,
    next_segment: 1L,
  }
}

///|
pub fn MotionEstimator::active_track_count(self : MotionEstimator) -> Int32 {
  self.tracks.length()
}

///|
pub fn MotionEstimator::last_timestamp_us(self : MotionEstimator) -> Int64? {
  self.last_timestamp
}

///|
fn validate_ids(
  ids : Array[Int32],
  seen : Map[Int32, Bool],
) -> Unit raise @types.GroundError {
  for id in ids {
    if id <= 0 || seen.contains(id) {
      raise @types.InvalidInput(
        "duplicate, conflicting, or nonpositive track identity",
      )
    }
    seen[id] = true
  }
}

///|
fn initial_track(
  observation : @types.GroundObservation,
  timestamp_us : Int64,
  segment_id : Int64,
  config : MotionConfig,
) -> TrackState {
  let r = observation.covariance
  let vv = config.initial_velocity_std * config.initial_velocity_std
  {
    track_id: observation.track_id,
    segment_id,
    first_timestamp_us: timestamp_us,
    last_timestamp_us: timestamp_us,
    accepted_count: 1,
    state: [observation.position.x, observation.position.y, 0.0, 0.0],
    covariance: @kalman.Matrix::from_rows([
      [r.xx, r.xy, 0.0, 0.0],
      [r.xy, r.yy, 0.0, 0.0],
      [0.0, 0.0, vv, 0.0],
      [0.0, 0.0, 0.0, vv],
    ]),
    first_filtered: observation.position,
    last_filtered: observation.position,
    observed_path_length_m: 0.0,
  }
}

///|
fn make_estimate(track : TrackState, status : MotionStatus) -> TrackEstimate {
  let accepted = status is Initializing || status is Ready
  let ready = status is Ready
  {
    track_id: track.track_id,
    segment_id: track.segment_id.to_string(),
    status,
    position: if accepted {
      Some({ x: track.state[0], y: track.state[1], })
    } else {
      None
    },
    position_covariance: if accepted {
      covariance_block(track.covariance, 0)
    } else {
      None
    },
    velocity: if ready {
      Some({ x: track.state[2], y: track.state[3], })
    } else {
      None
    },
    velocity_covariance: if ready {
      covariance_block(track.covariance, 2)
    } else {
      None
    },
    speed_mps: if ready {
      Some(norm2(track.state[2], track.state[3]))
    } else {
      None
    },
    observed_path_length_m: track.observed_path_length_m,
    net_displacement_m: norm2(
      track.last_filtered.x - track.first_filtered.x,
      track.last_filtered.y - track.first_filtered.y,
    ),
    accepted_count: track.accepted_count,
    last_accepted_timestamp_us: track.last_timestamp_us,
    filtered_state: if accepted {
      Some(track.state.copy())
    } else {
      None
    },
    filtered_covariance: if accepted {
      Some(flatten_covariance(track.covariance))
    } else {
      None
    },
  }
}

///|
fn readiness(track : TrackState, config : MotionConfig) -> MotionStatus {
  if track.accepted_count >= config.min_observations &&
    track.last_timestamp_us - track.first_timestamp_us >= config.min_span_us {
    Ready
  } else {
    Initializing
  }
}

///|
fn advance_track(
  previous : TrackState,
  observation : @types.GroundObservation,
  timestamp_us : Int64,
  config : MotionConfig,
) -> (TrackState, MotionStatus) raise @types.GroundError {
  let dt = (timestamp_us - previous.last_timestamp_us).to_double() / 1000000.0
  let transition = @kalman.constant_velocity_transition(2, dt)
  let process = process_matrix(dt, config.acceleration_spectral_density)
  let measurement = measurement_matrix(observation.covariance)
  if !transition.is_finite() || !process.is_finite() {
    return (previous, NumericalFailure)
  }
  let candidate = @kalman.KalmanND::new(
    previous.state,
    previous.covariance.to_rows(),
    process.to_rows(),
    measurement.to_rows(),
    transition.to_rows(),
    observation_matrix().to_rows(),
  )
  candidate.set_gate_threshold(config.innovation_gate)
  candidate.predict()
  if !healthy_state(candidate.state(), candidate.covariance()) {
    return (previous, NumericalFailure)
  }
  let report = candidate.update_and_report([
    observation.position.x,
    observation.position.y,
  ])
  if !@types.is_finite(report.nis()) {
    return (previous, NumericalFailure)
  }
  match report.result() {
    @kalman.RejectedByGate => (previous, RejectedInnovation)
    @kalman.Accepted => {
      let state = candidate.state()
      let covariance = candidate.covariance()
      let step = norm2(
        state[0] - previous.last_filtered.x,
        state[1] - previous.last_filtered.y,
      )
      let path = previous.observed_path_length_m + step
      let displacement = norm2(
        state[0] - previous.first_filtered.x,
        state[1] - previous.first_filtered.y,
      )
      if !healthy_state(state, covariance) ||
        !@types.is_finite(path) ||
        !@types.is_finite(displacement) ||
        covariance_block(covariance, 0) is None ||
        covariance_block(covariance, 2) is None ||
        !@types.is_finite(norm2(state[2], state[3])) {
        return (previous, NumericalFailure)
      }
      if previous.accepted_count == 2147483647 {
        raise @types.InvalidInput("accepted observation counter exhausted")
      }
      let next = {
        ..previous,
        last_timestamp_us: timestamp_us,
        accepted_count: previous.accepted_count + 1,
        state,
        covariance,
        last_filtered: { x: state[0], y: state[1], },
        observed_path_length_m: path,
      }
      (next, readiness(next, config))
    }
    _ => (previous, NumericalFailure)
  }
}

///|
/// Apply one globally increasing frame atomically. Missing tracks produce no
/// prediction output. Lost/removed identities and accepted-observation gaps at
/// least max_gap_us close and release the segment without retaining tombstones.
pub fn MotionEstimator::update(
  self : MotionEstimator,
  timestamp_us : Int64,
  observations : Array[@types.GroundObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> FrameResult raise @types.GroundError {
  if timestamp_us < 0L {
    raise @types.InvalidInput("timestamp_us must be nonnegative")
  }
  if self.last_timestamp is Some(previous) && timestamp_us <= previous {
    raise @types.InvalidInput("frame timestamps must strictly increase")
  }
  if observations.length() > self.config.max_tracks ||
    lost.length() > self.config.max_tracks ||
    removed.length() > self.config.max_tracks {
    raise @types.InvalidInput("frame identity limit exceeded")
  }
  let seen : Map[Int32, Bool] = Map([])
  let ordered = observations.copy()
  ordered.sort_by((a, b) => a.track_id.compare(b.track_id))
  for observation in ordered {
    observation.validate()
    validate_ids([observation.track_id], seen)
  }
  validate_ids(lost, seen)
  validate_ids(removed, seen)
  let closing : Map[Int32, Bool] = Map([])
  for id in lost {
    closing[id] = true
  }
  for id in removed {
    closing[id] = true
  }
  let staged : Map[Int32, TrackState] = Map([])
  let closed : Array[Int64] = []
  for id, track in self.tracks {
    if closing.contains(id) ||
      timestamp_us - track.last_timestamp_us >= self.config.max_gap_us {
      closed.push(track.segment_id)
    } else {
      staged[id] = track
    }
  }
  let results : Array[TrackEstimate] = []
  let mut next_segment = self.next_segment
  for observation in ordered {
    match staged.get(observation.track_id) {
      Some(previous) => {
        let (next, status) = advance_track(
          previous,
          observation,
          timestamp_us,
          self.config,
        )
        staged[observation.track_id] = next
        results.push(make_estimate(next, status))
      }
      None => {
        if staged.length() >= self.config.max_tracks {
          raise @types.InvalidInput("active track capacity exceeded")
        }
        if next_segment == 9223372036854775807L {
          raise @types.InvalidInput("segment identity counter exhausted")
        }
        let initial = initial_track(
          observation,
          timestamp_us,
          next_segment,
          self.config,
        )
        if !healthy_state(initial.state, initial.covariance) {
          results.push(make_estimate(initial, NumericalFailure))
        } else {
          staged[observation.track_id] = initial
          results.push(make_estimate(initial, Initializing))
        }
        next_segment = next_segment + 1L
      }
    }
  }
  results.sort_by((a, b) => a.track_id.compare(b.track_id))
  closed.sort()
  self.tracks = staged
  self.last_timestamp = Some(timestamp_us)
  self.next_segment = next_segment
  {
    session_id: self.session_id,
    timestamp_us,
    tracks: results,
    closed_segment_ids: closed.map(id => id.to_string()),
  }
}
