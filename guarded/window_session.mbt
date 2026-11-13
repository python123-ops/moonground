///|
/// Detach an existing guarded session and begin statistics at its current
/// checkpoint boundary. Earlier outcomes are not reconstructed as samples.
pub fn EvidenceGuardedTransitWindowSession::new(
  guarded : EvidenceGuardedTransitSession,
  window_us~ : Int64,
  duration_limits_us~ : Array[Int64],
  origin_us~ : Int64 = 0L,
) -> EvidenceGuardedTransitWindowSession raise @types.GroundError {
  let original = EvidenceGuardedTransitSession::from_checkpoint(
    guarded.checkpoint(),
  )
  let analysis = @analysis.EvidenceTransitWindowSession::new(
    original.analysis,
    window_us~,
    duration_limits_us~,
    origin_us~,
  )
  { analysis, health: original.health, max_tracks: original.max_tracks, }
}

///|
pub fn EvidenceGuardedTransitWindowSession::checkpoint(
  self : EvidenceGuardedTransitWindowSession,
) -> EvidenceGuardedTransitWindowCheckpoint {
  let analysis = self.analysis.checkpoint()
  {
    version: 1,
    guarded: {
      version: 1,
      analysis: analysis.analysis,
      health: self.health.checkpoint(),
    },
    windows: analysis.windows,
  }
}

///|
pub fn EvidenceGuardedTransitWindowSession::fork(
  self : EvidenceGuardedTransitWindowSession,
) -> EvidenceGuardedTransitWindowSession {
  {
    analysis: self.analysis.fork(),
    health: self.health.fork(),
    max_tracks: self.max_tracks,
  }
}

///|
/// Keep sampled health, metric evidence, pending entries and all windows warm.
pub fn EvidenceGuardedTransitWindowSession::reframed(
  self : EvidenceGuardedTransitWindowSession,
  transform : @types.PixelTransform,
) -> EvidenceGuardedTransitWindowSession raise @types.GroundError {
  {
    analysis: self.analysis.reframed(transform),
    health: self.health.reframed(transform),
    max_tracks: self.max_tracks,
  }
}

///|
/// Only current Healthy evidence permits object measurement. Other frames
/// close hidden segments and count that same empty cancellation frame once.
pub fn EvidenceGuardedTransitWindowSession::update(
  self : EvidenceGuardedTransitWindowSession,
  timestamp_us : Int64,
  landmarks : Array[@health.LandmarkObservation],
  observations : Array[@moonground.PixelObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> EvidenceGuardedTransitWindowFrame raise @types.GroundError {
  validate_guarded_objects(self.max_tracks, observations, lost, removed)
  let health = self.health.fork()
  let report = health.update(timestamp_us, landmarks)
  let decision : GuardDecision = if report.status == @health.Healthy {
    Allowed
  } else {
    Blocked
  }
  let frame = match decision {
    Allowed =>
      self.analysis.update_pixel(timestamp_us, observations, lost~, removed~)
    Blocked => self.analysis.interrupt(timestamp_us)
  }
  self.health = health
  let suppressed_track_ids = match decision {
    Allowed => []
    Blocked => {
      let ids = observations.map(observation => observation.track_id)
      ids.sort()
      ids
    }
  }
  {
    guarded: {
      decision,
      health: report,
      analysis: frame.analysis,
      suppressed_track_ids,
    },
    windows: frame.windows,
  }
}

///|
/// Replace projection through a strictly later empty barrier, counted in the
/// original statistics. Landmark confirmation restarts; metric totals remain.
pub fn EvidenceGuardedTransitWindowSession::replace_projection(
  self : EvidenceGuardedTransitWindowSession,
  timestamp_us : Int64,
  calibration : @moonground.GroundCalibration,
  camera~ : @moonground.CameraModel?,
) -> EvidenceGuardedTransitWindowFrame raise @types.GroundError {
  let candidate = self.analysis.fork()
  let interrupted = candidate.interrupt(timestamp_us)
  let snapshot = candidate.checkpoint()
  guard snapshot.analysis.measurement is @analysis.Pixel(pixel) else {
    raise @types.InvalidInput(
      "guarded transit windows require pixel measurements",
    )
  }
  let analysis = @analysis.EvidenceTransitWindowSession::from_checkpoint({
    ..snapshot,
    analysis: {
      ..snapshot.analysis,
      measurement: @analysis.Pixel({ ..pixel, calibration, camera, }),
    },
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
    guarded: {
      decision: Blocked,
      health: report,
      analysis: interrupted.analysis,
      suppressed_track_ids: [],
    },
    windows: interrupted.windows,
  }
}
