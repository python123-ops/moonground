///|
/// Atomic raw observations and exact-bound footprint run evidence.
pub fn moonground_footprint_run_analysis(source : String) -> String {
  @codec.footprint_run_analysis_json(source) catch {
    error => failure(error.message())
  }
}

///|
/// Read the actual candidate time and segment identities without committing.
pub fn moonground_footprint_run_preview(source : String) -> String {
  @codec.footprint_run_preview_json(source) catch {
    error => failure(error.message())
  }
}
