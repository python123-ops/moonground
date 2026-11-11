///|
fn normalize_matrix(
  values : Array[Double],
) -> Array[Double] raise @types.GroundError {
  if values.length() != 9 {
    raise @types.GroundError::InvalidInput(
      "homography needs 9 row-major values",
    )
  }
  let mut magnitude = 0.0
  for value in values {
    if !@types.is_finite(value) {
      raise @types.GroundError::InvalidInput("homography values must be finite")
    }
    magnitude = magnitude.max(value.abs())
  }
  if magnitude == 0.0 {
    raise @types.GroundError::InvalidInput("homography must be nonzero")
  }
  let normalized = values.map(fn(value) { value / magnitude })
  let determinant = normalized[0] *
    (normalized[4] * normalized[8] - normalized[5] * normalized[7]) -
    normalized[1] *
    (normalized[3] * normalized[8] - normalized[5] * normalized[6]) +
    normalized[2] *
    (normalized[3] * normalized[7] - normalized[4] * normalized[6])
  if !@types.is_finite(determinant) || determinant == 0.0 {
    raise @types.GroundError::InvalidInput("homography is singular")
  }
  normalized
}

///|
fn map_unchecked(
  h : Array[Double],
  point : @types.Point2,
) -> @types.Point2 raise @types.GroundError {
  let x = h[0] * point.x + h[1] * point.y + h[2]
  let y = h[3] * point.x + h[4] * point.y + h[5]
  let w = h[6] * point.x + h[7] * point.y + h[8]
  if !@types.is_finite(x) ||
    !@types.is_finite(y) ||
    !@types.is_finite(w) ||
    w == 0.0 {
    raise @types.GroundError::InvalidInput(
      "homogeneous projection is not finite",
    )
  }
  @types.Point2::new(x / w, y / w)
}

///|
fn jacobian_unchecked(
  h : Array[Double],
  point : @types.Point2,
) -> Array[Double] raise @types.GroundError {
  let mapped = map_unchecked(h, point)
  let w = h[6] * point.x + h[7] * point.y + h[8]
  let j = [
    (h[0] - h[6] * mapped.x) / w,
    (h[1] - h[7] * mapped.x) / w,
    (h[3] - h[6] * mapped.y) / w,
    (h[4] - h[7] * mapped.y) / w,
  ]
  for value in j {
    if !@types.is_finite(value) {
      raise @types.GroundError::InvalidInput(
        "projection Jacobian is not finite",
      )
    }
  }
  j
}

///|
/// Stable largest singular value of a row-major two by two matrix.
fn largest_singular_value(j : Array[Double]) -> Double {
  let mut scale = 0.0
  for value in j {
    scale = scale.max(value.abs())
  }
  if scale == 0.0 {
    return 0.0
  }
  let a = j[0] / scale
  let b = j[1] / scale
  let c = j[2] / scale
  let d = j[3] / scale
  let first = a * a + b * b
  let second = c * c + d * d
  let off_diagonal = a * c + b * d
  let discriminant = ((first - second) * (first - second) +
  4.0 * off_diagonal * off_diagonal).sqrt()
  scale * ((first + second + discriminant) / 2.0).sqrt()
}

///|
fn check_jacobian(
  j : Array[Double],
  limit : Double,
) -> Unit raise @types.GroundError {
  let scale = largest_singular_value(j)
  if !@types.is_finite(scale) || scale <= 0.0 || scale > limit {
    raise @types.GroundError::InvalidInput(
      "projection exceeds metres-per-pixel limit",
    )
  }
  let determinant = j[0] / scale * (j[3] / scale) -
    j[1] / scale * (j[2] / scale)
  if !@types.is_finite(determinant) || determinant.abs() <= 1.0e-12 {
    raise @types.GroundError::InvalidInput("projection is locally degenerate")
  }
}

