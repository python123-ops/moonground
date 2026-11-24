///|
fn evaluation_statistics_json(value : @evaluation.ErrorStatistics) -> Json {
  Json::object({
    "samples": Json(value.samples),
    "mean_absolute_error": optional_number_json(value.mean_absolute_error),
    "root_mean_square_error": optional_number_json(value.root_mean_square_error),
    "maximum_absolute_error": optional_number_json(value.maximum_absolute_error),
  })
}

///|
fn evaluation_timestamp_json(value : Int64?) -> Json {
  match value {
    Some(value) => Json(value.to_string())
    None => Json::null()
  }
}

///|
fn evaluation_report_json(report : @evaluation.EvaluationReport) -> String {
  let counts = report.counts
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("measurement_evaluation"),
    "reference_scope": Json("caller_supplied_aligned_metric_truth"),
    "session_id": Json(report.session_id),
    "first_timestamp_us": evaluation_timestamp_json(report.first_timestamp_us),
    "last_timestamp_us": evaluation_timestamp_json(report.last_timestamp_us),
    "counts": Json::object({
      "frames": Json(counts.frames.to_string()),
      "references": Json(counts.references),
      "speed_references": Json(counts.speed_references),
      "measurements": Json(counts.measurements),
      "without_reference": Json(counts.without_reference),
      "missing": Json(counts.missing),
      "initializing": Json(counts.initializing),
      "ready": Json(counts.ready),
      "uncertain": Json(counts.uncertain),
      "rejected_innovation": Json(counts.rejected_innovation),
      "numerical_failure": Json(counts.numerical_failure),
      "rejected_projection": Json(counts.rejected_projection),
    }),
    "position_error_m": evaluation_statistics_json(report.position_error_m),
    "position_bias_m": optional_point(report.position_bias_m),
    "position_coverage": optional_number_json(report.position_coverage),
    "speed_error_mps": evaluation_statistics_json(report.speed_error_mps),
    "speed_bias_mps": optional_number_json(report.speed_bias_mps),
    "speed_coverage": optional_number_json(report.speed_coverage),
  }).stringify()
}

///|
/// Evaluate supplied schema-0.2 measurement output, retaining bounded counters
/// and numerical accumulators rather than the sample history.
pub struct MeasurementEvaluationReplay {
  priv evaluator : @evaluation.EvaluationSession
  priv max_tracks : Int32
}

///|
pub fn MeasurementEvaluationReplay::open(
  source : String,
) -> MeasurementEvaluationReplay raise @types.GroundError {
  let document = parse_document(source)
  finite_number_tokens(document, "measurement evaluation")
  let fields = object(document, "measurement evaluation configuration")
  allowed_fields(
    fields,
    ["session_id", "max_tracks", "max_samples"],
    "measurement evaluation configuration",
  )
  measurement_evaluator(fields)
}

///|
fn measurement_evaluator(
  fields : Map[String, Json],
) -> MeasurementEvaluationReplay raise @types.GroundError {
  let max_tracks = match fields.get("max_tracks") {
    Some(value) => positive_int(value, "max_tracks")
    None => 4096
  }
  let max_samples = match fields.get("max_samples") {
    Some(value) => positive_int(value, "max_samples")
    None => 10000000
  }
  {
    evaluator: @evaluation.EvaluationSession::new(
      text(required(fields, "session_id"), "session_id"),
      max_tracks~,
      max_samples~,
    ),
    max_tracks,
  }
}

///|
/// Each line binds one measurement frame to a reference frame at the exact same
/// Int64 microsecond timestamp. Failed lines preserve the previous report.
pub fn MeasurementEvaluationReplay::process_line(
  self : MeasurementEvaluationReplay,
  source : String,
) -> Unit raise @types.GroundError {
  let document = parse_document(source)
  finite_number_tokens(document, "measurement evaluation")
  let fields = object(document, "evaluation frame")
  allowed_fields(fields, ["measurement", "reference"], "evaluation frame")
  let measured = required(fields, "measurement")
  let frame = gate_measurement(measured.stringify(), self.max_tracks)
  let measurement = object(measured, "measurement")
  let failures : Array[Int32] = []
  for value in array(required(measurement, "tracks"), "tracks", self.max_tracks) {
    let fields = object(value, "measurement track")
    if fields.get("status") is Some(String("rejected_projection")) {
      failures.push(positive_int(required(fields, "track_id"), "track_id"))
    }
  }
  let reference = object(required(fields, "reference"), "reference frame")
  allowed_fields(reference, ["timestamp_us", "samples"], "reference frame")
  let time = timestamp(
    required(reference, "timestamp_us"),
    "reference timestamp_us",
  )
  let samples = array(
    required(reference, "samples"),
    "reference samples",
    self.max_tracks,
  ).map(value => {
    let fields = object(value, "reference sample")
    allowed_fields(
      fields,
      ["track_id", "position_m", "speed_mps"],
      "reference sample",
    )
    let speed_mps = match fields.get("speed_mps") {
      None => None
      Some(value) => Some(number(value, "reference speed_mps"))
    }
    @evaluation.ReferenceSample::new(
      positive_int(required(fields, "track_id"), "track_id"),
      point(required(fields, "position_m"), "reference position_m"),
      speed_mps?,
    )
  })
  ignore(
    self.evaluator.update(frame, time, samples, projection_failures=failures),
  )
}

///|
pub fn MeasurementEvaluationReplay::report_json(
  self : MeasurementEvaluationReplay,
) -> String {
  evaluation_report_json(self.evaluator.report())
}

///|
/// Pure bounded adapter for JavaScript and short replay batches. Native CLI
/// evaluates the same per-line protocol without retaining the whole input.
pub fn measurement_evaluation_json(
  source : String,
) -> String raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "measurement evaluation batch",
  )
  allowed_fields(fields, ["source", "frames"], "measurement evaluation batch")
  let replay = MeasurementEvaluationReplay::open(
    text(required(fields, "source"), "source"),
  )
  let frames = text(required(fields, "frames"), "frames")
  if frames.length() > 8388608 {
    raise invalid(
      "measurement evaluation frames exceed 8388608 UTF-16 code units",
    )
  }
  let lines = if frames.length() == 0 {
    []
  } else {
    frames.split("\n").collect()
  }
  if frames.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5000 {
    raise invalid("measurement evaluation batch exceeds 5000 frames")
  }
  for line in lines {
    replay.process_line(line.to_owned())
  }
  replay.report_json()
}
