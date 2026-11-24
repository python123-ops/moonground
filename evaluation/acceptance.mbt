///|
/// Limits for one measured quantity. Position errors use m; speed errors use
/// m/s. Minimum samples count scored observations, including ready-only speeds.
pub struct AccuracyRequirements {
  min_samples : Int32
  min_coverage : Double
  max_mae : Double?
  max_rmse : Double?
  max_error : Double?
} derive(Debug)

///|
pub extend AccuracyRequirements with @debug.Debug::{to_repr}

///|
/// Require at least one finite, nonnegative error bound. Sample and coverage
/// requirements apply together with every selected error bound.
pub fn AccuracyRequirements::new(
  min_samples~ : Int32,
  min_coverage~ : Double,
  max_mae? : Double,
  max_rmse? : Double,
  max_error? : Double,
) -> AccuracyRequirements raise @types.GroundError {
  if min_samples < 1 ||
    !@types.is_finite(min_coverage) ||
    min_coverage < 0.0 ||
    min_coverage > 1.0 {
    raise @types.InvalidInput(
      "accuracy requirements need positive min_samples and min_coverage in [0,1]",
    )
  }
  if max_mae is None && max_rmse is None && max_error is None {
    raise @types.InvalidInput("accuracy requirements need an error bound")
  }
  for limit in [max_mae, max_rmse, max_error] {
    if limit is Some(value) && (!@types.is_finite(value) || value < 0.0) {
      raise @types.InvalidInput(
        "accuracy error bounds must be finite and nonnegative",
      )
    }
  }
  { min_samples, min_coverage, max_mae, max_rmse, max_error, }
}

///|
pub(all) enum AcceptanceMetric {
  PositionSamples
  PositionCoverage
  PositionMeanAbsoluteError
  PositionRootMeanSquareError
  PositionMaximumAbsoluteError
  SpeedSamples
  SpeedCoverage
  SpeedMeanAbsoluteError
  SpeedRootMeanSquareError
  SpeedMaximumAbsoluteError
} derive(Eq, Debug)

///|
pub extend AcceptanceMetric with @debug.Debug::{to_repr}

///|
pub extend AcceptanceMetric with Eq::{equal, not_equal}

///|
/// Sample count and coverage use inclusive lower bounds. Error statistics use
/// inclusive upper bounds. An unavailable observation always fails its check.
pub struct AcceptanceCheck {
  metric : AcceptanceMetric
  actual : Double?
  limit : Double
  passed : Bool
} derive(Debug)

///|
pub extend AcceptanceCheck with @debug.Debug::{to_repr}

///|
pub struct AcceptanceReport {
  evaluation : EvaluationReport
  accepted : Bool
  checks : Array[AcceptanceCheck]
} derive(Debug)

///|
pub extend AcceptanceReport with @debug.Debug::{to_repr}

///|
fn accuracy_check(
  metric : AcceptanceMetric,
  actual : Double?,
  limit : Double,
  minimum~ : Bool = false,
) -> AcceptanceCheck {
  let passed = match actual {
    Some(value) => if minimum { value >= limit } else { value <= limit }
    None => false
  }
  { metric, actual, limit, passed, }
}

///|
fn accuracy_checks(
  requirements : AccuracyRequirements,
  statistics : ErrorStatistics,
  coverage : Double?,
  speed~ : Bool,
) -> Array[AcceptanceCheck] {
  let checks = [
    accuracy_check(
      if speed {
        SpeedSamples
      } else {
        PositionSamples
      },
      Some(statistics.samples.to_double()),
      requirements.min_samples.to_double(),
      minimum=true,
    ),
    accuracy_check(
      if speed {
        SpeedCoverage
      } else {
        PositionCoverage
      },
      coverage,
      requirements.min_coverage,
      minimum=true,
    ),
  ]
  if requirements.max_mae is Some(limit) {
    checks.push(
      accuracy_check(
        if speed {
          SpeedMeanAbsoluteError
        } else {
          PositionMeanAbsoluteError
        },
        statistics.mean_absolute_error,
        limit,
      ),
    )
  }
  if requirements.max_rmse is Some(limit) {
    checks.push(
      accuracy_check(
        if speed {
          SpeedRootMeanSquareError
        } else {
          PositionRootMeanSquareError
        },
        statistics.root_mean_square_error,
        limit,
      ),
    )
  }
  if requirements.max_error is Some(limit) {
    checks.push(
      accuracy_check(
        if speed {
          SpeedMaximumAbsoluteError
        } else {
          PositionMaximumAbsoluteError
        },
        statistics.maximum_absolute_error,
        limit,
      ),
    )
  }
  checks
}

///|
/// Assess a snapshot of this session without changing its accumulators. Select
/// position, speed or both; there is no accepted result for an empty selection.
pub fn EvaluationSession::assess(
  self : EvaluationSession,
  position? : AccuracyRequirements,
  speed? : AccuracyRequirements,
) -> AcceptanceReport raise @types.GroundError {
  if position is None && speed is None {
    raise @types.InvalidInput(
      "measurement acceptance needs position or speed requirements",
    )
  }
  let evaluation = self.report()
  let checks : Array[AcceptanceCheck] = []
  if position is Some(requirements) {
    checks.append(
      accuracy_checks(
        requirements,
        evaluation.position_error_m,
        evaluation.position_coverage,
        speed=false,
      ),
    )
  }
  if speed is Some(requirements) {
    checks.append(
      accuracy_checks(
        requirements,
        evaluation.speed_error_mps,
        evaluation.speed_coverage,
        speed=true,
      ),
    )
  }
  { evaluation, accepted: checks.all(check => check.passed), checks, }
}
