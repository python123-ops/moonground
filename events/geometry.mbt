///|
fn checked(value : Double) -> Double raise @types.GroundError {
  if !@types.is_finite(value) {
    raise @types.InvalidInput("gate geometry is not representable")
  }
  value
}

///|
/// Build a gate without changing the caller's metric coordinate convention.
pub fn LineGate::new(
  gate_id : String,
  start_m : @types.Point2,
  end_m : @types.Point2,
  deadband_m~ : Double = 0.05,
) -> LineGate raise @types.GroundError {
  if gate_id.length() < 1 || gate_id.length() > 128 {
    raise @types.InvalidInput("gate_id must contain 1 to 128 UTF-16 code units")
  }
  start_m.validate()
  end_m.validate()
  if !@types.is_finite(deadband_m) || deadband_m < 0.0 {
    raise @types.InvalidInput("gate deadband must be finite and nonnegative")
  }
  let dx = checked(end_m.x - start_m.x)
  let dy = checked(end_m.y - start_m.y)
  let scale = if dx.abs() > dy.abs() { dx.abs() } else { dy.abs() }
  if scale == 0.0 {
    raise @types.InvalidInput("gate endpoints must differ")
  }
  let nx = dx / scale
  let ny = dy / scale
  let length_m = checked(scale * (nx * nx + ny * ny).sqrt())
  if length_m <= 0.0 {
    raise @types.InvalidInput("gate length is not representable")
  }
  {
    gate_id,
    start_m,
    end_m,
    deadband_m,
    unit_x: dx / length_m,
    unit_y: dy / length_m,
  }
}

///|
fn LineGate::distance(
  self : LineGate,
  point : @types.Point2,
) -> Double raise @types.GroundError {
  let dx = checked(point.x - self.start_m.x)
  let dy = checked(point.y - self.start_m.y)
  checked(self.unit_x * dy - self.unit_y * dx)
}

///|
fn LineGate::side(
  self : LineGate,
  point : @types.Point2,
) -> Int32 raise @types.GroundError {
  let distance = self.distance(point)
  if distance > self.deadband_m {
    1
  } else if distance < -self.deadband_m {
    -1
  } else {
    0
  }
}

///|
fn LineGate::crossing(
  self : LineGate,
  previous : GateAnchor,
  current : GateAnchor,
  track_id : Int32,
  segment_id : String,
) -> GateCrossing? raise @types.GroundError {
  let from_distance = self.distance(previous.point_m)
  let to_distance = self.distance(current.point_m)
  let a = from_distance.abs()
  let b = to_distance.abs()
  let scale = if a > b { a } else { b }
  // Opposite stable sides guarantee scale > 0. Scaling avoids a+b overflow.
  let fraction = checked(a / scale / (a / scale + b / scale))
  if fraction <= 0.0 || fraction >= 1.0 {
    raise @types.InvalidInput(
      "gate crossing fraction is not representable inside its bracket",
    )
  }
  let position_m : @types.Point2 = {
    x: checked(
      (1.0 - fraction) * previous.point_m.x + fraction * current.point_m.x,
    ),
    y: checked(
      (1.0 - fraction) * previous.point_m.y + fraction * current.point_m.y,
    ),
  }
  let dx = checked(position_m.x - self.start_m.x)
  let dy = checked(position_m.y - self.start_m.y)
  let from_start = checked(self.unit_x * dx + self.unit_y * dy)
  let end_dx = checked(position_m.x - self.end_m.x)
  let end_dy = checked(position_m.y - self.end_m.y)
  let from_end = checked(self.unit_x * end_dx + self.unit_y * end_dy)
  // Compare to each endpoint in its own origin. An independently rounded
  // dot product and norm must not exclude a point computed exactly at the end.
  if from_start < 0.0 || from_end > 0.0 {
    return None
  }
  Some({
    gate_id: self.gate_id,
    track_id,
    segment_id,
    direction: if from_distance < 0.0 {
      NegativeToPositive
    } else {
      PositiveToNegative
    },
    from_timestamp_us: previous.timestamp_us,
    to_timestamp_us: current.timestamp_us,
    from_position_m: previous.point_m,
    to_position_m: current.point_m,
    position_m,
    crossing_fraction: fraction,
  })
}
