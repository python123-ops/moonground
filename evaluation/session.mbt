///|
priv struct EvaluationState {
  counts : EvaluationCounts
  first_timestamp_us : Int64?
  last_timestamp_us : Int64?
  position : ErrorAccumulator
  speed : ErrorAccumulator
  bias_x : Double
  bias_y : Double
  bias_speed : Double
}

///|
/// Constant retained state; maps are bounded scratch space for one frame.
/// A failed frame commits no counters, statistics or timestamp watermark.
pub struct EvaluationSession {
  priv session_id : String
  priv max_tracks : Int32
  priv max_samples : Int32
  priv mut state : EvaluationState
}

///|
pub fn EvaluationSession::new(
  session_id : String,
  max_tracks~ : Int32 = 4096,
  max_samples~ : Int32 = 10000000,
) -> EvaluationSession raise @types.GroundError {
  if session_id.length() < 1 ||
    session_id.length() > 128 ||
    max_tracks < 1 ||
    max_tracks > 4096 ||
    max_samples < 1 {
    raise @types.InvalidInput("invalid evaluation identity or capacity")
  }
  {
    session_id,
    max_tracks,
    max_samples,
    state: {
      counts: {
        frames: 0L,
        references: 0,
        speed_references: 0,
        measurements: 0,
        without_reference: 0,
        missing: 0,
        initializing: 0,
        ready: 0,
        uncertain: 0,
        rejected_innovation: 0,
        numerical_failure: 0,
        rejected_projection: 0,
      },
      first_timestamp_us: None,
      last_timestamp_us: None,
      position: ErrorAccumulator::empty(),
      speed: ErrorAccumulator::empty(),
      bias_x: 0.0,
      bias_y: 0.0,
      bias_speed: 0.0,
    },
  }
}

///|
/// Independent continuation, sharing no mutable arrays or maps.
pub fn EvaluationSession::fork(self : EvaluationSession) -> EvaluationSession {
  {
    session_id: self.session_id,
    max_tracks: self.max_tracks,
    max_samples: self.max_samples,
    state: self.state,
  }
}

///|
pub fn EvaluationSession::report(self : EvaluationSession) -> EvaluationReport {
  let state = self.state
  {
    session_id: self.session_id,
    first_timestamp_us: state.first_timestamp_us,
    last_timestamp_us: state.last_timestamp_us,
    counts: state.counts,
    position_error_m: state.position.statistics(),
    position_bias_m: if state.position.count == 0 {
      None
    } else {
      Some({ x: state.bias_x, y: state.bias_y, })
    },
    position_coverage: evaluation_coverage(
      state.position.count,
      state.counts.references,
    ),
    speed_error_mps: state.speed.statistics(),
    speed_bias_mps: if state.speed.count == 0 {
      None
    } else {
      Some(state.bias_speed)
    },
    speed_coverage: evaluation_coverage(
      state.speed.count,
      state.counts.speed_references,
    ),
  }
}

///|
fn validate_evaluation_track(
  track : @motion.TrackEstimate,
  timestamp_us : Int64,
) -> Unit raise @types.GroundError {
  let accepted = track.status is @motion.Initializing ||
    track.status is @motion.Ready ||
    track.status is @motion.Uncertain
  if track.track_id <= 0 ||
    (track.position is Some(_)) != accepted ||
    (track.speed_mps is Some(_)) != (track.status is @motion.Ready) ||
    track.last_accepted_timestamp_us < 0L ||
    track.last_accepted_timestamp_us > timestamp_us ||
    (accepted && track.last_accepted_timestamp_us != timestamp_us) {
    raise @types.InvalidInput(
      "evaluation measurement status or timestamp differs",
    )
  }
  if track.position is Some(point) {
    point.validate()
  }
  if track.speed_mps is Some(speed) && (!@types.is_finite(speed) || speed < 0.0) {
    raise @types.InvalidInput("evaluation speed must be finite and nonnegative")
  }
}

