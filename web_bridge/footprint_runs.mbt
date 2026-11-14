///|
/// Confirmed current-footprint sample runs with a complete downstream checkpoint.
pub fn moonground_footprint_runs(source : String) -> String {
  @codec.footprint_runs_json(source) catch {
    error => failure(error.message())
  }
}
