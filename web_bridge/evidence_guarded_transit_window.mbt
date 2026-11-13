///|
pub fn moonground_evidence_guarded_transit_window(source : String) -> String {
  @codec.evidence_guarded_transit_window_json(source) catch {
    error => failure(error.message())
  }
}
