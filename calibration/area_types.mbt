///|
/// Area of an ordered strictly convex ground polygon. signed_area_m2 is
/// positive for counterclockwise ground winding; area_m2 is always positive.
/// Contributions contain only the original explicit shared parameter modes.
pub struct CalibrationAreaSensitivity {
  signed_area_m2 : Double
  area_m2 : Double
  contribution_m4 : Double
  std_m2 : Double
  priv ground_vertices : Array[@types.Point2]
  priv responses : Array[Double]
} derive(Debug)

///|
pub extend CalibrationAreaSensitivity with @debug.Debug::{to_repr}

///|
/// Defensive copy in the caller's original vertex order.
pub fn CalibrationAreaSensitivity::positions_m(
  self : CalibrationAreaSensitivity,
) -> Array[@types.Point2] {
  self.ground_vertices.copy()
}

///|
/// Absolute-area response per unit original shared latent coefficient.
pub fn CalibrationAreaSensitivity::mode_responses_m2(
  self : CalibrationAreaSensitivity,
) -> Array[Double] {
  self.responses.copy()
}

///|
/// First absolute area minus second, and their positive first/second ratio.
/// Contrast responses are formed before squaring, retaining shared error
/// cancellation. Cross contributions may be negative and have units m^4.
pub struct CalibrationAreaComparison {
  first : CalibrationAreaSensitivity
  second : CalibrationAreaSensitivity
  cross_contribution_m4 : Double
  difference_m2 : Double
  difference_contribution_m4 : Double
  difference_std_m2 : Double
  ratio : Double
  ratio_contribution : Double
  ratio_std : Double
  priv difference_responses : Array[Double]
  priv ratio_responses : Array[Double]
} derive(Debug)

///|
pub extend CalibrationAreaComparison with @debug.Debug::{to_repr}

///|
pub fn CalibrationAreaComparison::difference_mode_responses_m2(
  self : CalibrationAreaComparison,
) -> Array[Double] {
  self.difference_responses.copy()
}

///|
pub fn CalibrationAreaComparison::ratio_mode_responses(
  self : CalibrationAreaComparison,
) -> Array[Double] {
  self.ratio_responses.copy()
}
