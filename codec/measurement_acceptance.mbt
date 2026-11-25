///|
fn accuracy_optional_limit(
  fields : Map[String, Json],
  name : String,
) -> Double? raise @types.GroundError {
  match fields.get(name) {
    Some(value) => Some(number(value, name))
    None => None
  }
}

///|
fn accuracy_requirements(
  value : Json,
) -> @evaluation.AccuracyRequirements raise @types.GroundError {
  let fields = object(value, "accuracy requirements")
  allowed_fields(
    fields,
    ["min_samples", "min_coverage", "max_mae", "max_rmse", "max_error"],
    "accuracy requirements",
  )
  @evaluation.AccuracyRequirements::new(
    min_samples=positive_int(required(fields, "min_samples"), "min_samples"),
    min_coverage=number(required(fields, "min_coverage"), "min_coverage"),
    max_mae?=accuracy_optional_limit(fields, "max_mae"),
    max_rmse?=accuracy_optional_limit(fields, "max_rmse"),
    max_error?=accuracy_optional_limit(fields, "max_error"),
  )
}

///|
fn accuracy_requirements_json(value : @evaluation.AccuracyRequirements) -> Json {
  let fields = {
    "min_samples": Json(value.min_samples),
    "min_coverage": Json(value.min_coverage),
  }
  for
    (name, limit) in [
      ("max_mae", value.max_mae),
      ("max_rmse", value.max_rmse),
      ("max_error", value.max_error),
    ] {
    if limit is Some(limit) {
      fields[name] = Json(limit)
    }
  }
  Json::object(fields)
}

///|
fn acceptance_metric_name(value : @evaluation.AcceptanceMetric) -> String {
  match value {
    PositionSamples => "position_error_m.samples"
    PositionCoverage => "position_coverage"
    PositionMeanAbsoluteError => "position_error_m.mean_absolute_error"
    PositionRootMeanSquareError => "position_error_m.root_mean_square_error"
    PositionMaximumAbsoluteError => "position_error_m.maximum_absolute_error"
    SpeedSamples => "speed_error_mps.samples"
    SpeedCoverage => "speed_coverage"
    SpeedMeanAbsoluteError => "speed_error_mps.mean_absolute_error"
    SpeedRootMeanSquareError => "speed_error_mps.root_mean_square_error"
    SpeedMaximumAbsoluteError => "speed_error_mps.maximum_absolute_error"
  }
}

///|
fn acceptance_check_json(value : @evaluation.AcceptanceCheck) -> Json {
  let minimum = match value.metric {
    PositionSamples | PositionCoverage | SpeedSamples | SpeedCoverage => true
    _ => false
  }
  Json::object({
    "metric": Json(acceptance_metric_name(value.metric)),
    "comparison": Json(if minimum { "at_least" } else { "at_most" }),
    "actual": optional_number_json(value.actual),
    "limit": Json(value.limit),
    "passed": Json(value.passed),
  })
}

///|
/// Apply explicit accuracy requirements to the original aligned evaluation
/// protocol. No defaults infer a scene's acceptable position or speed error.
pub struct MeasurementAcceptanceReplay {
  priv replay : MeasurementEvaluationReplay
  priv position : @evaluation.AccuracyRequirements?
  priv speed : @evaluation.AccuracyRequirements?
}

///|
pub fn MeasurementAcceptanceReplay::open(
  source : String,
) -> MeasurementAcceptanceReplay raise @types.GroundError {
  let document = parse_document(source)
  finite_number_tokens(document, "measurement acceptance")
  let fields = object(document, "measurement acceptance configuration")
  allowed_fields(
    fields,
    ["session_id", "max_tracks", "max_samples", "requirements", "resume"],
    "measurement acceptance configuration",
  )
  let requirements = object(required(fields, "requirements"), "requirements")
  allowed_fields(requirements, ["position_m", "speed_mps"], "requirements")
  let position = requirements.get("position_m").map(accuracy_requirements)
  let speed = requirements.get("speed_mps").map(accuracy_requirements)
  let replay = measurement_evaluator(fields)
  ignore(replay.evaluator.assess(position?, speed?))
  { replay, position, speed, }
}

///|
/// Failed frames preserve the previous evaluation and acceptance checks.
pub fn MeasurementAcceptanceReplay::process_line(
  self : MeasurementAcceptanceReplay,
  source : String,
) -> Unit raise @types.GroundError {
  self.replay.process_line(source)
}

///|
pub fn MeasurementAcceptanceReplay::report_json(
  self : MeasurementAcceptanceReplay,
) -> String {
  let report = try! self.replay.evaluator.assess(
    position?=self.position,
    speed?=self.speed,
  )
  let requirements : Map[String, Json] = Map([])
  if self.position is Some(value) {
    requirements["position_m"] = accuracy_requirements_json(value)
  }
  if self.speed is Some(value) {
    requirements["speed_mps"] = accuracy_requirements_json(value)
  }
  // Embed the evaluator's original JSON, preserving the existing summary.
  "{\"schema_version\":\"0.1.0\",\"kind\":\"measurement_acceptance\",\"accepted\":" +
  report.accepted.to_string() +
  ",\"requirements\":" +
  Json::object(requirements).stringify() +
  ",\"checks\":" +
  Json(report.checks.map(acceptance_check_json)).stringify() +
  ",\"evaluation\":" +
  evaluation_report_json(report.evaluation) +
  "}"
}

///|
pub fn MeasurementAcceptanceReplay::accepted(
  self : MeasurementAcceptanceReplay,
) -> Bool {
  (try! self.replay.evaluator.assess(position?=self.position, speed?=self.speed)).accepted
}

///|
/// Pure bounded batch with the same explicit requirements as the native stream.
fn measurement_acceptance_batch(
  source : String,
  checkpoint~ : Bool,
) -> String raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "measurement acceptance batch",
  )
  allowed_fields(fields, ["source", "frames"], "measurement acceptance batch")
  let replay = MeasurementAcceptanceReplay::open(
    text(required(fields, "source"), "source"),
  )
  let frames = text(required(fields, "frames"), "frames")
  if frames.length() > 8388608 {
    raise invalid(
      "measurement acceptance frames exceed 8388608 UTF-16 code units",
    )
  }
  let lines = if frames.is_empty() { [] } else { frames.split("\n").collect() }
  if frames.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5000 {
    raise invalid("measurement acceptance batch exceeds 5000 frames")
  }
  for line in lines {
    replay.process_line(line.to_owned())
  }
  if checkpoint {
    replay.report_with_checkpoint_json()
  } else {
    replay.report_json()
  }
}

///|
pub fn measurement_acceptance_json(
  source : String,
) -> String raise @types.GroundError {
  measurement_acceptance_batch(source, checkpoint=false)
}

///|
pub fn measurement_acceptance_checkpoint_json(
  source : String,
) -> String raise @types.GroundError {
  measurement_acceptance_batch(source, checkpoint=true)
}
