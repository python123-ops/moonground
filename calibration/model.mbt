///|
/// A mapped ground point. Covariance is conditional on the supplied calibration.
pub struct GroundPoint {
  priv position_value : @types.Point2
  priv covariance_value : @types.Covariance2
} derive(Debug)

///|
pub extend GroundPoint with @debug.Debug::{to_repr}

///|
pub fn GroundPoint::position(self : GroundPoint) -> @types.Point2 {
  self.position_value
}

///|
pub fn GroundPoint::covariance(self : GroundPoint) -> @types.Covariance2 {
  self.covariance_value
}

///|
/// Residuals use metres. Imported matrices have no control/check residuals.
pub struct CalibrationReport {
  priv fit_count_value : Int32
  priv check_count_value : Int32
  priv fit_rms_value : Double?
  priv fit_max_value : Double?
  priv check_rms_value : Double?
  priv check_max_value : Double?
  priv roi_scale_bound_value : Double
} derive(Debug)

///|
pub extend CalibrationReport with @debug.Debug::{to_repr}

///|
pub fn CalibrationReport::fit_count(self : CalibrationReport) -> Int32 {
  self.fit_count_value
}

///|
pub fn CalibrationReport::check_count(self : CalibrationReport) -> Int32 {
  self.check_count_value
}

///|
pub fn CalibrationReport::fit_rms_m(self : CalibrationReport) -> Double? {
  self.fit_rms_value
}

///|
pub fn CalibrationReport::fit_max_error_m(self : CalibrationReport) -> Double? {
  self.fit_max_value
}

///|
pub fn CalibrationReport::check_rms_m(self : CalibrationReport) -> Double? {
  self.check_rms_value
}

///|
pub fn CalibrationReport::check_max_error_m(
  self : CalibrationReport,
) -> Double? {
  self.check_max_value
}

///|
/// Conservative upper bound on the largest mapping-Jacobian singular value
/// throughout the convex ROI. This is not a homography condition number.
pub fn CalibrationReport::roi_scale_bound_m_per_pixel(
  self : CalibrationReport,
) -> Double {
  self.roi_scale_bound_value
}

///|
struct ConvexRoi {
  vertices : Array[@types.Point2]
  normalized : Array[@types.Point2]
  origin : @types.Point2
  extent : Double
  orientation : Double
}

///|
/// Immutable pixel-to-ground calibration. Pixels must already be undistorted.
pub struct GroundCalibration {
  priv coefficients : Array[Double]
  priv domain : ConvexRoi
  priv maximum_scale : Double
  priv noise_floor_variance : Double
  priv report_value : CalibrationReport
}

///|
/// A defensive row-major copy of the normalized 3 by 3 matrix.
pub fn GroundCalibration::matrix(self : GroundCalibration) -> Array[Double] {
  self.coefficients.copy()
}

///|
/// A defensive copy of the pixel-space convex ROI, in caller-supplied order.
pub fn GroundCalibration::roi(self : GroundCalibration) -> Array[@types.Point2] {
  self.domain.vertices.copy()
}

///|
pub fn GroundCalibration::report(self : GroundCalibration) -> CalibrationReport {
  self.report_value
}
