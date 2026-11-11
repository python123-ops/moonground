///|
/// Fit a calibration without changing any existing browser session.
pub fn moonground_calibrate(source : String) -> String {
  @codec.calibrate_json(source) catch {
    error => failure(error.message())
  }
}
