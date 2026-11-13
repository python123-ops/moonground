///|
/// Joint observation, evidence-transit and confirmation-window replay.
pub fn moonground_evidence_transit_window_analysis(source : String) -> String {
  @codec.evidence_transit_window_analysis_json(source) catch {
    error => failure(error.message())
  }
}