///|
/// Match exact timestamps and explicit output track IDs, without interpolation
/// or identity association. Supply projection-failure IDs from MeasurementFrame
/// separately; they must be disjoint from its motion tracks. Position accuracy
/// includes fresh accepted positions; speed accuracy includes ready speeds only.
pub fn EvaluationSession::update(
  self : EvaluationSession,
  frame : @motion.FrameResult,
  reference_timestamp_us : Int64,
  references : Array[ReferenceSample],
  projection_failures~ : Array[Int32] = [],
) -> EvaluationReport raise @types.GroundError {
  let previous = self.state
  if frame.session_id != self.session_id ||
    frame.timestamp_us < 0L ||
    reference_timestamp_us != frame.timestamp_us ||
    (previous.last_timestamp_us is Some(last) && frame.timestamp_us <= last) {
    raise @types.InvalidInput(
      "evaluation requires the same session and exact increasing timestamps",
    )
  }
  if frame.tracks.length() > self.max_tracks ||
    projection_failures.length() > self.max_tracks - frame.tracks.length() ||
    references.length() > self.max_tracks {
    raise @types.InvalidInput("evaluation frame exceeds track capacity")
  }
  let measurement_count = frame.tracks.length() + projection_failures.length()
  if references.length() > self.max_samples - previous.counts.references ||
    measurement_count > self.max_samples - previous.counts.measurements ||
    previous.counts.frames == 9223372036854775807L {
    raise @types.InvalidInput("evaluation sample or frame capacity exhausted")
  }
  let measurements : Map[Int32, @motion.TrackEstimate] = Map([])
  let failures : Map[Int32, Bool] = Map([])
  for track in frame.tracks {
    validate_evaluation_track(track, frame.timestamp_us)
    if measurements.contains(track.track_id) {
      raise @types.InvalidInput("duplicate evaluation measurement identity")
    }
    measurements[track.track_id] = track
  }
  for id in projection_failures {
    if id <= 0 || measurements.contains(id) || failures.contains(id) {
      raise @types.InvalidInput(
        "invalid or duplicate evaluation projection failure",
      )
    }
    failures[id] = true
  }
  let reference_ids : Map[Int32, Bool] = Map([])
  let mut next = previous
  let mut counts = previous.counts
  let mut matched = 0
  for reference in references {
    let id = reference.track_id
    if reference_ids.contains(id) {
      raise @types.InvalidInput("duplicate evaluation reference identity")
    }
    reference_ids[id] = true
    if reference.speed_mps is Some(_) {
      counts = { ..counts, speed_references: counts.speed_references + 1, }
    }
    match measurements.get(id) {
      None =>
        if failures.contains(id) {
          matched += 1
          counts = {
            ..counts,
            rejected_projection: counts.rejected_projection + 1,
          }
        } else {
          counts = { ..counts, missing: counts.missing + 1, }
        }
      Some(track) => {
        matched += 1
        counts = match track.status {
          @motion.Initializing =>
            { ..counts, initializing: counts.initializing + 1, }
          @motion.Ready => { ..counts, ready: counts.ready + 1, }
          @motion.Uncertain => { ..counts, uncertain: counts.uncertain + 1, }
          @motion.RejectedInnovation =>
            { ..counts, rejected_innovation: counts.rejected_innovation + 1, }
          @motion.NumericalFailure =>
            { ..counts, numerical_failure: counts.numerical_failure + 1, }
        }
        if track.position is Some(position) {
          let dx = evaluation_finite(position.x - reference.position_m.x)
          let dy = evaluation_finite(position.y - reference.position_m.y)
          let position = next.position.add(evaluation_norm(dx, dy))
          next = {
            ..next,
            position,
            bias_x: evaluation_mean(next.bias_x, dx, position.count),
            bias_y: evaluation_mean(next.bias_y, dy, position.count),
          }
        }
        if track.speed_mps is Some(speed) &&
          reference.speed_mps is Some(expected) {
          let error = evaluation_finite(speed - expected)
          let speed = next.speed.add(error)
          next = {
            ..next,
            speed,
            bias_speed: evaluation_mean(next.bias_speed, error, speed.count),
          }
        }
      }
    }
  }
  counts = {
    ..counts,
    frames: counts.frames + 1L,
    references: counts.references + references.length(),
    measurements: counts.measurements + measurement_count,
    without_reference: counts.without_reference + measurement_count - matched,
  }
  next = {
    ..next,
    counts,
    first_timestamp_us: if previous.first_timestamp_us is None {
      Some(frame.timestamp_us)
    } else {
      previous.first_timestamp_us
    },
    last_timestamp_us: Some(frame.timestamp_us),
  }
  self.state = next
  self.report()
}
