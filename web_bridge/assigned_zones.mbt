///|
/// Explicit shapes bound to the current measurement clock and target segment.
pub fn moonground_assigned_zone_evidence(source : String) -> String {
  @codec.assigned_zone_evidence_json(source) catch {
    error => failure(error.message())
  }
}
