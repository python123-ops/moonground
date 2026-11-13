///|
/// Whether the last committed frame retained this accepted, quality-eligible
/// identity and segment. All-unconfirmed gate sides still retain a track.
pub fn EvidenceGateCounter::has_current_track(
  self : EvidenceGateCounter,
  track_id : Int32,
  segment_id : String,
) -> Bool {
  match self.tracks.get(track_id) {
    Some(track) => track.segment_id == segment_id
    None => false
  }
}

///|
/// Read one original stable-side anchor without exporting all tracks. Invalid
/// identity syntax or an unknown gate raises; a missing/different segment or
/// unconfirmed gate without a retained anchor returns None. Returned point and
/// covariance are independent immutable values at the original anchor time.
pub fn EvidenceGateCounter::anchor(
  self : EvidenceGateCounter,
  track_id : Int32,
  segment_id : String,
  gate_id : String,
) -> EvidenceGateAnchor? raise @types.GroundError {
  if track_id <= 0 {
    raise @types.InvalidInput("evidence anchor identity must be positive")
  }
  validate_segment(segment_id)
  let mut gate_index = -1
  for index, gate in self.gates {
    if gate.gate_id == gate_id {
      gate_index = index
      break
    }
  }
  if gate_index < 0 {
    raise @types.InvalidInput("evidence anchor references an unknown gate")
  }
  match self.tracks.get(track_id) {
    Some(track) if track.segment_id == segment_id =>
      track.anchors[gate_index].map(anchor => {
        timestamp_us: anchor.timestamp_us,
        point_m: { x: anchor.point_m.x, y: anchor.point_m.y, },
        covariance: {
          xx: anchor.covariance.xx,
          xy: anchor.covariance.xy,
          yy: anchor.covariance.yy,
        },
      })
    _ => None
  }
}
