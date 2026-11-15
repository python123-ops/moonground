///|
/// First-order contribution from explicit shared homography parameter modes.
/// Zero and singular contributions are valid. This is separate from the
/// strictly positive-definite measurement Covariance2 and the ground floor.
pub struct CalibrationContribution2 {
  xx : Double
  xy : Double
  yy : Double
} derive(Debug)

///|
pub extend CalibrationContribution2 with @debug.Debug::{to_repr}

///|
/// A point and its response to each original, ordered parameter mode.
pub struct CalibrationSensitivityPoint {
  position_m : @types.Point2
  priv responses : Array[@types.Point2]
  contribution_m2 : CalibrationContribution2
} derive(Debug)

///|
pub extend CalibrationSensitivityPoint with @debug.Debug::{to_repr}

///|
/// Defensive copy, in the same order as HomographySensitivity::modes().
pub fn CalibrationSensitivityPoint::mode_responses_m(
  self : CalibrationSensitivityPoint,
) -> Array[@types.Point2] {
  self.responses.copy()
}

///|
/// Cross block is Cov(first, second), row-major [xx, xy, yx, yy]. It need
/// not be symmetric. Displacement is second minus first. The two points
/// share the same latent mode coefficients; their errors are correlated.
pub struct CalibrationSensitivityPair {
  first : CalibrationSensitivityPoint
  second : CalibrationSensitivityPoint
  displacement_m : @types.Point2
  displacement_contribution_m2 : CalibrationContribution2
  priv cross_block : Array[Double]
} derive(Debug)

///|
pub extend CalibrationSensitivityPair with @debug.Debug::{to_repr}

///|
pub fn CalibrationSensitivityPair::cross_contribution_m2(
  self : CalibrationSensitivityPair,
) -> Array[Double] {
  self.cross_block.copy()
}

///|
/// Immutable first-order model H + sum_i(mode_i * xi_i). xi_i have zero
/// mean, unit variance and zero mutual covariance, and are shared across
/// points. Modes use the gauge of calibration.matrix(), including h22.
/// No mode distribution, covariance fit or finite-perturbation bound is inferred.
pub struct HomographySensitivity {
  priv calibration : GroundCalibration
  priv mode_values : Array[Array[Double]]
}

///|
/// A defensive copy of the exact normalized baseline to which modes are bound.
pub fn HomographySensitivity::matrix(
  self : HomographySensitivity,
) -> Array[Double] {
  self.calibration.matrix()
}

///|
pub fn HomographySensitivity::modes(
  self : HomographySensitivity,
) -> Array[Array[Double]] {
  self.mode_values.map(mode => mode.copy())
}
