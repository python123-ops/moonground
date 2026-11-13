///|
/// Only the current Healthy landmark report permits object measurements.
/// A fatal analysis error also rolls back this frame's landmark streak and
/// watermark. Blocked raw objects still undergo structural validation but are
/// neither projected nor evaluated by the normal-evidence numerical core.
pub fn EvidenceGuardedSession::update(
  self : EvidenceGuardedSession,
  timestamp_us : Int64,
  landmarks : Array[@health.LandmarkObservation],
  observations : Array[@moonground.PixelObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> EvidenceGuardedFrame raise @types.GroundError {
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
  // Analysis commits atomically and no potentially failing work follows.
  self.health = health
  let suppressed_track_ids = match decision {
    Allowed => []
    Blocked => {
      let ids = observations.map(observation => observation.track_id)
      ids.sort()
      ids
    }
  }
  { decision, health: report, analysis: frame, suppressed_track_ids, }
}
