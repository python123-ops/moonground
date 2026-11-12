///|
fn same_camera(
  a : @moonground.CameraModel?,
  b : @moonground.CameraModel?,
) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(a), Some(b)) =>
      a.parameters() == b.parameters() &&
      a.max_normalized_radius() == b.max_normalized_radius()
    _ => false
  }
}

///|
/// Restore both old checkpoint formats before validating their shared policy.
/// Non-healthy state cannot retain active object segments or gate anchors.
pub fn GuardedSession::from_checkpoint(
  checkpoint : GuardedCheckpoint,
) -> GuardedSession raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput("unsupported guarded checkpoint version")
  }
  let analysis = @analysis.AnalysisSession::from_checkpoint(checkpoint.analysis)
  let health = @health.CalibrationMonitor::from_checkpoint(checkpoint.health)
  guard checkpoint.analysis.measurement is @analysis.Pixel(pixel) else {
    raise @types.InvalidInput("guarded analysis requires pixel measurements")
  }
  let motion = pixel.motion
  let counting = checkpoint.analysis.counting
  if motion.last_timestamp_us != checkpoint.health.last_timestamp_us {
    raise @types.InvalidInput("guarded health and analysis watermarks differ")
  }
  if !pixel.calibration.same_projection(checkpoint.health.calibration) ||
    !same_camera(pixel.camera, checkpoint.health.camera) {
    raise @types.InvalidInput(
      "guarded health and analysis projection configurations differ",
    )
  }
  let max_tracks = motion.config.max_tracks()
  if counting.config.max_tracks < max_tracks {
    raise @types.InvalidInput(
      "guarded gate capacity must cover the measurement capacity",
    )
  }
  if health.status() != @health.Healthy {
    if motion.tracks.length() != 0 || counting.tracks.length() != 0 {
      raise @types.InvalidInput(
        "blocked guarded checkpoint retains active object state",
      )
    }
  } else {
    guard checkpoint.health.streak is Some(streak) else {
      raise @types.InvalidInput(
        "healthy guarded checkpoint lacks an evidence streak",
      )
    }
    for track in motion.tracks {
      if track.first_timestamp_us < streak.since_us ||
        track.first_timestamp_us - streak.since_us <
        checkpoint.health.config.confirmation_us ||
        track.first_timestamp_us - streak.since_us <
        Int64::from_int(checkpoint.health.config.min_observations - 1) {
        raise @types.InvalidInput(
          "guarded object segment predates possible health confirmation",
        )
      }
    }
  }
  { analysis, health, max_tracks, }
}

///|
/// Detach a pixel analysis and landmark monitor with the same configuration and
/// watermark. Existing state must satisfy the guarded checkpoint invariants.
pub fn GuardedSession::new(
  analysis : @analysis.AnalysisSession,
  health : @health.CalibrationMonitor,
) -> GuardedSession raise @types.GroundError {
  GuardedSession::from_checkpoint({
    version: 1,
    analysis: analysis.checkpoint(),
    health: health.checkpoint(),
  })
}

///|
pub fn GuardedSession::checkpoint(self : GuardedSession) -> GuardedCheckpoint {
  {
    version: 1,
    analysis: self.analysis.checkpoint(),
    health: self.health.checkpoint(),
  }
}

///|
pub fn GuardedSession::fork(self : GuardedSession) -> GuardedSession {
  {
    analysis: self.analysis.fork(),
    health: self.health.fork(),
    max_tracks: self.max_tracks,
  }
}

///|
/// Re-express both fixed calibrations in the same destination pixel convention.
/// Object and landmark observations must subsequently use that transform.
pub fn GuardedSession::reframed(
  self : GuardedSession,
  transform : @types.PixelTransform,
) -> GuardedSession raise @types.GroundError {
  {
    analysis: self.analysis.reframed(transform),
    health: self.health.reframed(transform),
    max_tracks: self.max_tracks,
  }
}
