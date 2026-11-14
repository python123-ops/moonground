///|
/// Original observations and explicit footprints commit with bounded windows.
pub fn moonground_footprint_run_window_analysis(source : String) -> String {
  @codec.footprint_run_window_analysis_json(source) catch {
    error => failure(error.message())
  }
}

///|
/// Inspect one actual uncommitted measurement at the complete source.
pub fn moonground_footprint_run_window_preview(source : String) -> String {
  @codec.footprint_run_window_preview_json(source) catch {
    error => failure(error.message())
  }
}
