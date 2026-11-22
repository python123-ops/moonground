///|
/// Shared-calibration signed offsets against a reference line defined in pixels.
pub fn moonground_calibration_line_offset(source : String) -> String {
  @codec.calibration_line_offset_json(source) catch {
    error => failure(error.message())
  }
}
