///|
fn normal_deviation(
  gate : LineGate,
  covariance : @types.Covariance2,
) -> Double raise @types.GroundError {
  covariance.linear_std({ x: -gate.unit_y, y: gate.unit_x, })
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
