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
fn velocity_component(
  direction : @types.Point2,
  velocity : @types.Point2,
) -> Double raise @types.GroundError {
  velocity.component_along(direction)
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
