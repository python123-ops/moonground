///|
fn checked_zone_coordinate(value : Double) -> Double raise @types.GroundError {
  if !@types.is_finite(value) {
    raise @types.InvalidInput("zone geometry is not representable")
  }
  value
}

///|
fn zone_cross(
  a : @types.Point2,
  b : @types.Point2,
  point : @types.Point2,
) -> Double {
  (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
}

///|
fn validate_convex_geometry(
  vertices_m : Array[@types.Point2],
) -> (Array[@types.Point2], Double) raise @types.GroundError {
  if vertices_m.length() < 3 || vertices_m.length() > 32 {
    raise @types.InvalidInput("convex geometry requires 3 to 32 vertices")
  }
  let first = vertices_m[0]
  first.validate()
  let mut low_x = first.x
  let mut low_y = first.y
  let mut high_x = first.x
  let mut high_y = first.y
  for point in vertices_m {
    point.validate()
    low_x = low_x.min(point.x)
    low_y = low_y.min(point.y)
    high_x = high_x.max(point.x)
    high_y = high_y.max(point.y)
  }
  let extent = checked_zone_coordinate(high_x - low_x).max(
    checked_zone_coordinate(high_y - low_y),
  )
  if extent <= 0.0 {
    raise @types.InvalidInput("zone has no finite spatial extent")
  }
  let normalized = vertices_m.map(point => @types.Point2::{
    x: (point.x - low_x) / extent,
    y: (point.y - low_y) / extent,
  })
  let turn = zone_cross(normalized[0], normalized[1], normalized[2])
  if !@types.is_finite(turn) || turn.abs() <= 1.0e-12 {
    raise @types.InvalidInput("zone must be strictly convex")
  }
  let orientation = if turn > 0.0 { 1.0 } else { -1.0 }
  for index in 0..<normalized.length() {
    let next = (index + 1) % normalized.length()
    for other in 0..<normalized.length() {
      if other != index &&
        other != next &&
        orientation *
        zone_cross(normalized[index], normalized[next], normalized[other]) <=
        1.0e-12 {
        raise @types.InvalidInput(
          "zone must be simple strictly convex and have no repeated vertices",
        )
      }
    }
  }
  let normals : Array[@types.Point2] = []
  for index, start in vertices_m {
    let end = vertices_m[(index + 1) % vertices_m.length()]
    let dx = checked_zone_coordinate(end.x - start.x)
    let dy = checked_zone_coordinate(end.y - start.y)
    let scale = dx.abs().max(dy.abs())
    if scale == 0.0 {
      raise @types.InvalidInput("zone edge endpoints must differ")
    }
    let sx = dx / scale
    let sy = dy / scale
    let length = checked_zone_coordinate(scale * (sx * sx + sy * sy).sqrt())
    if length <= 0.0 {
      raise @types.InvalidInput("zone edge length is not representable")
    }
    let ux = dx / length
    let uy = dy / length
    let unit_norm = ux * ux + uy * uy
    if !@types.is_finite(unit_norm) ||
      (unit_norm - 1.0).abs() > 8.881784197001252e-16 ||
      (dx != 0.0 && ux == 0.0) ||
      (dy != 0.0 && uy == 0.0) {
      raise @types.InvalidInput("zone normal loses a nonzero component")
    }
    normals.push({ x: orientation * uy, y: -orientation * ux, })
  }
  (normals, orientation)
}

///|
/// Require strict convexity with a 1e-12 cross-product margin after translating
/// and scaling the bounding box to unit extent. This construction threshold
/// does not add a tolerance to evidence classification at any supporting line.
pub fn ConvexZone::new(
  zone_id : String,
  vertices_m : Array[@types.Point2],
  sigma_multiplier~ : Double = 2.0,
) -> ConvexZone raise @types.GroundError {
  if zone_id.length() < 1 ||
    zone_id.length() > 128 ||
    vertices_m.length() < 3 ||
    vertices_m.length() > 32 ||
    !@types.is_finite(sigma_multiplier) ||
    sigma_multiplier < 0.0 {
    raise @types.InvalidInput(
      "invalid zone identity vertex count or sigma multiplier",
    )
  }
  let (normals, orientation) = validate_convex_geometry(vertices_m)
  {
    zone_id,
    sigma_multiplier,
    vertices: vertices_m.copy(),
    normals,
    orientation,
  }
}

///|
pub fn ConvexZone::vertices_m(self : ConvexZone) -> Array[@types.Point2] {
  self.vertices.copy()
}

///|
/// Evaluate current model position uncertainty along all outward faces.
/// This is a sufficient separation test, not a complete ellipse intersection.
pub fn ConvexZone::evaluate(
  self : ConvexZone,
  position : @types.Point2,
  covariance : @types.Covariance2,
) -> ZoneBand raise @types.GroundError {
  position.validate()
  covariance.validate()
  let faces : Array[ZoneFaceBand] = []
  let mut inside = true
  let mut separating_edge_index : Int32? = None
  for edge_index, start in self.vertices {
    let offset : @types.Point2 = {
      x: checked_zone_coordinate(position.x - start.x),
      y: checked_zone_coordinate(position.y - start.y),
    }
    let outward_normal = self.normals[edge_index]
    let end = self.vertices[(edge_index + 1) % self.vertices.length()]
    let edge_direction : @types.Point2 = {
      x: end.x - start.x,
      y: end.y - start.y,
    }
    let distance_m = -self.orientation *
      offset.signed_line_distance(edge_direction)
    let normal_std_m = covariance.linear_std(outward_normal)
    let radius = self.sigma_multiplier * normal_std_m
    if !@types.is_finite(radius) ||
      (self.sigma_multiplier > 0.0 && radius <= 0.0) {
      raise @types.InvalidInput("zone evidence radius is not representable")
    }
    let lower_m = distance_m - radius
    let upper_m = distance_m + radius
    if !@types.is_finite(lower_m) ||
      !@types.is_finite(upper_m) ||
      (
        self.sigma_multiplier > 0.0 &&
        (lower_m >= distance_m || upper_m <= distance_m)
      ) {
      raise @types.InvalidInput("zone evidence interval is not representable")
    }
    if upper_m > 0.0 {
      inside = false
    }
    if lower_m > 0.0 && separating_edge_index is None {
      separating_edge_index = Some(edge_index)
    }
    faces.push({
      edge_index,
      outward_normal,
      distance_m,
      normal_std_m,
      lower_m,
      upper_m,
    })
  }
  let decision = if inside {
    Inside
  } else if separating_edge_index is Some(_) {
    Outside
  } else {
    Indeterminate
  }
  {
    zone_id: self.zone_id,
    sigma_multiplier: self.sigma_multiplier,
    faces,
    decision,
    separating_edge_index,
  }
}
