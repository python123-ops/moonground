///|
/// Explicit shared-calibration directions and local circular angle tangents.
pub fn moonground_calibration_angle(source : String) -> String {
  @codec.calibration_angle_json(source) catch {
    error => failure(error.message())
  }
}
