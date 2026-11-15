///|
/// Explicit first-order shared-calibration length differences and ratios.
pub fn moonground_calibration_distance(source : String) -> String {
  @codec.calibration_distance_json(source) catch {
    error => failure(error.message())
  }
}
