///|
/// Validate the complete measurement/evidence/interval state before binding its
/// pixel projection and watermark to the restored landmark health policy.
pub fn EvidenceGuardedTransitSession::from_checkpoint(
  checkpoint : EvidenceGuardedTransitCheckpoint,
) -> EvidenceGuardedTransitSession raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput(
      "unsupported evidence guarded transit checkpoint version",
    )
  }
  let analysis = @analysis.EvidenceTransitSession::from_checkpoint(
    checkpoint.analysis,
  )
  let health = @health.CalibrationMonitor::from_checkpoint(checkpoint.health)
  guard checkpoint.analysis.measurement is @analysis.Pixel(pixel) else {
    raise @types.InvalidInput("guarded transit requires pixel measurements")
  }
  let max_tracks = validate_guard_binding(
    pixel,
    checkpoint.health,
    health.status(),
    checkpoint.analysis.transit.counting.config.max_tracks,
    checkpoint.analysis.transit.counting.tracks.length(),
  )
  for track in checkpoint.analysis.transit.counting.tracks {
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
  for pending in checkpoint.analysis.transit.pending {
    validate_guard_accepted_time(
      pending.entry.from_timestamp_us,
      checkpoint.health,
      pixel.motion.config.max_gap_us,
    )
    validate_guard_accepted_time(
      pending.entry.to_timestamp_us,
      checkpoint.health,
      pixel.motion.config.max_gap_us,
    )
  }
  { analysis, health, max_tracks, }
}

///|
/// Validate and detach an existing pixel transit analysis and a landmark
/// monitor with matching projection, camera and committed frame watermark.
pub fn EvidenceGuardedTransitSession::new(
  analysis : @analysis.EvidenceTransitSession,
  health : @health.CalibrationMonitor,
) -> EvidenceGuardedTransitSession raise @types.GroundError {
  EvidenceGuardedTransitSession::from_checkpoint({
    version: 1,
    analysis: analysis.checkpoint(),
    health: health.checkpoint(),
  })
}

///|
pub fn EvidenceGuardedTransitSession::checkpoint(
  self : EvidenceGuardedTransitSession,
) -> EvidenceGuardedTransitCheckpoint {
  {
    version: 1,
    analysis: self.analysis.checkpoint(),
    health: self.health.checkpoint(),
  }
}

///|
pub fn EvidenceGuardedTransitSession::fork(
  self : EvidenceGuardedTransitSession,
) -> EvidenceGuardedTransitSession {
  {
    analysis: self.analysis.fork(),
    health: self.health.fork(),
    max_tracks: self.max_tracks,
  }
}

///|
/// Re-express both pixel configurations. Health progress, metric motion,
/// original covariance witnesses and pending intervals remain warm.
pub fn EvidenceGuardedTransitSession::reframed(
  self : EvidenceGuardedTransitSession,
  transform : @types.PixelTransform,
) -> EvidenceGuardedTransitSession raise @types.GroundError {
  {
    analysis: self.analysis.reframed(transform),
    health: self.health.reframed(transform),
    max_tracks: self.max_tracks,
  }
}
