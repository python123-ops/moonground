///|
fn evidence_hypot(x : Double, y : Double) -> Double {
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
fn evidence_product(a : Double, b : Double) -> (Double, Double) {
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
fn normal_deviation(
  gate : LineGate,
  covariance : @types.Covariance2,
) -> Double raise @types.GroundError {
  let nx = -gate.unit_y
  let ny = gate.unit_x
  let deviation = if covariance.xy == 0.0 {
    // Independent normal/tangent variances may differ by many orders of
    // magnitude. Do not divide the small diagonal by the large one.
    evidence_hypot(nx * covariance.xx.sqrt(), ny * covariance.yy.sqrt())
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
    let (ac, ac_error) = evidence_product(a, c)
    let (bb, bb_error) = evidence_product(b, b)
    let difference = ac - bb
    let displaced = difference - ac
    let subtraction_error = ac - (difference - displaced) - (bb + displaced)
    let determinant = difference + (subtraction_error + ac_error - bb_error)
    let residual = determinant / a
    // Explicit numerical domain, rather than reporting a spuriously small
    // normal deviation for almost perfectly correlated or underflowing LDL.
    if !@types.is_finite(determinant) ||
      determinant <= 0.0 ||
      determinant / ac <= 1.4210854715202004e-14 ||
      residual < 3.5601181736115222e-307 {
      raise @types.InvalidInput(
        "normal covariance cancellation or scale exceeds supported precision",
      )
    }
    let u = if pivot_x { nx } else { ny }
    let v = if pivot_x { ny } else { nx }
    scale.sqrt() *
    evidence_hypot(a.sqrt() * (u + b / a * v), residual.sqrt() * v)
  }
  if !@types.is_finite(deviation) || deviation <= 0.0 {
    raise @types.InvalidInput("normal standard deviation is not representable")
  }
  deviation
}

///|
fn normal_evidence_band(
  gate : LineGate,
  point : @types.Point2,
  covariance : @types.Covariance2,
  multiplier : Double,
) -> (Double, Double, Double, Double, Int32) raise @types.GroundError {
  let distance_m = gate.distance(point)
  let normal_std_m = normal_deviation(gate, covariance)
  let radius = multiplier * normal_std_m
  if !@types.is_finite(radius) || (multiplier > 0.0 && radius <= 0.0) {
    raise @types.InvalidInput("normal evidence radius is not representable")
  }
  let lower_m = distance_m - radius
  let upper_m = distance_m + radius
  if !@types.is_finite(lower_m) ||
    !@types.is_finite(upper_m) ||
    (multiplier > 0.0 && (lower_m >= distance_m || upper_m <= distance_m)) {
    raise @types.InvalidInput("normal evidence interval is not representable")
  }
  let side = if multiplier == 0.0 {
    gate.side(point)
  } else if lower_m > gate.deadband_m {
    1
  } else if upper_m < -gate.deadband_m {
    -1
  } else {
    0
  }
  (distance_m, normal_std_m, lower_m, upper_m, side)
}

///|
fn gate_evidence(
  gate : LineGate,
  track_id : Int32,
  segment_id : String,
  point : @types.Point2,
  covariance : @types.Covariance2,
  multiplier : Double,
) -> GateEvidence raise @types.GroundError {
  let (distance_m, normal_std_m, lower_m, upper_m, side) = normal_evidence_band(
    gate, point, covariance, multiplier,
  )
  {
    track_id,
    segment_id,
    gate_id: gate.gate_id,
    distance_m,
    normal_std_m,
    lower_m,
    upper_m,
    side,
  }
}

///|
/// Check a position and its original covariance under the evidence policy.
/// Returns -1, 0 (unconfirmed), or 1 using the same supported numerical domain
/// as EvidenceGateCounter. Even a zero multiplier validates SPD and computes
/// the normal deviation. This is side evidence, not finite-endpoint confidence.
pub fn LineGate::evidence_side(
  self : LineGate,
  point : @types.Point2,
  covariance : @types.Covariance2,
  sigma_multiplier~ : Double = 2.0,
) -> Int32 raise @types.GroundError {
  point.validate()
  covariance.validate()
  if !@types.is_finite(sigma_multiplier) || sigma_multiplier < 0.0 {
    raise @types.InvalidInput(
      "evidence sigma multiplier must be finite and nonnegative",
    )
  }
  let (_, _, _, _, side) = normal_evidence_band(
    self, point, covariance, sigma_multiplier,
  )
  side
}
