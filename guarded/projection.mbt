///|
/// Explicitly replace the fixed pixel projection in the same metric ground
/// frame. Gates and landmark ground references retain their physical meaning.
/// The required camera option replaces the old model; None removes it.
///
/// A strictly later empty barrier frame closes every old object segment,
/// clears gate anchors and restarts landmark confirmation. Totals and the next
/// segment identity remain. No replacement evidence is sampled at the barrier.
pub fn GuardedSession::replace_projection(
  self : GuardedSession,
  timestamp_us : Int64,
  calibration : @moonground.GroundCalibration,
  camera~ : @moonground.CameraModel?,
) -> GuardedFrame raise @types.GroundError {
  let candidate = self.analysis.fork()
  let interrupted = candidate.interrupt(timestamp_us)
  let snapshot = candidate.checkpoint()
  guard snapshot.measurement is @analysis.Pixel(pixel) else {
    raise @types.InvalidInput(
      "guarded projection replacement requires pixel mode",
    )
  }
  // Replacement is infrequent: restore the fully closed state to validate the
  // new configuration and all retained exact counters before committing either
  // owned engine. This does not add a per-observation checkpoint round trip.
  let analysis = @analysis.AnalysisSession::from_checkpoint({
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
  // No potentially failing work follows the two assignments.
  self.analysis = analysis
  self.health = health
  {
    decision: Blocked,
    health: report,
    analysis: interrupted,
    suppressed_track_ids: [],
  }
}
