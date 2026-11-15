///|
/// Pure first-order shared homography-parameter diagnostics, without a handle.
pub fn moonground_calibration_sensitivity(source : String) -> String {
  @codec.calibration_sensitivity_json(source) catch {
    error => failure(error.message())
  }
}
