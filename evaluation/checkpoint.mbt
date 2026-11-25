///|
/// Numerical state, including the scaled sum of squares needed for continuation.
/// A rounded report's MAE and RMSE are insufficient to reconstruct this state.
pub(all) struct ErrorAccumulatorCheckpoint {
  samples : Int32
  mean_absolute : Double
  scale : Double
  scaled_squares : Double
  maximum : Double
} derive(Debug)

///|
pub extend ErrorAccumulatorCheckpoint with @debug.Debug::{to_repr}

///|
/// Constant-size state after the last committed frame; no sample history.
/// Wire formats encode frames and microsecond timestamps as decimal strings.
pub(all) struct EvaluationCheckpoint {
  version : Int32
  session_id : String
  max_tracks : Int32
  max_samples : Int32
  counts : EvaluationCounts
  first_timestamp_us : Int64?
  last_timestamp_us : Int64?
  position : ErrorAccumulatorCheckpoint
  speed : ErrorAccumulatorCheckpoint
  position_bias_m : @types.Point2
  speed_bias_mps : Double
} derive(Debug)

///|
pub extend EvaluationCheckpoint with @debug.Debug::{to_repr}

///|
fn ErrorAccumulator::checkpoint(
  self : ErrorAccumulator,
) -> ErrorAccumulatorCheckpoint {
  {
    samples: self.count,
    mean_absolute: self.mean_absolute,
    scale: self.scale,
    scaled_squares: self.scaled_squares,
    maximum: self.maximum,
  }
}

///|
pub fn EvaluationSession::checkpoint(
  self : EvaluationSession,
) -> EvaluationCheckpoint {
  let state = self.state
  {
    version: 1,
    session_id: self.session_id,
    max_tracks: self.max_tracks,
    max_samples: self.max_samples,
    counts: state.counts,
    first_timestamp_us: state.first_timestamp_us,
    last_timestamp_us: state.last_timestamp_us,
    position: state.position.checkpoint(),
    speed: state.speed.checkpoint(),
    position_bias_m: { x: state.bias_x, y: state.bias_y, },
    speed_bias_mps: state.bias_speed,
  }
}

///|
fn restored_error(
  value : ErrorAccumulatorCheckpoint,
  maximum_samples : Int32,
) -> ErrorAccumulator raise @types.GroundError {
  if value.samples < 0 ||
    value.samples > maximum_samples ||
    !@types.is_finite(value.mean_absolute) ||
    !@types.is_finite(value.scale) ||
    !@types.is_finite(value.scaled_squares) ||
    !@types.is_finite(value.maximum) ||
    value.mean_absolute < 0.0 ||
    value.scale < 0.0 ||
    value.maximum != value.scale ||
    value.mean_absolute > value.maximum {
    raise @types.InvalidInput("invalid evaluation checkpoint accumulator")
  }
  if value.samples == 0 || value.scale == 0.0 {
    if value.mean_absolute != 0.0 ||
      value.scale != 0.0 ||
      value.scaled_squares != 0.0 {
      raise @types.InvalidInput(
        "empty or zero evaluation accumulator is inconsistent",
      )
    }
  } else {
    let count = value.samples.to_double()
    if value.scaled_squares < 1.0 || value.scaled_squares > count {
      raise @types.InvalidInput("invalid evaluation scaled sum of squares")
    }
    // Work in normalized units; allow accumulated floating-point rounding.
    // Subnormal means may round to a full error or zero, so only structural
    // bounds apply at scales where averaging can lose absolute precision.
    if value.scale >= 1.0e-280 {
      let mean = value.mean_absolute / value.scale
      let square = value.scaled_squares / count
      let tolerance = 64.0 * 2.220446049250313e-16 * count
      if mean + tolerance < 1.0 / count ||
        mean > square.sqrt() + tolerance ||
        square > mean + tolerance {
        raise @types.InvalidInput("evaluation error moments are inconsistent")
      }
    }
  }
  {
    count: value.samples,
    mean_absolute: value.mean_absolute,
    scale: value.scale,
    scaled_squares: value.scaled_squares,
    maximum: value.maximum,
  }
}

///|
fn checkpoint_population(count : Int32, tracks : Int32) -> Int64 {
  if count == 0 {
    0L
  } else {
    Int64::from_int((count - 1) / tracks + 1)
  }
}