///|
fn validate_mapping_domain(
  h : Array[Double],
  domain : ConvexRoi,
  maximum_scale : Double,
) -> Double raise @types.GroundError {
  let first_w = h[6] * domain.vertices[0].x + h[7] * domain.vertices[0].y + h[8]
  let mut min_w = first_w.abs()
  let mut max_w = first_w.abs()
  let numerators = [0.0, 0.0, 0.0, 0.0]
  for point in domain.vertices {
    let w = h[6] * point.x + h[7] * point.y + h[8]
    if !@types.is_finite(w) || w == 0.0 || (w > 0.0) != (first_w > 0.0) {
      raise @types.GroundError::InvalidInput(
        "ROI intersects projective horizon",
      )
    }
    min_w = min_w.min(w.abs())
    max_w = max_w.max(w.abs())
    check_jacobian(jacobian_unchecked(h, point), maximum_scale)
    let n = [
      (h[0] * h[7] - h[6] * h[1]) * point.y + h[0] * h[8] - h[6] * h[2],
      (h[1] * h[6] - h[7] * h[0]) * point.x + h[1] * h[8] - h[7] * h[2],
      (h[3] * h[7] - h[6] * h[4]) * point.y + h[3] * h[8] - h[6] * h[5],
      (h[4] * h[6] - h[7] * h[3]) * point.x + h[4] * h[8] - h[7] * h[5],
    ]
    for i in 0..<4 {
      if !@types.is_finite(n[i]) {
        raise @types.GroundError::InvalidInput(
          "ROI mapping bound is not finite",
        )
      }
      numerators[i] = numerators[i].max(n[i].abs())
    }
  }
  if min_w / max_w < 1.0e-9 {
    raise @types.GroundError::InvalidInput(
      "ROI is too close to projective horizon",
    )
  }
  // Numerators are affine and w has one sign on a convex polygon, so vertex
  // extrema provide a conservative bound everywhere in the ROI. Divide twice
  // to avoid squaring a small homogeneous denominator prematurely.
  let bound = largest_singular_value(
    numerators.map(fn(value) { value / min_w / min_w }),
  )
  if !@types.is_finite(bound) || bound > maximum_scale {
    raise @types.GroundError::InvalidInput("ROI exceeds metres-per-pixel limit")
  }
  bound
}

///|
/// Import a pixel-to-metre matrix. The ROI must be a simple strictly convex
/// polygon. Its boundary is included; mappings outside it are rejected.
pub fn GroundCalibration::from_homography(
  matrix : Array[Double],
  roi : Array[@types.Point2],
  max_meters_per_pixel~ : Double = 0.5,
  ground_noise_floor_m~ : Double = 0.001,
) -> GroundCalibration raise @types.GroundError {
  if !@types.is_finite(max_meters_per_pixel) || max_meters_per_pixel <= 0.0 {
    raise @types.GroundError::InvalidInput(
      "metres-per-pixel limit must be finite and positive",
    )
  }
  let variance = ground_noise_floor_m * ground_noise_floor_m
  if !@types.is_finite(ground_noise_floor_m) ||
    ground_noise_floor_m <= 0.0 ||
    !@types.is_finite(variance) ||
    variance <= 0.0 {
    raise @types.GroundError::InvalidInput(
      "ground noise floor must have finite positive variance",
    )
  }
  let coefficients = normalize_matrix(matrix)
  let domain = make_roi(roi)
  let bound = validate_mapping_domain(
    coefficients, domain, max_meters_per_pixel,
  )
  {
    coefficients,
    domain,
    maximum_scale: max_meters_per_pixel,
    noise_floor_variance: variance,
    report_value: {
      fit_count_value: 0,
      check_count_value: 0,
      fit_rms_value: None,
      fit_max_value: None,
      check_rms_value: None,
      check_max_value: None,
      roi_scale_bound_value: bound,
    },
  }
}

///|
/// Map one already-undistorted pixel point within the calibrated ROI.
pub fn GroundCalibration::map_point(
  self : GroundCalibration,
  point : @types.Point2,
) -> @types.Point2 raise @types.GroundError {
  require_domain_point(self.domain, point)
  map_unchecked(self.coefficients, point)
}

///|
/// Analytic row-major [dX/dx, dX/dy, dY/dx, dY/dy], in metres per pixel.
pub fn GroundCalibration::jacobian(
  self : GroundCalibration,
  point : @types.Point2,
) -> Array[Double] raise @types.GroundError {
  require_domain_point(self.domain, point)
  let j = jacobian_unchecked(self.coefficients, point)
  check_jacobian(j, self.maximum_scale)
  j
}

///|
/// Propagate pixel covariance as J Sigma J^T and add the configured isotropic
/// ground noise floor. This does not estimate calibration-parameter error.
pub fn GroundCalibration::project(
  self : GroundCalibration,
  point : @types.Point2,
  covariance : @types.Covariance2,
) -> GroundPoint raise @types.GroundError {
  covariance.validate()
  let position = self.map_point(point)
  let j = self.jacobian(point)
  let a = j[0]
  let b = j[1]
  let c = j[2]
  let d = j[3]
  let t00 = a * covariance.xx + b * covariance.xy
  let t01 = a * covariance.xy + b * covariance.yy
  let t10 = c * covariance.xx + d * covariance.xy
  let t11 = c * covariance.xy + d * covariance.yy
  for value in [t00, t01, t10, t11] {
    if !@types.is_finite(value) {
      raise @types.GroundError::InvalidInput(
        "covariance propagation overflowed",
      )
    }
  }
  let xx = t00 * a + t01 * b + self.noise_floor_variance
  let xy = (t00 * c + t01 * d) / 2.0 + (t10 * a + t11 * b) / 2.0
  let yy = t10 * c + t11 * d + self.noise_floor_variance
  {
    position_value: position,
    covariance_value: @types.Covariance2::new(xx, xy, yy),
  }
}
