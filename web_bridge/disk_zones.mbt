///|
/// Explicit physical disk support without changing position covariance.
pub fn moonground_disk_zone_evidence(source : String) -> String {
  @codec.disk_zone_evidence_json(source) catch {
    error => failure(error.message())
  }
}
