///|
/// Current metric-position halfplane evidence, preserving the raw protocol.
pub fn moonground_zone_evidence(source : String) -> String {
  @codec.zone_evidence_json(source) catch {
    error => failure(error.message())
  }
}
