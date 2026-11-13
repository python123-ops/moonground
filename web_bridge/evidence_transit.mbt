///|
/// Pair covariance-confirmed gate crossings on the original measurement clock.
pub fn moonground_evidence_transit(source : String) -> String {
  @codec.evidence_transit_json(source) catch {
    error => failure(error.message())
  }
}
