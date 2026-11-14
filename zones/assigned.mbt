///|
pub fn FootprintAssignment::new(
  track_id : Int32,
  segment_id : String,
  shape : FootprintShape,
) -> FootprintAssignment raise @types.GroundError {
  if track_id <= 0 {
    raise @types.InvalidInput(
      "footprint assignment target identity must be positive",
    )
  }
  validate_zone_segment(segment_id)
  { track_id, segment_id, shape, }
}

///|
pub fn FootprintAssignments::new(
  timestamp_us : Int64,
  assignments : Array[FootprintAssignment],
) -> FootprintAssignments raise @types.GroundError {
  if timestamp_us < 0L || assignments.length() > 10000 {
    raise @types.InvalidInput(
      "footprint assignment timestamp or capacity is invalid",
    )
  }
  let ids : Map[Int32, Bool] = Map([])
  for assignment in assignments {
    if ids.contains(assignment.track_id) {
      raise @types.InvalidInput(
        "duplicate footprint assignment target identity",
      )
    }
    ids[assignment.track_id] = true
  }
  { timestamp_us, assignments: assignments.copy(), }
}

///|
/// Evaluate explicit current-target shapes after validating all original
/// position evidence. Missing Ready shapes produce one unavailable row; no
/// assignment carries across timestamps or segments. Matching nonReady rows
/// retain their original reason without evaluating physical shape support.
/// Per call at most 65536 faces expand, with at most 32 support projections
/// per face for convex assignments (2097152 total).
pub fn ZoneProjector::evaluate_assigned(
  self : ZoneProjector,
  frame : @motion.FrameResult,
  assignments : FootprintAssignments,
) -> AssignedFootprintZoneEvidenceFrame raise @types.GroundError {
  let statistical = self.evaluate(frame)
  if assignments.timestamp_us != frame.timestamp_us ||
    assignments.assignments.length() > self.max_tracks {
    raise @types.InvalidInput(
      "footprint assignments do not match frame time or capacity",
    )
  }
  let reported : Map[Int32, String] = Map([])
  for track in frame.tracks {
    reported[track.track_id] = track.segment_id
  }
  let assigned : Map[Int32, FootprintShape] = Map([])
  for assignment in assignments.assignments {
    if reported.get(assignment.track_id) != Some(assignment.segment_id) {
      raise @types.InvalidInput(
        "footprint assignment must match a reported target and segment",
      )
    }
    assigned[assignment.track_id] = assignment.shape
  }
  let evidence : Array[AssignedFootprintEvidence] = []
  let unavailable : Array[AssignedFootprintUnavailable] = statistical.unavailable.map(row => {
      track_id: row.track_id,
      segment_id: row.segment_id,
      reason: Position(row.reason),
    },
  )
  for index, row in statistical.evidence {
    let zone_index = index % self.zones.length()
    match assigned.get(row.track_id) {
      None =>
        // Every Ready target has all configured zones in their original order.
        if zone_index == 0 {
          unavailable.push({
            track_id: row.track_id,
            segment_id: Some(row.segment_id),
            reason: MissingFootprint,
          })
        }
      Some(Disk(footprint)) =>
        evidence.push({
          track_id: row.track_id,
          segment_id: row.segment_id,
          evidence: Disk(expand_disk_zone(row.evidence, footprint)),
        })
      Some(Convex(footprint)) => {
        let supports = footprint_zone_support(self.zones[zone_index], footprint)
        evidence.push({
          track_id: row.track_id,
          segment_id: row.segment_id,
          evidence: Convex(
            expand_footprint_zone(row.evidence, supports, footprint),
          ),
        })
      }
    }
  }
  unavailable.sort_by((a, b) => a.track_id.compare(b.track_id))
  {
    session_id: statistical.session_id,
    timestamp_us: statistical.timestamp_us,
    evidence,
    unavailable,
  }
}
