///|
/// Compare the exact stored projection, ordered ROI, scale policy and ground
/// noise variance. Fit/check diagnostics do not change projection behavior.
/// This is a configuration identity check, not an approximate geometric test.
pub fn GroundCalibration::same_projection(
  self : GroundCalibration,
  other : GroundCalibration,
) -> Bool {
  if self.coefficients != other.coefficients ||
    self.maximum_scale != other.maximum_scale ||
    self.noise_floor_variance != other.noise_floor_variance ||
    self.domain.vertices.length() != other.domain.vertices.length() {
    return false
  }
  for index, point in self.domain.vertices {
    let other_point = other.domain.vertices[index]
    if point.x != other_point.x || point.y != other_point.y {
      return false
    }
  }
  true
}
