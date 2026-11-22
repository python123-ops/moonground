///|
/// Explicit metric reference for the already-associated output track identity.
/// Speed is optional and independently measured; it is never derived from
/// adjacent reference positions or an assumed frame rate.
pub struct ReferenceSample {
  track_id : Int32
  position_m : @types.Point2
  speed_mps : Double?
} derive(Debug)

///|
pub extend ReferenceSample with @debug.Debug::{to_repr}

///|
pub fn ReferenceSample::new(
  track_id : Int32,
  position_m : @types.Point2,
  speed_mps? : Double,
) -> ReferenceSample raise @types.GroundError {
  position_m.validate()
  if track_id <= 0 {
    raise @types.InvalidInput("evaluation reference track_id must be positive")
  }
  if speed_mps is Some(speed) && (!@types.is_finite(speed) || speed < 0.0) {
    raise @types.InvalidInput("reference speed must be finite and nonnegative")
  }
  { track_id, position_m, speed_mps, }
}

///|
/// Empty error populations have null statistics, including the maximum.
pub struct ErrorStatistics {
  samples : Int32
  mean_absolute_error : Double?
  root_mean_square_error : Double?
  maximum_absolute_error : Double?
} derive(Debug)

///|
pub extend ErrorStatistics with @debug.Debug::{to_repr}

///|
/// Status counts concern reference samples. Measurements without a reference
/// are counted separately and never enter accuracy or availability denominators.
pub struct EvaluationCounts {
  frames : Int64
  references : Int32
  speed_references : Int32
  measurements : Int32
  without_reference : Int32
  missing : Int32
  initializing : Int32
  ready : Int32
  uncertain : Int32
  rejected_innovation : Int32
  numerical_failure : Int32
  rejected_projection : Int32
} derive(Debug)

///|
pub extend EvaluationCounts with @debug.Debug::{to_repr}

///|
/// Position statistics use fresh accepted positions (initializing/ready/uncertain).
/// Speed statistics use ready speeds with explicit speed references only.
/// Coverage uses every supplied position or speed reference, including misses.
pub struct EvaluationReport {
  session_id : String
  first_timestamp_us : Int64?
  last_timestamp_us : Int64?
  counts : EvaluationCounts
  position_error_m : ErrorStatistics
  position_bias_m : @types.Point2?
  position_coverage : Double?
  speed_error_mps : ErrorStatistics
  speed_bias_mps : Double?
  speed_coverage : Double?
} derive(Debug)

///|
pub extend EvaluationReport with @debug.Debug::{to_repr}
