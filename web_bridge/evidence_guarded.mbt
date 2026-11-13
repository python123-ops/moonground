///|
/// Atomically apply landmark health, pixel measurement and covariance evidence.
pub fn moonground_evidence_guarded(source : String) -> String {
  @codec.evidence_guarded_json(source) catch {
    error => failure(error.message())
  }
}
