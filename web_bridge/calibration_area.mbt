///|
/// Explicit shared-calibration convex ground area differences and ratios.
pub fn moonground_calibration_area(source : String) -> String {
  @codec.calibration_area_json(source) catch {
    error => failure(error.message())
  }
}
