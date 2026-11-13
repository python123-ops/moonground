///|
fn validate_ids(
  ids : Array[Int32],
  seen : Map[Int32, Bool],
) -> Unit raise @types.GroundError {
  for id in ids {
    if id <= 0 || seen.contains(id) {
      raise @types.InvalidInput(
        "guarded object identities must be positive, unique and disjoint",
      )
    }
    seen[id] = true
  }
}

///|
// Validate the submitted payload even when the current health will suppress it.
// This phase does not project pixels through a calibration that is being blocked.
fn validate_guarded_objects(
  max_tracks : Int32,
  observations : Array[@moonground.PixelObservation],
  lost : Array[Int32],
  removed : Array[Int32],
) -> Unit raise @types.GroundError {
  if observations.length() > max_tracks ||
    lost.length() > max_tracks ||
    removed.length() > max_tracks {
    raise @types.InvalidInput("guarded object frame exceeds target capacity")
  }
  let seen : Map[Int32, Bool] = Map([])
  for observation in observations {
    ignore(
      @moonground.PixelObservation::new(
        observation.track_id,
        observation.position,
        observation.covariance,
      ),
    )
    validate_ids([observation.track_id], seen)
  }
  validate_ids(lost, seen)
  validate_ids(removed, seen)
}

///|
/// Apply landmark evidence and the explicit object policy atomically. Only
/// Healthy permits object measurements. Every other status closes all active
/// segments at this timestamp without changing cumulative crossings or IDs.
pub fn GuardedSession::update(
  self : GuardedSession,
  timestamp_us : Int64,
  landmarks : Array[@health.LandmarkObservation],
  observations : Array[@moonground.PixelObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> GuardedFrame raise @types.GroundError {
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
  // Analysis updates are themselves atomic and these assignments cannot raise;
  // no external reference exposes either owned engine between these commits.
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
