///|
/// Fixed-landmark health, exact footprint runs and windows share one commit.
pub fn moonground_footprint_run_window_guarded(source : String) -> String {
  @codec.footprint_run_window_guarded_json(source) catch {
    error => failure(error.message())
  }
}

///|
/// Discover actual candidates on a private whole-stream branch without shapes.
pub fn moonground_footprint_run_window_guarded_preview(
  source : String,
) -> String {
  @codec.footprint_run_window_guarded_preview_json(source) catch {
    error => failure(error.message())
  }
}
