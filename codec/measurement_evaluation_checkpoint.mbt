///|
fn evaluation_counts_json(value : @evaluation.EvaluationCounts) -> Json {
  Json::object({
    "frames": Json(value.frames.to_string()),
    "references": Json(value.references),
    "speed_references": Json(value.speed_references),
    "measurements": Json(value.measurements),
    "without_reference": Json(value.without_reference),
    "missing": Json(value.missing),
    "initializing": Json(value.initializing),
    "ready": Json(value.ready),
    "uncertain": Json(value.uncertain),
    "rejected_innovation": Json(value.rejected_innovation),
    "numerical_failure": Json(value.numerical_failure),
    "rejected_projection": Json(value.rejected_projection),
  })
}

///|
fn evaluation_count(
  value : Json,
  label : String,
) -> Int32 raise @types.GroundError {
  let numeric = number(value, label)
  if numeric < 0.0 ||
    numeric > 2147483647.0 ||
    numeric.to_int().to_double() != numeric {
    raise invalid(label + " must be a nonnegative 32-bit integer")
  }
  let result = numeric.to_int()
  if value is Number(_, repr=Some(source)) &&
    !(if result == 0 {
      window_zero_token(source)
    } else {
      integer_token_equals(source, result)
    }) {
    raise invalid(label + " must be a nonnegative 32-bit integer")
  }
  result
}

///|
fn evaluation_checkpoint_counts(
  value : Json,
) -> @evaluation.EvaluationCounts raise @types.GroundError {
  let fields = object(value, "evaluation counts")
  allowed_fields(
    fields,
    [
      "frames", "references", "speed_references", "measurements", "without_reference",
      "missing", "initializing", "ready", "uncertain", "rejected_innovation", "numerical_failure",
      "rejected_projection",
    ],
    "evaluation counts",
  )
  {
    frames: timestamp(required(fields, "frames"), "frames"),
    references: evaluation_count(required(fields, "references"), "references"),
    speed_references: evaluation_count(
      required(fields, "speed_references"),
      "speed_references",
    ),
    measurements: evaluation_count(
      required(fields, "measurements"),
      "measurements",
    ),
    without_reference: evaluation_count(
      required(fields, "without_reference"),
      "without_reference",
    ),
    missing: evaluation_count(required(fields, "missing"), "missing"),
    initializing: evaluation_count(
      required(fields, "initializing"),
      "initializing",
    ),
    ready: evaluation_count(required(fields, "ready"), "ready"),
    uncertain: evaluation_count(required(fields, "uncertain"), "uncertain"),
    rejected_innovation: evaluation_count(
      required(fields, "rejected_innovation"),
      "rejected_innovation",
    ),
    numerical_failure: evaluation_count(
      required(fields, "numerical_failure"),
      "numerical_failure",
    ),
    rejected_projection: evaluation_count(
      required(fields, "rejected_projection"),
      "rejected_projection",
    ),
  }
}

///|
fn evaluation_accumulator_json(
  value : @evaluation.ErrorAccumulatorCheckpoint,
) -> Json {
  Json::object({
    "samples": Json(value.samples),
    "mean_absolute": Json(value.mean_absolute),
    "scale": Json(value.scale),
    "scaled_squares": Json(value.scaled_squares),
    "maximum": Json(value.maximum),
  })
}

///|
fn evaluation_checkpoint_accumulator(
  value : Json,
) -> @evaluation.ErrorAccumulatorCheckpoint raise @types.GroundError {
  let fields = object(value, "evaluation accumulator")
  allowed_fields(
    fields,
    ["samples", "mean_absolute", "scale", "scaled_squares", "maximum"],
    "evaluation accumulator",
  )
  {
    samples: evaluation_count(required(fields, "samples"), "samples"),
    mean_absolute: number(required(fields, "mean_absolute"), "mean_absolute"),
    scale: number(required(fields, "scale"), "scale"),
    scaled_squares: number(required(fields, "scaled_squares"), "scaled_squares"),
    maximum: number(required(fields, "maximum"), "maximum"),
  }
}

