///|
/// Evaluate the same explicit physical radius for every admitted current Ready
/// measurement. Original frame admission and statistical position validation
/// run first; no source arrays or freshness state are retained.
pub fn ZoneProjector::evaluate_disk(
  self : ZoneProjector,
  frame : @motion.FrameResult,
  footprint : DiskFootprint,
) -> DiskZoneEvidenceFrame raise @types.GroundError {
  let position = self.evaluate(frame)
  let evidence : Array[DiskZoneEvidence] = []
  for row in position.evidence {
    evidence.push({
      track_id: row.track_id,
      segment_id: row.segment_id,
      evidence: expand_disk_zone(row.evidence, footprint),
    })
  }
  {
    session_id: position.session_id,
    timestamp_us: position.timestamp_us,
    evidence,
    unavailable: position.unavailable,
  }
}
