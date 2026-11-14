///|
/// Replace projection through one strictly later empty window input. Existing
/// pools and statistics survive; object segments and landmark evidence restart.
pub fn FootprintRunWindowGuardedSession::replace_projection(
  self : FootprintRunWindowGuardedSession,
  timestamp_us : Int64,
  calibration : @moonground.GroundCalibration,
  camera~ : @moonground.CameraModel?,
) -> FootprintRunWindowGuardedFrame raise @types.GroundError {
  let candidate = self.analysis.fork()
  let interrupted = candidate.interrupt(timestamp_us)
  let snapshot = candidate.checkpoint()
  guard snapshot.measurement is @analysis.Pixel(pixel) else {
    raise @types.InvalidInput(
      "guarded footprint windows require pixel measurement",
    )
  }
  let analysis = @analysis.FootprintRunWindowSession::from_checkpoint({
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
  let result : FootprintRunWindowGuardedFrame = {
    decision: GuardDecision::Blocked,
    health: { ..report, landmarks: report.landmarks.copy(), },
    analysis: detach_guarded_run_window_analysis(interrupted),
    suppressed_track_ids: [],
  }
  self.analysis = analysis
  self.health = health
  self.last_timestamp = Some(timestamp_us)
  result
}
