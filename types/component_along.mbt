///|
fn component_product(
  a : Double,
  b : Double,
) -> (Double, Double) raise GroundError {
  let product = a * b
  if a != 0.0 && b != 0.0 && product.abs() < 3.5601181736115222e-307 {
    raise InvalidInput(
      "projection component product exceeds supported precision",
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
fn component_sum(
  a : Double,
  b : Double,
  c : Double,
  d : Double,
) -> Double raise GroundError {
  let (px, ex) = component_product(a, b)
  let (py, ey) = component_product(c, d)
  let sum = px + py
  let displaced = sum - px
  let error = px - (sum - displaced) + (py - displaced)
  sum + (error + ex + ey)
}

///|
fn component_scale(largest : Double) -> Double {
  let exponent = largest.reinterpret_as_int64() & 0x7ff0000000000000L
  if exponent == 0L {
    2.2250738585072014e-308
  } else {
    exponent.reinterpret_as_double()
  }
}

///|
/// Stable scalar projection along an already normalized direction.
/// Validates a unit vector without normalizing it again; the finite precision
/// domain matches directed velocity evidence, including compensated cancellation.
pub fn Point2::component_along(
  vector : Point2,
  direction : Point2,
) -> Double raise GroundError {
  vector.validate()
  direction.validate()
  let norm = direction.x * direction.x + direction.y * direction.y
  if !is_finite(norm) || (norm - 1.0).abs() > 8.881784197001252e-16 {
    raise InvalidInput("projection direction must be a finite unit vector")
  }
  let largest = vector.x.abs().max(vector.y.abs())
  if largest == 0.0 {
    return 0.0
  }
  let scale = component_scale(largest)
  let x = vector.x / scale
  let y = vector.y / scale
  if (direction.x != 0.0 && vector.x != 0.0 && x == 0.0) ||
    (direction.y != 0.0 && vector.y != 0.0 && y == 0.0) {
    raise InvalidInput("projection component scaling loses a nonzero term")
  }
  let normalized = component_sum(direction.x, x, direction.y, y)
  let component = normalized * scale
  if !is_finite(component) || (normalized != 0.0 && component == 0.0) {
    raise InvalidInput("projection component is not representable")
  }
  component
}

///|
/// Signed perpendicular distance from a line through the origin, positive to
/// the left of its nonzero raw direction. Both vectors are scaled by exact
/// powers of two before the compensated determinant; no boundary epsilon is
/// introduced by a rounded normalized direction. Unsupported loss of nonzero
/// terms or an unrepresentable result raises InvalidInput.
pub fn Point2::signed_line_distance(
  offset : Point2,
  edge_direction : Point2,
) -> Double raise GroundError {
  offset.validate()
  edge_direction.validate()
  let edge_largest = edge_direction.x.abs().max(edge_direction.y.abs())
  if edge_largest == 0.0 {
    raise InvalidInput("line direction must be nonzero")
  }
  let edge_scale = component_scale(edge_largest)
  let edge_x = edge_direction.x / edge_scale
  let edge_y = edge_direction.y / edge_scale
  if (edge_direction.x != 0.0 && edge_x == 0.0) ||
    (edge_direction.y != 0.0 && edge_y == 0.0) {
    raise InvalidInput("line direction scaling loses a nonzero term")
  }
  let largest = offset.x.abs().max(offset.y.abs())
  if largest == 0.0 {
    return 0.0
  }
  let scale = component_scale(largest)
  let x = offset.x / scale
  let y = offset.y / scale
  if (offset.x != 0.0 && edge_y != 0.0 && x == 0.0) ||
    (offset.y != 0.0 && edge_x != 0.0 && y == 0.0) {
    raise InvalidInput("line offset scaling loses a nonzero term")
  }
  let determinant = component_sum(edge_x, y, -edge_y, x)
  let normalized = determinant / (edge_x * edge_x + edge_y * edge_y).sqrt()
  let distance = normalized * scale
  if !is_finite(distance) ||
    (determinant != 0.0 && determinant.abs() < 3.5601181736115222e-307) ||
    (normalized != 0.0 && normalized.abs() < 3.5601181736115222e-307) ||
    (determinant != 0.0 && normalized == 0.0) ||
    (normalized != 0.0 && distance == 0.0) {
    raise InvalidInput("line distance is not representable")
  }
  distance
}
