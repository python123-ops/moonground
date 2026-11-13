///|
fn linear_hypot(x : Double, y : Double) -> Double {
  let scale = x.abs().max(y.abs())
  if scale == 0.0 {
    0.0
  } else {
    let x = x / scale
    let y = y / scale
    scale * (x * x + y * y).sqrt()
  }
}

///|
// Dekker's product split is safe here: covariance entries have already been
// scaled by a power of two to magnitude at most two.
fn linear_product(a : Double, b : Double) -> (Double, Double) {
  let product = a * b
  let split_a = 134217729.0 * a
  let high_a = split_a - (split_a - a)
  let low_a = a - high_a
  let split_b = 134217729.0 * b
  let high_b = split_b - (split_b - b)
  let low_b = b - high_b
  let error = high_a * high_b -
    product +
    high_a * low_b +
    low_a * high_b +
    low_a * low_b
  (product, error)
}

///|
/// Standard deviation of the linear form a*x+b*y under this covariance.
/// Coefficients are not normalized. The supported covariance precision domain
/// matches directional gate evidence; zero coefficients still validate SPD.
pub fn Covariance2::linear_std(
  covariance : Covariance2,
  coefficients : Point2,
) -> Double raise GroundError {
  coefficients.validate()
  covariance.validate()
  let nx = coefficients.x
  let ny = coefficients.y
  if nx == 0.0 && ny == 0.0 {
    return 0.0
  }
  let deviation = if covariance.xy == 0.0 {
    // Independent normal/tangent variances may differ by many orders of
    // magnitude. Do not divide the small diagonal by the large one.
    linear_hypot(nx * covariance.xx.sqrt(), ny * covariance.yy.sqrt())
  } else {
    let pivot_x = covariance.xx >= covariance.yy
    let pivot = if pivot_x { covariance.xx } else { covariance.yy }
    let other = if pivot_x { covariance.yy } else { covariance.xx }
    let exponent = pivot.reinterpret_as_int64() & 0x7ff0000000000000L
    let scale = if exponent == 0L {
      2.2250738585072014e-308
    } else {
      exponent.reinterpret_as_double()
    }
    let a = pivot / scale
    let b = covariance.xy / scale
    let c = other / scale
    let (ac, ac_error) = linear_product(a, c)
    let (bb, bb_error) = linear_product(b, b)
    let difference = ac - bb
    let displaced = difference - ac
    let subtraction_error = ac - (difference - displaced) - (bb + displaced)
    let determinant = difference + (subtraction_error + ac_error - bb_error)
    let residual = determinant / a
    // Explicit numerical domain, rather than reporting a spuriously small
    // normal deviation for almost perfectly correlated or underflowing LDL.
    if !is_finite(determinant) ||
      determinant <= 0.0 ||
      determinant / ac <= 1.4210854715202004e-14 ||
      residual < 3.5601181736115222e-307 {
      raise InvalidInput(
        "normal covariance cancellation or scale exceeds supported precision",
      )
    }
    let u = if pivot_x { nx } else { ny }
    let v = if pivot_x { ny } else { nx }
    scale.sqrt() * linear_hypot(a.sqrt() * (u + b / a * v), residual.sqrt() * v)
  }
  if !is_finite(deviation) || deviation <= 0.0 {
    raise InvalidInput("normal standard deviation is not representable")
  }
  deviation
}
