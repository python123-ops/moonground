///|
/// Signed perpendicular ground offset under explicit shared calibration modes.
/// Positive is left of the directed infinite reference line; units are metres.
pub struct CalibrationLineOffsetSensitivity {
  position_m : @types.Point2
  signed_offset_m : Double
  contribution_m2 : Double
  std_m : Double
  priv responses : Array[Double]
} derive(Debug)

///|
pub extend CalibrationLineOffsetSensitivity with @debug.Debug::{to_repr}

///|
/// Return a detached copy in the original mode order, in metres per mode.
pub fn CalibrationLineOffsetSensitivity::mode_responses_m(
  self : CalibrationLineOffsetSensitivity,
) -> Array[Double] {
  self.responses.copy()
}

///|
/// Two points measured against the same moving reference line and calibration.
/// Difference is first minus second, evaluated directly from their displacement.
pub struct CalibrationLineOffsetComparison {
  line_start_m : @types.Point2
  line_end_m : @types.Point2
  direction : @types.Point2
  line_length_m : Double
  first : CalibrationLineOffsetSensitivity
  second : CalibrationLineOffsetSensitivity
  cross_contribution_m2 : Double
  difference_m : Double
  difference_contribution_m2 : Double
  difference_std_m : Double
  priv responses : Array[Double]
} derive(Debug)

///|
pub extend CalibrationLineOffsetComparison with @debug.Debug::{to_repr}

///|
/// Return detached first-minus-second responses, in metres per mode.
pub fn CalibrationLineOffsetComparison::difference_mode_responses_m(
  self : CalibrationLineOffsetComparison,
) -> Array[Double] {
  self.responses.copy()
}
