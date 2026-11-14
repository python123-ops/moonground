///|
/// Validate the same strict convex geometry domain as ConvexZone, then require
/// the origin in the closed footprint without a containment epsilon. Vertex
/// order is preserved; no hull, centering or heading is inferred.
pub fn ConvexFootprint::new(
  vertices_offset_m : Array[@types.Point2],
) -> ConvexFootprint raise @types.GroundError {
  let (_, orientation) = validate_convex_geometry(vertices_offset_m)
  for index, start in vertices_offset_m {
    let end = vertices_offset_m[(index + 1) % vertices_offset_m.length()]
    let edge : @types.Point2 = { x: end.x - start.x, y: end.y - start.y, }
    let origin_offset : @types.Point2 = { x: -start.x, y: -start.y, }
    if -orientation * origin_offset.signed_line_distance(edge) > 0.0 {
      raise @types.InvalidInput(
        "convex footprint must contain the modeled anchor",
      )
    }
  }
  { vertices: vertices_offset_m.copy(), }
}

///|
pub fn ConvexFootprint::vertices_offset_m(
  self : ConvexFootprint,
) -> Array[@types.Point2] {
  self.vertices.copy()
}

///|
fn footprint_zone_support(
  zone : ConvexZone,
  footprint : ConvexFootprint,
) -> Array[FootprintSupport] raise @types.GroundError {
  let supports : Array[FootprintSupport] = []
  for index, start in zone.vertices {
    let end = zone.vertices[(index + 1) % zone.vertices.length()]
    let edge : @types.Point2 = { x: end.x - start.x, y: end.y - start.y, }
    let first = -zone.orientation *
      footprint.vertices[0].signed_line_distance(edge)
    let mut lower_m = first
    let mut upper_m = first
    for vertex in 1..<footprint.vertices.length() {
      let projected = -zone.orientation *
        footprint.vertices[vertex].signed_line_distance(edge)
      lower_m = lower_m.min(projected)
      upper_m = upper_m.max(projected)
    }
    if !@types.is_finite(lower_m) ||
      !@types.is_finite(upper_m) ||
      lower_m > 0.0 ||
      upper_m < 0.0 {
      raise @types.InvalidInput(
        "convex footprint support cannot represent anchor containment",
      )
    }
    supports.push({ lower_m, upper_m, })
  }
  supports
}

///|
fn footprint_combined_extent(
  noise : Double,
  extent : Double,
) -> Double raise @types.GroundError {
  let combined = noise + extent
  if !@types.is_finite(combined) ||
    (noise > 0.0 && (combined <= noise || combined <= extent)) {
    raise @types.InvalidInput(
      "footprint and position extent exceed supported precision",
    )
  }
  combined
}

///|
fn expand_footprint_zone(
  position : ZoneBand,
  supports : Array[FootprintSupport],
  footprint : ConvexFootprint,
) -> FootprintZoneBand raise @types.GroundError {
  let faces : Array[FootprintZoneFaceBand] = []
  let mut inside = true
  let mut separating_edge_index : Int32? = None
  for index, face in position.faces {
    let support = supports[index]
    let noise = position.sigma_multiplier * face.normal_std_m
    let lower_m = if support.lower_m == 0.0 {
      face.lower_m
    } else {
      let combined = footprint_combined_extent(noise, -support.lower_m)
      let lower = face.distance_m - combined
      if !@types.is_finite(lower) || lower >= face.lower_m {
        raise @types.InvalidInput(
          "footprint lower endpoint cannot expand the position band",
        )
      }
      lower
    }
    let upper_m = if support.upper_m == 0.0 {
      face.upper_m
    } else {
      let combined = footprint_combined_extent(noise, support.upper_m)
      let upper = face.distance_m + combined
      if !@types.is_finite(upper) || upper <= face.upper_m {
        raise @types.InvalidInput(
          "footprint upper endpoint cannot expand the position band",
        )
      }
      upper
    }
    if upper_m > 0.0 {
      inside = false
    }
    if lower_m > 0.0 && separating_edge_index is None {
      separating_edge_index = Some(face.edge_index)
    }
    faces.push({
      edge_index: face.edge_index,
      outward_normal: face.outward_normal,
      distance_m: face.distance_m,
      normal_std_m: face.normal_std_m,
      position_lower_m: face.lower_m,
      position_upper_m: face.upper_m,
      footprint_lower_m: support.lower_m,
      footprint_upper_m: support.upper_m,
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
    zone_id: position.zone_id,
    vertices_offset_m: footprint.vertices.copy(),
    sigma_multiplier: position.sigma_multiplier,
    faces,
    decision,
    separating_edge_index,
  }
}

///|
/// Evaluate deterministic ground-oriented body offsets independently of the
/// original position covariance. A zero support extent retains that endpoint
/// exactly; every positive extent must remain represented and expand it.
pub fn ConvexZone::evaluate_footprint(
  self : ConvexZone,
  position : @types.Point2,
  covariance : @types.Covariance2,
  footprint : ConvexFootprint,
) -> FootprintZoneBand raise @types.GroundError {
  let statistical = self.evaluate(position, covariance)
  expand_footprint_zone(
    statistical,
    footprint_zone_support(self, footprint),
    footprint,
  )
}
