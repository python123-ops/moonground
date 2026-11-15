///|
/// Direction of an explicitly supplied static segment, from first to second.
/// angle_rad is measured counterclockwise from ground +x, in (-pi, pi].
/// Contributions describe a local angular tangent in radians, including at
/// the display branch cut; they do not define a real-line angle interval.
pub struct CalibrationDirectionSensitivity {
  first_position_m : @types.Point2
  second_position_m : @types.Point2
  direction : @types.Point2
  distance_m : Double
  angle_rad : Double
  contribution_rad2 : Double
  std_rad : Double
  priv responses : Array[Double]
} derive(Debug)

///|
pub extend CalibrationDirectionSensitivity with @debug.Debug::{to_repr}

///|
/// Defensive copy in the original HomographySensitivity mode order.
pub fn CalibrationDirectionSensitivity::mode_responses_rad(
  self : CalibrationDirectionSensitivity,
) -> Array[Double] {
  self.responses.copy()
}

///|
/// Signed angle from the first directed segment to the second, in (-pi, pi].
/// Both directions share the same latent parameter coefficients. The local
/// angle response is second minus first, before squaring for its contribution.
pub struct CalibrationAngleComparison {
  first : CalibrationDirectionSensitivity
  second : CalibrationDirectionSensitivity
  cross_contribution_rad2 : Double
  angle_rad : Double
  contribution_rad2 : Double
  std_rad : Double
  priv responses : Array[Double]
} derive(Debug)

///|
pub extend CalibrationAngleComparison with @debug.Debug::{to_repr}

///|
pub fn CalibrationAngleComparison::mode_responses_rad(
  self : CalibrationAngleComparison,
) -> Array[Double] {
  self.responses.copy()
}