///|
pub fn EvaluationSession::from_checkpoint(
  checkpoint : EvaluationCheckpoint,
) -> EvaluationSession raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput("unsupported evaluation checkpoint version")
  }
  let session = EvaluationSession::new(
    checkpoint.session_id,
    max_tracks=checkpoint.max_tracks,
    max_samples=checkpoint.max_samples,
  )
  let c = checkpoint.counts
  let values = [
    c.references,
    c.speed_references,
    c.measurements,
    c.without_reference,
    c.missing,
    c.initializing,
    c.ready,
    c.uncertain,
    c.rejected_innovation,
    c.numerical_failure,
    c.rejected_projection,
  ]
  for value in values {
    if value < 0 || value > checkpoint.max_samples {
      raise @types.InvalidInput("invalid evaluation checkpoint count")
    }
  }
  let references = Int64::from_int(c.references)
  let accepted = Int64::from_int(c.initializing) +
    Int64::from_int(c.ready) +
    Int64::from_int(c.uncertain)
  if references !=
    accepted +
    Int64::from_int(c.missing) +
    Int64::from_int(c.rejected_innovation) +
    Int64::from_int(c.numerical_failure) +
    Int64::from_int(c.rejected_projection) ||
    Int64::from_int(c.measurements) !=
    references -
    Int64::from_int(c.missing) +
    Int64::from_int(c.without_reference) ||
    c.speed_references > c.references ||
    Int64::from_int(checkpoint.position.samples) != accepted ||
    checkpoint.speed.samples > c.ready ||
    checkpoint.speed.samples > c.speed_references ||
    Int64::from_int(checkpoint.speed.samples) <
    Int64::from_int(c.speed_references) - references + Int64::from_int(c.ready) {
    raise @types.InvalidInput("evaluation checkpoint populations disagree")
  }
  if c.frames < 0L ||
    c.frames < checkpoint_population(c.references, checkpoint.max_tracks) ||
    c.frames < checkpoint_population(c.measurements, checkpoint.max_tracks) {
    raise @types.InvalidInput(
      "evaluation checkpoint frame count is inconsistent",
    )
  }
  match (checkpoint.first_timestamp_us, checkpoint.last_timestamp_us) {
    (None, None) =>
      if c.frames != 0L || c.references != 0 || c.measurements != 0 {
        raise @types.InvalidInput(
          "evaluation checkpoint has counts without time",
        )
      }
    (Some(first), Some(last)) =>
      if c.frames < 1L ||
        first < 0L ||
        last < first ||
        (c.frames == 1L) != (first == last) ||
        c.frames - 1L > last - first {
        raise @types.InvalidInput("invalid evaluation checkpoint time range")
      }
    _ =>
      raise @types.InvalidInput("incomplete evaluation checkpoint time range")
  }
  let position = restored_error(checkpoint.position, checkpoint.max_samples)
  let speed = restored_error(checkpoint.speed, checkpoint.max_samples)
  checkpoint.position_bias_m.validate()
  if !@types.is_finite(checkpoint.speed_bias_mps) ||
    checkpoint.position_bias_m.x.abs() > position.maximum ||
    checkpoint.position_bias_m.y.abs() > position.maximum ||
    checkpoint.speed_bias_mps.abs() > speed.maximum {
    raise @types.InvalidInput("invalid evaluation checkpoint bias")
  }
  if position.scale >= 1.0e-280 &&
    evaluation_norm(
      checkpoint.position_bias_m.x / position.scale,
      checkpoint.position_bias_m.y / position.scale,
    ) >
    position.mean_absolute / position.scale +
    64.0 * 2.220446049250313e-16 * position.count.to_double() {
    raise @types.InvalidInput("evaluation position bias exceeds mean error")
  }
  if speed.scale >= 1.0e-280 &&
    checkpoint.speed_bias_mps.abs() / speed.scale >
    speed.mean_absolute / speed.scale +
    64.0 * 2.220446049250313e-16 * speed.count.to_double() {
    raise @types.InvalidInput("evaluation speed bias exceeds mean error")
  }
  session.state = {
    counts: c,
    first_timestamp_us: checkpoint.first_timestamp_us,
    last_timestamp_us: checkpoint.last_timestamp_us,
    position,
    speed,
    bias_x: checkpoint.position_bias_m.x,
    bias_y: checkpoint.position_bias_m.y,
    bias_speed: checkpoint.speed_bias_mps,
  }
  session
}
