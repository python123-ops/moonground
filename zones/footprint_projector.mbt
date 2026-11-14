///|
/// Reuse current Ready admission and original position evidence, then compute
/// each configured zone's body support once for the whole frame. One footprint
/// applies to every returned target. No clock or mutable source arrays persist.
pub fn ZoneProjector::evaluate_footprint(
  self : ZoneProjector,
  frame : @motion.FrameResult,
  footprint : ConvexFootprint,
) -> FootprintZoneEvidenceFrame raise @types.GroundError {
  let statistical = self.evaluate(frame)
  let evidence : Array[FootprintZoneEvidence] = []
  if statistical.evidence.length() > 0 {
    let supports = self.zones.map(zone => {
      footprint_zone_support(zone, footprint)
    })
    for index, row in statistical.evidence {
      // Original evaluation emits every configured zone in order per Ready
      // target, so this indexes its once-per-zone support without a new owner.
      evidence.push({
        track_id: row.track_id,
        segment_id: row.segment_id,
        evidence: expand_footprint_zone(
          row.evidence,
          supports[index % supports.length()],
          footprint,
        ),
      })
    }
  }
  {
    session_id: statistical.session_id,
    timestamp_us: statistical.timestamp_us,
    evidence,
    unavailable: statistical.unavailable,
  }
}
