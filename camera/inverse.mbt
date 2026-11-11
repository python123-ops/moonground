///|
fn CameraModel::project_disk(
  self : CameraModel,
  p : @geometry.Point2,
) -> @geometry.Point2 {
  let norm = norm2(p.x, p.y)
  if norm <= self.radius {
    p
  } else {
    let ratio = self.radius / norm
    @geometry.Point2::new(x=p.x * ratio, y=p.y * ratio)
  }
}

///|
fn CameraModel::solve_normalized(
  self : CameraModel,
  point : @types.Point2,
) -> @geometry.Point2 raise @types.GroundError {
  point.validate()
  let target = @geometry.Point2::new(
    x=(point.x - self.cx) / self.fx,
    y=(point.y - self.cy) / self.fy,
  )
  let target_norm = norm2(target.x, target.y)
  if !@types.is_finite(target.x) ||
    !@types.is_finite(target.y) ||
    !@types.is_finite(target_norm) {
    raise @types.InvalidInput("camera normalized pixel is not finite")
  }
  // f(0)=0 and ||J_f|| <= 1+L on the disk, so points beyond this
  // outer radius cannot possess an inverse in the declared domain.
  if target_norm / self.radius > 1.0 + self.perturbation_bound + 1.0e-12 {
    raise @types.InvalidInput("pixel has no inverse within camera radius")
  }
  let mut estimate = self.project_disk(target)
  // Projection is non-expansive. Thus Proj_disk(target - (f(x)-x))
  // is a contraction with constant L. A boundary fixed point without a small
  // forward residual is not an inverse and must never be accepted.
  for _ in 0..<512 {
    let forward = @brown.distort_point(estimate, self.distortion)
    let dx = target.x - forward.x
    let dy = target.y - forward.y
    let residual = norm2(dx, dy)
    if !@types.is_finite(forward.x) ||
      !@types.is_finite(forward.y) ||
      !@types.is_finite(residual) {
      raise @types.InvalidInput("camera inverse arithmetic is not finite")
    }
    // Work relative to the declared radius: an absolute normalized-coordinate
    // tolerance would silently enlarge tiny domains (and clip distant inputs).
    if residual / self.radius / (1.0 - self.perturbation_bound) <= 1.0e-12 {
      if norm2(estimate.x, estimate.y) / self.radius > 1.0 + 1.0e-12 {
        raise @types.InvalidInput("rectified point exceeds camera radius")
      }
      return estimate
    }
    let next = self.project_disk(
      @geometry.Point2::new(x=estimate.x + dx, y=estimate.y + dy),
    )
    if !@types.is_finite(next.x) || !@types.is_finite(next.y) {
      raise @types.InvalidInput("camera inverse arithmetic is not finite")
    }
    if next.x == estimate.x && next.y == estimate.y {
      raise @types.InvalidInput("camera inverse did not converge within radius")
    }
    estimate = next
  }
  raise @types.InvalidInput("camera inverse did not converge in 512 iterations")
}

///|
fn CameraModel::rectified_pixel(
  self : CameraModel,
  normalized : @geometry.Point2,
) -> @types.Point2 raise @types.GroundError {
  @types.Point2::new(
    self.fx * normalized.x + self.cx,
    self.fy * normalized.y + self.cy,
  )
}

///|
fn focal_scaled(
  value : Double,
  numerator : Double,
  denominator : Double,
) -> Double {
  if value == 0.0 {
    return 0.0
  }
  let ratio = numerator / denominator
  if @types.is_finite(ratio) && ratio > 0.0 {
    value * ratio
  } else {
    // A finite equal-focal ratio must be formed before multiplying, otherwise
    // value/very-small-focal can overflow even when the final result is small.
    // When the ratio itself is unrepresentable, the divided-first order may
    // still succeed; the caller rejects any remaining non-finite result.
    value / denominator * numerator
  }
}

///|
fn CameraModel::inverse_pixel_jacobian(
  self : CameraModel,
  normalized : @geometry.Point2,
) -> Array[Double] raise @types.GroundError {
  let forward = @brown.distortion_jacobian(normalized, self.distortion)
  let a = forward.m00
  let b = forward.m01
  let c = forward.m10
  let d = forward.m11
  let scale = a.abs().max(b.abs()).max(c.abs()).max(d.abs())
  if !@types.is_finite(scale) ||
    !@types.is_finite(a) ||
    !@types.is_finite(b) ||
    !@types.is_finite(c) ||
    !@types.is_finite(d) ||
    a <= 0.0 ||
    d <= 0.0 ||
    scale <= 0.0 {
    raise @types.InvalidInput(
      "camera inverse Jacobian is not finite positive definite",
    )
  }
  let determinant = a / scale * (d / scale) - b / scale * (c / scale)
  if !@types.is_finite(determinant) || determinant <= 0.0 {
    raise @types.InvalidInput("camera inverse Jacobian is singular")
  }
  let inverse = [
    d / scale / determinant / scale,
    -(b / scale) / determinant / scale,
    -(c / scale) / determinant / scale,
    a / scale / determinant / scale,
  ]
  let result = [
    inverse[0],
    focal_scaled(inverse[1], self.fx, self.fy),
    focal_scaled(inverse[2], self.fy, self.fx),
    inverse[3],
  ]
  for value in result {
    if !@types.is_finite(value) {
      raise @types.InvalidInput("camera pixel Jacobian is not finite")
    }
  }
  result
}

///|
/// Correct one raw pixel using the certified branch. A maximum of 512
/// projected contraction steps is allowed; residual/R/(1-L) must be at most
/// 1e-12. Domain comparisons use the same relative radius scale. Unresolved
/// points raise an error.
pub fn CameraModel::rectify(
  self : CameraModel,
  point : @types.Point2,
) -> @types.Point2 raise @types.GroundError {
  self.rectified_pixel(self.solve_normalized(point))
}

///|
/// Analytic raw-to-rectified pixel Jacobian, row-major two by two.
pub fn CameraModel::jacobian(
  self : CameraModel,
  point : @types.Point2,
) -> Array[Double] raise @types.GroundError {
  self.inverse_pixel_jacobian(self.solve_normalized(point))
}
