///|
priv struct IntersectionPoint {
  x : IntersectionInterval
  y : IntersectionInterval
}

///|
priv struct IntersectionMetric {
  pivot_x : Bool
  a : IntersectionInterval
  b : IntersectionInterval
  c : IntersectionInterval
  determinant : IntersectionInterval
  ratio : IntersectionInterval
  residual : IntersectionInterval
}

///|
fn intersection_metric(
  covariance : @types.Covariance2,
) -> (IntersectionMetric, Int32) raise @types.GroundError {
  let pivot_x = covariance.xx >= covariance.yy
  let pivot = if pivot_x { covariance.xx } else { covariance.yy }
  let other = if pivot_x { covariance.yy } else { covariance.xx }
  let (scale, exponent) = intersection_scale(pivot)
  let divisor = intersection_point(scale)
  let a = intersection_div(intersection_point(pivot), divisor)
  let b = intersection_div(intersection_point(covariance.xy), divisor)
  let c = intersection_div(intersection_point(other), divisor)
  let determinant = intersection_sub(
    intersection_mul(a, c),
    intersection_square(b),
  )
  if determinant.lower <= 0.0 {
    raise @types.InvalidInput(
      "ellipse covariance determinant cannot be certified positive at supported precision",
    )
  }
  (
    {
      pivot_x,
      a,
      b,
      c,
      determinant,
      ratio: intersection_div(b, a),
      residual: intersection_div(determinant, a),
    },
    exponent,
  )
}

///|
fn intersection_axes(
  point : IntersectionPoint,
  metric : IntersectionMetric,
) -> (IntersectionInterval, IntersectionInterval) {
  if metric.pivot_x {
    (point.x, point.y)
  } else {
    (point.y, point.x)
  }
}

///|
// Positive LDL form of the adjugate quadratic. The intervals enclose the exact
// rational coefficients, including all covariance and geometric input errors.
fn intersection_numerator(
  point : IntersectionPoint,
  metric : IntersectionMetric,
) -> IntersectionInterval raise @types.GroundError {
  let (u, v) = intersection_axes(point, metric)
  let shifted = intersection_sub(v, intersection_mul(metric.ratio, u))
  let result = intersection_add(
    intersection_mul(metric.a, intersection_square(shifted)),
    intersection_mul(metric.residual, intersection_square(u)),
  )
  { lower: result.lower.max(0.0), upper: result.upper, }
}

///|
fn intersection_bilinear(
  first : IntersectionPoint,
  second : IntersectionPoint,
  metric : IntersectionMetric,
) -> IntersectionInterval raise @types.GroundError {
  let (u, v) = intersection_axes(first, metric)
  let (x, y) = intersection_axes(second, metric)
  intersection_sub(
    intersection_add(
      intersection_mul(metric.c, intersection_mul(u, x)),
      intersection_mul(metric.a, intersection_mul(v, y)),
    ),
    intersection_mul(
      metric.b,
      intersection_add(intersection_mul(u, y), intersection_mul(v, x)),
    ),
  )
}

///|
fn intersection_at(
  offset : IntersectionPoint,
  edge : IntersectionPoint,
  fraction : IntersectionInterval,
) -> IntersectionPoint raise @types.GroundError {
  {
    x: intersection_add(offset.x, intersection_mul(fraction, edge.x)),
    y: intersection_add(offset.y, intersection_mul(fraction, edge.y)),
  }
}

///|
fn intersection_parameter(
  offset : IntersectionPoint,
  edge : IntersectionPoint,
  metric : IntersectionMetric,
) -> IntersectionInterval raise @types.GroundError {
  let a = intersection_numerator(edge, metric)
  if a.lower <= 0.0 {
    raise @types.InvalidInput(
      "ellipse edge metric length cannot be certified positive at supported precision",
    )
  }
  let b = intersection_bilinear(offset, edge, metric)
  if b.lower >= 0.0 {
    return intersection_point(0.0)
  }
  if intersection_add(a, b).upper <= 0.0 {
    return intersection_point(1.0)
  }
  let stationary = intersection_div(intersection_neg(b), a)
  {
    lower: stationary.lower.max(0.0).min(1.0),
    upper: stationary.upper.max(0.0).min(1.0),
  }
}

///|
fn intersection_offset(
  point : @types.Point2,
  origin : @types.Point2,
  scale : Double,
) -> IntersectionPoint raise @types.GroundError {
  let divisor = intersection_point(scale)
  {
    x: intersection_div(intersection_scalar_add(point.x, -origin.x), divisor),
    y: intersection_div(intersection_scalar_add(point.y, -origin.y), divisor),
  }
}

///|
fn intersection_cross(
  first : IntersectionPoint,
  second : IntersectionPoint,
) -> IntersectionInterval raise @types.GroundError {
  intersection_sub(
    intersection_mul(first.x, second.y),
    intersection_mul(first.y, second.x),
  )
}

