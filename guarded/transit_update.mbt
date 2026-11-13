///|
/// Only the current Healthy report permits measurement and interval updates.
/// Other reports interrupt all active segments through the same empty frame,
/// immediately cancelling pending entries. Suppressed raw observations still
/// receive structural checks, without projection or normal-evidence arithmetic.
pub fn EvidenceGuardedTransitSession::update(
  self : EvidenceGuardedTransitSession,
  timestamp_us : Int64,
  landmarks : Array[@health.LandmarkObservation],
  observations : Array[@moonground.PixelObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> EvidenceGuardedTransitFrame raise @types.GroundError {
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
  // The joint update is atomic; no operation that can raise follows it.
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
