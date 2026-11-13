///|
fn valid_probe(probe : VelocityProbe) -> Unit raise @types.GroundError {
  if probe.probe_id.length() < 1 || probe.probe_id.length() > 128 {
    raise @types.InvalidInput(
      "probe_id must contain 1 to 128 UTF-16 code units",
    )
  }
  probe.direction.validate()
  let norm = probe.direction.x * probe.direction.x +
    probe.direction.y * probe.direction.y
  if !@types.is_finite(norm) ||
    (norm - 1.0).abs() > 8.881784197001252e-16 ||
    !@types.is_finite(probe.threshold_mps) ||
    !@types.is_finite(probe.sigma_multiplier) ||
    probe.sigma_multiplier < 0.0 {
    raise @types.InvalidInput("invalid normalized velocity probe or threshold")
  }
}

///|
/// Normalize once using a scaled norm, without forming an overflowing length.
pub fn VelocityProbe::new(
  probe_id : String,
  direction : @types.Point2,
  threshold_mps : Double,
  sigma_multiplier~ : Double = 2.0,
) -> VelocityProbe raise @types.GroundError {
  direction.validate()
  let scale = direction.x.abs().max(direction.y.abs())
  if scale == 0.0 {
    raise @types.InvalidInput("velocity probe direction must be nonzero")
  }
  let x = direction.x / scale
  let y = direction.y / scale
  let norm = (x * x + y * y).sqrt()
  let dx = x / norm
  let dy = y / norm
  if (direction.x != 0.0 && dx == 0.0) || (direction.y != 0.0 && dy == 0.0) {
    raise @types.InvalidInput(
      "velocity direction normalization loses a nonzero component",
    )
  }
  let probe = {
    probe_id,
    direction: @types.Point2::{ x: dx, y: dy, },
    threshold_mps,
    sigma_multiplier,
  }
  valid_probe(probe)
  probe
}

///|
fn velocity_product(
  a : Double,
  b : Double,
) -> (Double, Double) raise @types.GroundError {
  let product = a * b
  if a != 0.0 && b != 0.0 && product.abs() < 3.5601181736115222e-307 {
    raise @types.InvalidInput(
      "velocity component product exceeds supported precision",
    )
  }
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
fn velocity_component(
  direction : @types.Point2,
  velocity : @types.Point2,
) -> Double raise @types.GroundError {
  velocity.validate()
  let largest = velocity.x.abs().max(velocity.y.abs())
  if largest == 0.0 {
    return 0.0
  }
  let exponent = largest.reinterpret_as_int64() & 0x7ff0000000000000L
  let scale = if exponent == 0L {
    2.2250738585072014e-308
  } else {
    exponent.reinterpret_as_double()
  }
  let x = velocity.x / scale
  let y = velocity.y / scale
  if (direction.x != 0.0 && velocity.x != 0.0 && x == 0.0) ||
    (direction.y != 0.0 && velocity.y != 0.0 && y == 0.0) {
    raise @types.InvalidInput("velocity component scaling loses a nonzero term")
  }
  let (px, ex) = velocity_product(direction.x, x)
  let (py, ey) = velocity_product(direction.y, y)
  let sum = px + py
  let displaced = sum - px
  let error = px - (sum - displaced) + (py - displaced)
  let normalized = sum + (error + ex + ey)
  let component = normalized * scale
  if !@types.is_finite(component) || (normalized != 0.0 && component == 0.0) {
    raise @types.InvalidInput("velocity component is not representable")
  }
  component
}

///|
/// Evaluate a caller-supplied vector and covariance explicitly. The frame
/// convenience API separately enforces the original Ready measurement policy.
pub fn VelocityProbe::evaluate(
  self : VelocityProbe,
  velocity : @types.Point2,
  covariance : @types.Covariance2,
) -> VelocityBand raise @types.GroundError {
  valid_probe(self)
  let component_mps = velocity_component(self.direction, velocity)
  let axis_std_mps = covariance.linear_std(self.direction)
  let radius = self.sigma_multiplier * axis_std_mps
  if !@types.is_finite(radius) || (self.sigma_multiplier > 0.0 && radius <= 0.0) {
    raise @types.InvalidInput("velocity evidence radius is not representable")
  }
  let lower_mps = component_mps - radius
  let upper_mps = component_mps + radius
  if !@types.is_finite(lower_mps) ||
    !@types.is_finite(upper_mps) ||
    (
      self.sigma_multiplier > 0.0 &&
      (lower_mps >= component_mps || upper_mps <= component_mps)
    ) {
    raise @types.InvalidInput("velocity evidence interval is not representable")
  }
  let decision = if lower_mps > self.threshold_mps {
    Above
  } else if upper_mps <= self.threshold_mps {
    AtOrBelow
  } else {
    Indeterminate
  }
  {
    probe_id: self.probe_id,
    component_mps,
    axis_std_mps,
    lower_mps,
    upper_mps,
    threshold_mps: self.threshold_mps,
    sigma_multiplier: self.sigma_multiplier,
    decision,
  }
}
