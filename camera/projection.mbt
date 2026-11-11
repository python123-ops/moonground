///|
fn propagate(
  j : Array[Double],
  covariance : @types.Covariance2,
) -> @types.Covariance2 raise @types.GroundError {
  covariance.validate()
  let a = j[0]
  let b = j[1]
  let c = j[2]
  let d = j[3]
  let t00 = a * covariance.xx + b * covariance.xy
  let t01 = a * covariance.xy + b * covariance.yy
  let t10 = c * covariance.xx + d * covariance.xy
  let t11 = c * covariance.xy + d * covariance.yy
  for value in [t00, t01, t10, t11] {
    if !@types.is_finite(value) {
      raise @types.InvalidInput("camera covariance propagation overflowed")
    }
  }
  @types.Covariance2::new(
    t00 * a + t01 * b,
    (t00 * c + t01 * d) / 2.0 + (t10 * a + t11 * b) / 2.0,
    t10 * c + t11 * d,
  )
}

///|
/// Propagate raw-pixel covariance into rectified pixels. No noise floor or
/// calibration-parameter uncertainty is added by this camera operation.
pub fn CameraModel::rectify_covariance(
  self : CameraModel,
  point : @types.Point2,
  covariance : @types.Covariance2,
) -> @types.Covariance2 raise @types.GroundError {
  covariance.validate()
  propagate(self.jacobian(point), covariance)
}

///|
/// Compose lens correction with a calibration whose ROI is in rectified pixel
/// coordinates. Only GroundCalibration adds the ground noise floor, once.
pub fn CameraModel::project(
  self : CameraModel,
  calibration : @calibration.GroundCalibration,
  point : @types.Point2,
  covariance : @types.Covariance2,
) -> @calibration.GroundPoint raise @types.GroundError {
  covariance.validate()
  let normalized = self.solve_normalized(point)
  let rectified = self.rectified_pixel(normalized)
  let covariance = propagate(
    self.inverse_pixel_jacobian(normalized),
    covariance,
  )
  calibration.project(rectified, covariance)
}

///|
/// Full raw-pixel-to-ground Jacobian, J_homography * J_rectification.
pub fn CameraModel::project_jacobian(
  self : CameraModel,
  calibration : @calibration.GroundCalibration,
  point : @types.Point2,
) -> Array[Double] raise @types.GroundError {
  let normalized = self.solve_normalized(point)
  let ground = calibration.jacobian(self.rectified_pixel(normalized))
  let lens = self.inverse_pixel_jacobian(normalized)
  let result = [
    ground[0] * lens[0] + ground[1] * lens[2],
    ground[0] * lens[1] + ground[1] * lens[3],
    ground[2] * lens[0] + ground[3] * lens[2],
    ground[2] * lens[1] + ground[3] * lens[3],
  ]
  for value in result {
    if !@types.is_finite(value) {
      raise @types.InvalidInput("camera-ground Jacobian is not finite")
    }
  }
  result
}
