///|
/// Re-express this measured pixel and its covariance in destination coordinates.
pub fn PixelObservation::reframed(
  self : PixelObservation,
  transform : @types.PixelTransform,
) -> PixelObservation raise @types.GroundError {
  PixelObservation::new(
    self.track_id,
    transform.point(self.position),
    transform.covariance(self.covariance),
  )
}

///|
/// Create an independent session using destination pixel coordinates p'=D p+t.
/// Ground-plane motion, uncertainty, paths, identities and timestamps retain
/// their meaning. Future observations must use the same transformed pixels.
pub fn MeasurementSession::reframed(
  self : MeasurementSession,
  transform : @types.PixelTransform,
) -> MeasurementSession raise @types.GroundError {
  let checkpoint = self.checkpoint()
  let camera = match checkpoint.camera {
    Some(value) => Some(value.reframed(transform))
    None => None
  }
  MeasurementSession::from_checkpoint({
    calibration: checkpoint.calibration.reframed(transform),
    camera,
    motion: checkpoint.motion,
  })
}
