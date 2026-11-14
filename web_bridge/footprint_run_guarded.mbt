///|
/// Atomic calibration health, pixel observations and exact footprint runs.
pub fn moonground_footprint_run_guarded(source : String) -> String {
  @codec.footprint_run_guarded_json(source) catch {
    error => failure(error.message())
  }
}

///|
/// Discover actual identities through blocking and recovery on a private replay.
pub fn moonground_footprint_run_guarded_preview(source : String) -> String {
  @codec.footprint_run_guarded_preview_json(source) catch {
    error => failure(error.message())
  }
}
