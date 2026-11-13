///|
/// Atomically measure raw observations and pair evidence-confirmed passages.
pub fn moonground_evidence_transit_analysis(source : String) -> String {
  @codec.evidence_transit_analysis_json(source) catch {
    error => failure(error.message())
  }
}
