///|
/// Create an independent branch with the same fixed calibration, camera and
/// committed motion. Updating either branch leaves the other branch untouched.
pub fn MeasurementSession::fork(
  self : MeasurementSession,
) -> MeasurementSession {
  {
    calibration: self.calibration,
    estimator: self.estimator.fork(),
    max_tracks: self.max_tracks,
    camera_model: self.camera_model,
  }
}
