///|
/// A complete pixel-measurement snapshot. Calibration and camera values are
/// immutable; motion arrays are copied when exporting and restoring.
pub(all) struct MeasurementCheckpoint {
  calibration : @calibration.GroundCalibration
  camera : @camera.CameraModel?
  motion : @motion.MotionCheckpoint
}

///|
/// Capture the exact calibration, camera and accepted motion state.
pub fn MeasurementSession::checkpoint(
  self : MeasurementSession,
) -> MeasurementCheckpoint {
  {
    calibration: self.calibration,
    camera: self.camera_model,
    motion: self.estimator.checkpoint(),
  }
}

///|
/// Construct an independent session after validating the complete motion state.
pub fn MeasurementSession::from_checkpoint(
  checkpoint : MeasurementCheckpoint,
) -> MeasurementSession raise @types.GroundError {
  let estimator = @motion.MotionEstimator::from_checkpoint(checkpoint.motion)
  {
    calibration: checkpoint.calibration,
    camera_model: checkpoint.camera,
    estimator,
    max_tracks: checkpoint.motion.config.max_tracks(),
  }
}
