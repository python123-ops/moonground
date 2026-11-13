///|
/// Explicitly replace projection in the same metric ground frame. The required
/// camera option installs Some(model) or removes correction with None. A later
/// empty barrier closes all old segments and evidence anchors while preserving
/// the multiplier, counts, next identity and fixed landmark ground references.
pub fn EvidenceGuardedSession::replace_projection(
  self : EvidenceGuardedSession,
  timestamp_us : Int64,
  calibration : @moonground.GroundCalibration,
  camera~ : @moonground.CameraModel?,
) -> EvidenceGuardedFrame raise @types.GroundError {
  let candidate = self.analysis.fork()
  let interrupted = candidate.interrupt(timestamp_us)
  let snapshot = candidate.checkpoint()
  guard snapshot.measurement is @analysis.Pixel(pixel) else {
    raise @types.InvalidInput(
      "guarded projection replacement requires pixel mode",
    )
  }
  let analysis = @analysis.EvidenceAnalysisSession::from_checkpoint({
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
