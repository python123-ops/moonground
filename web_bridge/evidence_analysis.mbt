///|
/// Atomically measure raw observations and confirm covariance-evidence sides.
pub fn moonground_evidence_analysis(source : String) -> String {
  @codec.evidence_analysis_json(source) catch {
    error => failure(error.message())
  }
}
