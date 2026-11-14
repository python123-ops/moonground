///|
pub fn ZoneProjector::new(
  session_id : String,
  zones : Array[ConvexZone],
  max_tracks~ : Int32 = 1000,
) -> ZoneProjector raise @types.GroundError {
  if session_id.length() == 0 ||
    zones.length() < 1 ||
    zones.length() > 16 ||
    max_tracks < 1 ||
    max_tracks > 10000 {
    raise @types.InvalidInput("invalid zone projector session or capacity")
  }
  let mut total_faces = 0
  let ids : Map[String, Bool] = Map([])
  for zone in zones {
    total_faces += zone.vertices.length()
    if ids.contains(zone.zone_id) {
      raise @types.InvalidInput("duplicate zone identity")
    }
    ids[zone.zone_id] = true
  }
  if max_tracks > 65536 / total_faces {
    raise @types.InvalidInput("zone face and track work budget exceeds 65536")
  }
  { session_id, zones: zones.copy(), max_tracks, }
}

///|
fn validate_zone_segment(source : String) -> Unit raise @types.GroundError {
  let segment = @string.parse_int64(source, base=10) catch {
    _ =>
      raise @types.InvalidInput(
        "zone segment identity must be a positive Int64 string",
      )
  }
  if segment <= 0L || segment.to_string() != source {
    raise @types.InvalidInput(
      "zone segment identity must be a canonical positive Int64 string",
    )
  }
}

///|
/// Evaluate an independent current measurement frame. No input or output
/// arrays are retained, and an error cannot leave a partially advanced state.
pub fn ZoneProjector::evaluate(
  self : ZoneProjector,
  frame : @motion.FrameResult,
) -> ZoneEvidenceFrame raise @types.GroundError {
  if frame.session_id != self.session_id ||
    frame.timestamp_us < 0L ||
    frame.tracks.length() > self.max_tracks ||
    frame.closed_segment_ids.length() > self.max_tracks {
    raise @types.InvalidInput("zone frame session time or capacity is invalid")
  }
  let closed : Map[String, Bool] = Map([])
  for id in frame.closed_segment_ids {
    validate_zone_segment(id)
    if closed.contains(id) {
      raise @types.InvalidInput("duplicate closed zone segment")
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
        "zone frame identities or accepted timestamps are invalid",
      )
    }
    ids[track.track_id] = true
    segments[track.segment_id] = true
    let accepted = track.status is @motion.Ready ||
      track.status is @motion.Initializing ||
      track.status is @motion.Uncertain
    if accepted && closed.contains(track.segment_id) {
      raise @types.InvalidInput("current accepted zone track is also closed")
    }
    if track.status is @motion.Ready &&
      track.last_accepted_timestamp_us != frame.timestamp_us {
      raise @types.InvalidInput(
        "ready zone sample is not current in this frame",
      )
    }
  }
  let tracks = frame.tracks.copy()
  tracks.sort_by((a, b) => a.track_id.compare(b.track_id))
  let evidence : Array[ZoneEvidence] = []
  let unavailable : Array[ZoneUnavailable] = []
  for track in tracks {
    match track.status {
      @motion.Ready => {
        guard track.position is Some(position) &&
          track.position_covariance is Some(covariance) else {
          raise @types.InvalidInput(
            "ready zone sample lacks its position or covariance",
          )
        }
        for zone in self.zones {
          evidence.push({
            track_id: track.track_id,
            segment_id: track.segment_id,
            evidence: zone.evaluate(position, covariance),
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
            raise @types.InvalidInput("unavailable zone status cannot be Ready")
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
