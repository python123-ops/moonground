///|
/// Euclidean distance at the fixed calibration and its first-order response
/// to the original shared modes. contribution_m2 excludes observation noise,
/// the ground floor and higher-order effects. Endpoints must map distinctly.
pub struct CalibrationDistanceSensitivity {
  first_position_m : @types.Point2
  second_position_m : @types.Point2
  direction : @types.Point2
  distance_m : Double
  contribution_m2 : Double
  std_m : Double
  priv distance_responses : Array[Double]
} derive(Debug)

///|
pub extend CalibrationDistanceSensitivity with @debug.Debug::{to_repr}

///|
/// Defensive copy in the original HomographySensitivity mode order.
pub fn CalibrationDistanceSensitivity::mode_responses_m(
  self : CalibrationDistanceSensitivity,
) -> Array[Double] {
  self.distance_responses.copy()
}

///|
/// The first distance minus the second, and their positive first/second ratio.
/// Both distances use the same latent parameter coefficients. Contrast
/// contributions come from mode responses before squaring, retaining common
/// error cancellation. All contributions are local first-order estimates.
pub struct CalibrationDistanceComparison {
  first : CalibrationDistanceSensitivity
  second : CalibrationDistanceSensitivity
  cross_contribution_m2 : Double
  difference_m : Double
  difference_contribution_m2 : Double
  difference_std_m : Double
  ratio : Double
  ratio_contribution : Double
  ratio_std : Double
  priv difference_responses : Array[Double]
  priv ratio_responses : Array[Double]
} derive(Debug)

///|
pub extend CalibrationDistanceComparison with @debug.Debug::{to_repr}

///|
pub fn CalibrationDistanceComparison::difference_mode_responses_m(
  self : CalibrationDistanceComparison,
) -> Array[Double] {
  self.difference_responses.copy()
}

///|
/// Dimensionless response per unit original latent mode coefficient.
pub fn CalibrationDistanceComparison::ratio_mode_responses(
  self : CalibrationDistanceComparison,
) -> Array[Double] {
  self.ratio_responses.copy()
}
