///|
/// Evaluate only current Ready model positions. No legacy supporting-face
/// calculation is needed for admission, and no input or output state is kept.
pub fn ZoneProjector::intersect_position(
  self : ZoneProjector,
  frame : @motion.FrameResult,
) -> PositionZoneIntersectionFrame raise @types.GroundError {
  if frame.session_id != self.session_id ||
    frame.timestamp_us < 0L ||
    frame.tracks.length() > self.max_tracks ||
    frame.closed_segment_ids.length() > self.max_tracks {
    raise @types.InvalidInput(
      "intersection frame session time or capacity is invalid",
    )
  }
  let closed : Map[String, Bool] = Map([])
  for id in frame.closed_segment_ids {
    validate_zone_segment(id)
    if closed.contains(id) {
      raise @types.InvalidInput("duplicate closed intersection segment")
    }
    closed[id] = true
  }
  let ids : Map[Int32, Bool] = Map([])
  let segments : Map[String, Bool] = Map([])
  for track in frame.tracks {
    validate_zone_segment(track.segment_id)
    if track.track_id <= 0 ||
      ids.contains(track.track_id) ||
      segments.contains(track.segment_id) ||
      track.last_accepted_timestamp_us < 0L ||
      track.last_accepted_timestamp_us > frame.timestamp_us {
      raise @types.InvalidInput(
        "intersection frame identities or accepted timestamps are invalid",
      )
    }
    ids[track.track_id] = true
    segments[track.segment_id] = true
    let accepted = track.status is @motion.Ready ||
      track.status is @motion.Initializing ||
      track.status is @motion.Uncertain
    if accepted && closed.contains(track.segment_id) {
      raise @types.InvalidInput("accepted intersection track is also closed")
    }
    if track.status is @motion.Ready &&
      track.last_accepted_timestamp_us != frame.timestamp_us {
      raise @types.InvalidInput("Ready intersection sample is not current")
    }
  }
  let tracks = frame.tracks.copy()
  tracks.sort_by((a, b) => a.track_id.compare(b.track_id))
  let evidence : Array[PositionZoneIntersectionEvidence] = []
  let unavailable : Array[ZoneUnavailable] = []
  for track in tracks {
    match track.status {
      @motion.Ready => {
        guard track.position is Some(position) &&
          track.position_covariance is Some(covariance) else {
          raise @types.InvalidInput(
            "Ready intersection sample lacks position or covariance",
          )
        }
        for zone in self.zones {
          evidence.push({
            track_id: track.track_id,
            segment_id: track.segment_id,
            evidence: zone.intersect_position(position, covariance),
          })
        }
      }
      status => {
        let reason = match status {
          @motion.Initializing => Initializing
          @motion.Uncertain => Uncertain
          @motion.RejectedInnovation => RejectedInnovation
          @motion.NumericalFailure => NumericalFailure
          @motion.Ready =>
            raise @types.InvalidInput(
              "unavailable intersection status cannot be Ready",
            )
        }
        unavailable.push({
          track_id: track.track_id,
          segment_id: Some(track.segment_id),
          reason,
        })
      }
    }
  }
  {
    session_id: frame.session_id,
    timestamp_us: frame.timestamp_us,
    evidence,
    unavailable,
  }
}
