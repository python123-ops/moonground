///|
/// Replace fixed projection through one strictly later empty barrier, keeping
/// region definitions, shape policy, run limits and the next segment identity.
pub fn FootprintRunGuardedSession::replace_projection(
  self : FootprintRunGuardedSession,
  timestamp_us : Int64,
  calibration : @moonground.GroundCalibration,
  camera~ : @moonground.CameraModel?,
) -> FootprintRunGuardedFrame raise @types.GroundError {
  let candidate = self.analysis.fork()
  let interrupted = candidate.interrupt(timestamp_us)
  let snapshot = candidate.checkpoint()
  guard snapshot.measurement is @analysis.Pixel(pixel) else {
    raise @types.InvalidInput(
      "guarded footprint run projection replacement requires pixel mode",
    )
  }
  let analysis = @analysis.FootprintRunSession::from_checkpoint({
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
  let result : FootprintRunGuardedFrame = {
    decision: GuardDecision::Blocked,
    health: { ..report, landmarks: report.landmarks.copy(), },
    analysis: detach_guarded_run_analysis(interrupted),
    suppressed_track_ids: [],
  }
  self.analysis = analysis
  self.health = health
  self.last_timestamp = Some(timestamp_us)
  result
}