///|
fn evaluation_checkpoint_json(value : @evaluation.EvaluationCheckpoint) -> Json {
  Json::object({
    "version": Json(value.version),
    "session_id": Json(value.session_id),
    "max_tracks": Json(value.max_tracks),
    "max_samples": Json(value.max_samples),
    "first_timestamp_us": evaluation_timestamp_json(value.first_timestamp_us),
    "last_timestamp_us": evaluation_timestamp_json(value.last_timestamp_us),
    "counts": evaluation_counts_json(value.counts),
    "position": evaluation_accumulator_json(value.position),
    "speed": evaluation_accumulator_json(value.speed),
    "position_bias_m": point_json(value.position_bias_m),
    "speed_bias_mps": Json(value.speed_bias_mps),
  })
}

///|
fn evaluation_checkpoint_time(value : Json) -> Int64? raise @types.GroundError {
  match value {
    Null => None
    _ => Some(timestamp(value, "evaluation checkpoint time"))
  }
}

///|
fn evaluation_checkpoint(
  value : Json,
) -> @evaluation.EvaluationCheckpoint raise @types.GroundError {
  if value.stringify().length() > 16384 {
    raise invalid("evaluation checkpoint exceeds 16384 UTF-16 code units")
  }
  let fields = object(value, "evaluation checkpoint")
  allowed_fields(
    fields,
    [
      "version", "session_id", "max_tracks", "max_samples", "counts", "first_timestamp_us",
      "last_timestamp_us", "position", "speed", "position_bias_m", "speed_bias_mps",
    ],
    "evaluation checkpoint",
  )
  {
    version: positive_int(required(fields, "version"), "version"),
    session_id: text(required(fields, "session_id"), "session_id"),
    max_tracks: positive_int(required(fields, "max_tracks"), "max_tracks"),
    max_samples: positive_int(required(fields, "max_samples"), "max_samples"),
    counts: evaluation_checkpoint_counts(required(fields, "counts")),
    first_timestamp_us: evaluation_checkpoint_time(
      required(fields, "first_timestamp_us"),
    ),
    last_timestamp_us: evaluation_checkpoint_time(
      required(fields, "last_timestamp_us"),
    ),
    position: evaluation_checkpoint_accumulator(required(fields, "position")),
    speed: evaluation_checkpoint_accumulator(required(fields, "speed")),
    position_bias_m: point(
      required(fields, "position_bias_m"),
      "position_bias_m",
    ),
    speed_bias_mps: number(required(fields, "speed_bias_mps"), "speed_bias_mps"),
  }
}

///|
/// Full resumable state, distinct from the rounded evaluation summary.
pub fn MeasurementEvaluationReplay::checkpoint_json(
  self : MeasurementEvaluationReplay,
) -> String {
  "{\"resume\":" +
  evaluation_checkpoint_json(self.evaluator.checkpoint()).stringify() +
  "}"
}

///|
/// One EOF result containing the summary and its complete continuation state.
pub fn MeasurementEvaluationReplay::report_with_checkpoint_json(
  self : MeasurementEvaluationReplay,
) -> String {
  "{\"report\":" +
  self.report_json() +
  ",\"resume\":" +
  evaluation_checkpoint_json(self.evaluator.checkpoint()).stringify() +
  "}"
}

///|
pub fn MeasurementAcceptanceReplay::checkpoint_json(
  self : MeasurementAcceptanceReplay,
) -> String {
  self.replay.checkpoint_json()
}

///|
pub fn MeasurementAcceptanceReplay::report_with_checkpoint_json(
  self : MeasurementAcceptanceReplay,
) -> String {
  "{\"report\":" +
  self.report_json() +
  ",\"resume\":" +
  evaluation_checkpoint_json(self.replay.evaluator.checkpoint()).stringify() +
  "}"
}
