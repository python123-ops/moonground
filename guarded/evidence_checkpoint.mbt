///|
pub fn EvidenceGuardedSession::from_checkpoint(
  checkpoint : EvidenceGuardedCheckpoint,
) -> EvidenceGuardedSession raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput("unsupported evidence guarded checkpoint version")
  }
  let analysis = @analysis.EvidenceAnalysisSession::from_checkpoint(
    checkpoint.analysis,
  )
  let health = @health.CalibrationMonitor::from_checkpoint(checkpoint.health)
  guard checkpoint.analysis.measurement is @analysis.Pixel(pixel) else {
    raise @types.InvalidInput("guarded analysis requires pixel measurements")
  }
  let max_tracks = validate_guard_binding(
    pixel,
    checkpoint.health,
    health.status(),
    checkpoint.analysis.counting.config.max_tracks,
    checkpoint.analysis.counting.tracks.length(),
  )
  for track in checkpoint.analysis.counting.tracks {
    for anchor in track.anchors {
      if anchor is Some(anchor) {
        validate_guard_accepted_time(
          anchor.timestamp_us,
          checkpoint.health,
          pixel.motion.config.max_gap_us,
        )
      }
    }
  }
  { analysis, health, max_tracks, }
}

///|
/// Validate and detach a pixel evidence analysis and a landmark monitor with
/// exactly matching projection, camera configuration and frame watermark.
pub fn EvidenceGuardedSession::new(
  analysis : @analysis.EvidenceAnalysisSession,
  health : @health.CalibrationMonitor,
) -> EvidenceGuardedSession raise @types.GroundError {
  EvidenceGuardedSession::from_checkpoint({
    version: 1,
    analysis: analysis.checkpoint(),
    health: health.checkpoint(),
  })
}

///|
pub fn EvidenceGuardedSession::checkpoint(
  self : EvidenceGuardedSession,
) -> EvidenceGuardedCheckpoint {
  {
    version: 1,
    analysis: self.analysis.checkpoint(),
    health: self.health.checkpoint(),
  }
}

///|
pub fn EvidenceGuardedSession::fork(
  self : EvidenceGuardedSession,
) -> EvidenceGuardedSession {
  {
    analysis: self.analysis.fork(),
    health: self.health.fork(),
    max_tracks: self.max_tracks,
  }
}

///|
/// Re-express both pixel configurations while preserving all committed metric
/// motion, health progress, covariance evidence, totals and segment allocation.
pub fn EvidenceGuardedSession::reframed(
  self : EvidenceGuardedSession,
  transform : @types.PixelTransform,
) -> EvidenceGuardedSession raise @types.GroundError {
  {
    analysis: self.analysis.reframed(transform),
    health: self.health.reframed(transform),
    max_tracks: self.max_tracks,
  }
}
