///|
pub fn DiskFootprint::new(
  radius_m : Double,
) -> DiskFootprint raise @types.GroundError {
  if !@types.is_finite(radius_m) || radius_m < 0.0 {
    raise @types.InvalidInput(
      "disk footprint radius must be finite and nonnegative",
    )
  }
  { radius_m, }
}

///|
fn expand_disk_zone(
  position : ZoneBand,
  footprint : DiskFootprint,
) -> DiskZoneBand raise @types.GroundError {
  let radius_m = footprint.radius_m
  let faces : Array[DiskZoneFaceBand] = []
  let mut inside = true
  let mut separating_edge_index : Int32? = None
  for face in position.faces {
    let (lower_m, upper_m) = if radius_m == 0.0 {
      (face.lower_m, face.upper_m)
    } else {
      let noise = position.sigma_multiplier * face.normal_std_m
      let combined = noise + radius_m
      if !@types.is_finite(combined) ||
        (noise > 0.0 && (combined <= noise || combined <= radius_m)) {
        raise @types.InvalidInput(
          "disk and position radius exceed supported precision",
        )
      }
      let lower = face.distance_m - combined
      let upper = face.distance_m + combined
      if !@types.is_finite(lower) ||
        !@types.is_finite(upper) ||
        lower >= face.lower_m ||
        upper <= face.upper_m {
        raise @types.InvalidInput(
          "disk evidence interval cannot expand the position band",
        )
      }
      (lower, upper)
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
      lower_m,
      upper_m,
    })
  }
  let decision = if radius_m == 0.0 {
    position.decision
  } else if inside {
    Inside
  } else if separating_edge_index is Some(_) {
    Outside
  } else {
    Indeterminate
  }
  {
    zone_id: position.zone_id,
    radius_m,
    sigma_multiplier: position.sigma_multiplier,
    faces,
    decision,
    separating_edge_index: if radius_m == 0.0 {
      position.separating_edge_index
    } else {
      separating_edge_index
    },
  }
}

///|
/// Expand the original position evidence by a deterministic centered disk.
/// Zero radius preserves every original bound and decision. A positive radius
/// must retain both positive contributions and strictly expand both endpoints;
/// it cannot conceal an unsupported original position band.
pub fn ConvexZone::evaluate_disk(
  self : ConvexZone,
  position : @types.Point2,
  covariance : @types.Covariance2,
  footprint : DiskFootprint,
) -> DiskZoneBand raise @types.GroundError {
  expand_disk_zone(self.evaluate(position, covariance), footprint)
}
