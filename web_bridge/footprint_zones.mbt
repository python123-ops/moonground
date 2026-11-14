///|
/// Explicit ground-axis convex offsets, separate from position uncertainty.
pub fn moonground_footprint_zone_evidence(source : String) -> String {
  @codec.footprint_zone_evidence_json(source) catch {
    error => failure(error.message())
  }
}
