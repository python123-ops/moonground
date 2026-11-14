///|
/// Visual first-confirmation and ending windows with the original run monitor.
pub fn moonground_footprint_run_windows(source : String) -> String {
  @codec.footprint_run_windows_json(source) catch {
    error => failure(error.message())
  }
}
