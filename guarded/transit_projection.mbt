///|
/// Replace projection in the same metric ground frame through a strictly later
/// empty barrier. It closes hidden segments and cancels pending entries while
/// retaining gates, sections, TTL, multiplier, all totals and the next identity.
/// Fixed landmark truths and health policy remain; confirmation starts cold.
pub fn EvidenceGuardedTransitSession::replace_projection(
  self : EvidenceGuardedTransitSession,
  timestamp_us : Int64,
  calibration : @moonground.GroundCalibration,
  camera~ : @moonground.CameraModel?,
) -> EvidenceGuardedTransitFrame raise @types.GroundError {
  let candidate = self.analysis.fork()
  let interrupted = candidate.interrupt(timestamp_us)
  let snapshot = candidate.checkpoint()
  guard snapshot.measurement is @analysis.Pixel(pixel) else {
    raise @types.InvalidInput(
      "guarded transit projection replacement requires pixel mode",
    )
  }
  let analysis = @analysis.EvidenceTransitSession::from_checkpoint({
    ..snapshot,
    measurement: @analysis.Pixel({ ..pixel, calibration, camera, }),
  })
  let previous = self.health.checkpoint()
  let health = @health.CalibrationMonitor::new(
    calibration,
    previous.landmarks,
    previous.config,
    camera?,
  )
  let report = health.update(timestamp_us, [])
  self.analysis = analysis
  self.health = health
  {
    decision: Blocked,
    health: report,
    analysis: interrupted,
    suppressed_track_ids: [],
  }
}