///|
/// Independently bound ellipse/polygon nonempty intersection. Power-of-two
/// scaling supports ordinary unit changes; a determinant or edge metric whose
/// positive sign cannot be certified, or any nonfinite bound, raises InvalidInput.
/// Ambiguous centre signs retain a zero minimum lower bound, without an epsilon.
pub fn ConvexZone::intersect_position(
  self : ConvexZone,
  position : @types.Point2,
  covariance : @types.Covariance2,
) -> PositionZoneIntersection raise @types.GroundError {
  position.validate()
  covariance.validate()
  let (metric, covariance_exponent) = intersection_metric(covariance)
  let threshold = intersection_square(intersection_point(self.sigma_multiplier))
  let mut largest = 0.0
  let mut exact_vertex = false
  for vertex in self.vertices {
    let x = intersection_scalar_add(vertex.x, -position.x)
    let y = intersection_scalar_add(vertex.y, -position.y)
    largest = largest
      .max(x.lower.abs())
      .max(x.upper.abs())
      .max(y.lower.abs())
      .max(y.upper.abs())
    if vertex.x == position.x && vertex.y == position.y {
      exact_vertex = true
    }
  }
  let (coordinate_scale, coordinate_exponent) = intersection_scale(largest)
  let exponent = 2 * coordinate_exponent - covariance_exponent
  let offsets = self.vertices.map(vertex => {
    intersection_offset(vertex, position, coordinate_scale)
  })
  let edges = Array::makei(self.vertices.length(), index => {
    intersection_offset(
      self.vertices[(index + 1) % self.vertices.length()],
      self.vertices[index],
      coordinate_scale,
    )
  })
  let mut centre_inside = true
  let mut centre_outside = false
  for index, edge in edges {
    let toward_centre = {
      x: intersection_neg(offsets[index].x),
      y: intersection_neg(offsets[index].y),
    }
    let cross = intersection_cross(edge, toward_centre)
    let inward = if self.orientation > 0.0 {
      cross
    } else {
      intersection_neg(cross)
    }
    if inward.lower < 0.0 {
      centre_inside = false
    }
    if inward.upper < 0.0 {
      centre_outside = true
    }
  }
  if exact_vertex || centre_inside {
    return {
      zone_id: self.zone_id,
      sigma_multiplier: self.sigma_multiplier,
      minimum_quadratic_lower: 0.0,
      minimum_quadratic_upper: 0.0,
      witness_edge_index: None,
      witness_fraction: None,
      witness_position_m: position,
      decision: ZoneIntersectionDecision::Intersects,
    }
  }
  let mut global_lower : Double? = None
  let mut global_upper : Double? = None
  let mut witness_edge = 0
  let mut witness_fraction = 0.0
  for index, edge in edges {
    let fraction = intersection_parameter(offsets[index], edge, metric)
    let lower = intersection_rescale(
        intersection_div(
          intersection_numerator(
            intersection_at(offsets[index], edge, fraction),
            metric,
          ),
          metric.determinant,
        ),
        exponent,
      ).lower
    let candidate = (fraction.lower + (fraction.upper - fraction.lower) / 2.0)
      .max(0.0)
      .min(1.0)
    let upper = intersection_rescale(
        intersection_div(
          intersection_numerator(
            intersection_at(offsets[index], edge, intersection_point(candidate)),
            metric,
          ),
          metric.determinant,
        ),
        exponent,
      ).upper
    global_lower = Some(
      match global_lower {
        None => lower
        Some(previous) => previous.min(lower)
      },
    )
    let better = match global_upper {
      None => true
      Some(previous) => upper < previous
    }
    if better {
      global_upper = Some(upper)
      witness_edge = index
      witness_fraction = candidate
    }
  }
  let lower = if centre_outside { global_lower.unwrap() } else { 0.0 }
  let upper = global_upper.unwrap()
  if lower > upper {
    raise @types.InvalidInput("ellipse intersection bounds are inconsistent")
  }
  let start = self.vertices[witness_edge]
  let end = self.vertices[(witness_edge + 1) % self.vertices.length()]
  let witness = if witness_fraction == 0.0 {
    start
  } else if witness_fraction == 1.0 {
    end
  } else {
    @types.Point2::{
      x: intersection_finite(start.x + witness_fraction * (end.x - start.x)),
      y: intersection_finite(start.y + witness_fraction * (end.y - start.y)),
    }
  }
  {
    zone_id: self.zone_id,
    sigma_multiplier: self.sigma_multiplier,
    minimum_quadratic_lower: lower,
    minimum_quadratic_upper: upper,
    witness_edge_index: Some(witness_edge),
    witness_fraction: Some(witness_fraction),
    witness_position_m: witness,
    decision: if lower > threshold.upper {
      ZoneIntersectionDecision::Disjoint
    } else if upper <= threshold.lower {
      ZoneIntersectionDecision::Intersects
    } else {
      ZoneIntersectionDecision::Unresolved
    },
  }
}
