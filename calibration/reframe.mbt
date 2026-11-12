///|
/// Express this calibration in destination pixels p' = D p + t. The ground
/// reference, SI fit/check residuals and ground noise floor remain unchanged.
/// The ROI and the metres-per-pixel validation bound use destination pixels.
pub fn GroundCalibration::reframed(
  self : GroundCalibration,
  transform : @types.PixelTransform,
) -> GroundCalibration raise @types.GroundError {
  if transform.scale_x == 1.0 &&
    transform.scale_y == 1.0 &&
    transform.offset_x == 0.0 &&
    transform.offset_y == 0.0 {
    return self
  }
  let maximum_scale = self.maximum_scale /
    transform.scale_x.min(transform.scale_y)
  if !@types.is_finite(maximum_scale) || maximum_scale <= 0.0 {
    raise @types.InvalidInput(
      "transformed metres-per-pixel limit must be finite and positive",
    )
  }
  let transformed : Array[Double] = []
  for row in 0..<3 {
    let x = self.coefficients[row * 3] / transform.scale_x
    let y = self.coefficients[row * 3 + 1] / transform.scale_y
    transformed.push(x)
    transformed.push(y)
    transformed.push(
      self.coefficients[row * 3 + 2] -
      x * transform.offset_x -
      y * transform.offset_y,
    )
  }
  let coefficients = normalize_matrix(transformed)
  let vertices : Array[@types.Point2] = []
  for point in self.domain.vertices {
    vertices.push(transform.point(point))
  }
  let domain = make_roi(vertices)
  let bound = validate_mapping_domain(coefficients, domain, maximum_scale)
  {
    coefficients,
    domain,
    maximum_scale,
    noise_floor_variance: self.noise_floor_variance,
    report_value: { ..self.report_value, roi_scale_bound_value: bound, },
  }
}
