///|
fn require_distributed_points(
  points : Array[@types.Point2],
) -> Unit raise @types.GroundError {
  let first = points[0]
  let mut min_x = first.x
  let mut max_x = first.x
  let mut min_y = first.y
  let mut max_y = first.y
  for point in points {
    point.validate()
    min_x = min_x.min(point.x)
    max_x = max_x.max(point.x)
    min_y = min_y.min(point.y)
    max_y = max_y.max(point.y)
  }
  let extent = (max_x - min_x).max(max_y - min_y)
  if !@types.is_finite(extent) || extent <= 0.0 {
    raise @types.GroundError::InvalidInput(
      "control points have no finite spread",
    )
  }
  let normalized = points.map(fn(point) {
    @types.Point2::{
      x: (point.x - min_x) / extent,
      y: (point.y - min_y) / extent,
    }
  })
  let mut center_x = 0.0
  let mut center_y = 0.0
  for point in normalized {
    center_x += point.x / points.length().to_double()
    center_y += point.y / points.length().to_double()
  }
  let mut xx = 0.0
  let mut xy = 0.0
  let mut yy = 0.0
  for i in 0..<normalized.length() {
    let point = normalized[i]
    let x = point.x - center_x
    let y = point.y - center_y
    xx += x * x
    xy += x * y
    yy += y * y
    for j in 0..<i {
      let dx = point.x - normalized[j].x
      let dy = point.y - normalized[j].y
      if dx * dx + dy * dy <= 1.0e-24 {
        raise @types.GroundError::InvalidInput(
          "control points contain duplicates",
        )
      }
    }
  }
  let trace = xx + yy
  if (xx * yy - xy * xy) / (trace * trace) <= 1.0e-12 {
    raise @types.GroundError::InvalidInput(
      "control points are nearly collinear",
    )
  }
}

///|
fn stable_distance(
  a : @types.Point2,
  b : @types.Point2,
) -> Double raise @types.GroundError {
  let x = (a.x - b.x).abs()
  let y = (a.y - b.y).abs()
  let scale = x.max(y)
  if !@types.is_finite(scale) {
    raise @types.GroundError::InvalidInput("calibration residual overflowed")
  }
  if scale == 0.0 {
    0.0
  } else {
    let result = scale *
      (x / scale * (x / scale) + y / scale * (y / scale)).sqrt()
    if !@types.is_finite(result) {
      raise @types.GroundError::InvalidInput("calibration residual overflowed")
    }
    result
  }
}

///|
fn residual_summary(
  calibration : GroundCalibration,
  pixels : Array[@types.Point2],
  world : Array[@types.Point2],
) -> (Double, Double) raise @types.GroundError {
  let errors = pixels.mapi((i, point) => {
    stable_distance(calibration.map_point(point), world[i])
  })
  let mut largest = 0.0
  for error in errors {
    largest = largest.max(error)
  }
  if largest == 0.0 {
    return (0.0, 0.0)
  }
  let mut squares = 0.0
  for error in errors {
    let scaled = error / largest
    squares += scaled * scaled / errors.length().to_double()
  }
  (largest * squares.sqrt(), largest)
}

///|
/// Fit at least six control pairs, then validate at least two independent
/// hold-out pairs. All pixels must be undistorted and within the same ROI.
/// Thresholds apply to the maximum Euclidean residual in metres, not RMS.
/// The published geometry package supplies normalized multi-point fitting;
/// this path deliberately does not call its 0.2.2 RANSAC estimator.
pub fn GroundCalibration::fit(
  control_pixels : Array[@types.Point2],
  control_world : Array[@types.Point2],
  check_pixels : Array[@types.Point2],
  check_world : Array[@types.Point2],
  roi : Array[@types.Point2],
  max_fit_error_m~ : Double = 0.1,
  max_check_error_m~ : Double = 0.2,
  max_meters_per_pixel~ : Double = 0.5,
  ground_noise_floor_m~ : Double = 0.001,
) -> GroundCalibration raise @types.GroundError {
  if control_pixels.length() != control_world.length() ||
    control_pixels.length() < 6 ||
    control_pixels.length() > 4096 ||
    check_pixels.length() != check_world.length() ||
    check_pixels.length() < 2 ||
    check_pixels.length() > 4096 {
    raise @types.GroundError::InvalidInput(
      "calibration needs 6 to 4096 control pairs and 2 to 4096 check pairs",
    )
  }
  if !@types.is_finite(max_fit_error_m) ||
    max_fit_error_m <= 0.0 ||
    !@types.is_finite(max_check_error_m) ||
    max_check_error_m <= 0.0 {
    raise @types.GroundError::InvalidInput(
      "residual limits must be finite and positive",
    )
  }
  require_distributed_points(control_pixels)
  require_distributed_points(control_world)
  let domain = make_roi(roi)
  for point in control_pixels {
    require_domain_point(domain, point)
  }
  require_independent_checks(
    control_pixels, control_world, check_pixels, check_world, domain,
  )
  let imported = fit_control_model(
    control_pixels,
    control_world,
    roi,
    max_meters_per_pixel~,
    ground_noise_floor_m~,
  )
  let (fit_rms, fit_max) = residual_summary(
    imported, control_pixels, control_world,
  )
  let (check_rms, check_max) = residual_summary(
    imported, check_pixels, check_world,
  )
  if fit_max > max_fit_error_m {
    raise @types.GroundError::InvalidInput("control residual exceeds fit limit")
  }
  if check_max > max_check_error_m {
    raise @types.GroundError::InvalidInput(
      "hold-out residual exceeds check limit",
    )
  }
  {
    ..imported,
    report_value: {
      fit_count_value: control_pixels.length(),
      check_count_value: check_pixels.length(),
      fit_rms_value: Some(fit_rms),
      fit_max_value: Some(fit_max),
      check_rms_value: Some(check_rms),
      check_max_value: Some(check_max),
      roi_scale_bound_value: imported.report_value.roi_scale_bound_value,
    },
  }
}

///|
fn require_independent_checks(
  control_pixels : Array[@types.Point2],
  control_world : Array[@types.Point2],
  check_pixels : Array[@types.Point2],
  check_world : Array[@types.Point2],
  domain : ConvexRoi,
) -> Unit raise @types.GroundError {
  for i in 0..<check_pixels.length() {
    require_domain_point(domain, check_pixels[i])
    check_world[i].validate()
    for j in 0..<control_pixels.length() {
      if (
          check_pixels[i].x == control_pixels[j].x &&
          check_pixels[i].y == control_pixels[j].y
        ) ||
        (
          check_world[i].x == control_world[j].x &&
          check_world[i].y == control_world[j].y
        ) {
        raise @types.GroundError::InvalidInput(
          "check points must be independent of controls",
        )
      }
    }
    for j in 0..<i {
      if (
          check_pixels[i].x == check_pixels[j].x &&
          check_pixels[i].y == check_pixels[j].y
        ) ||
        (
          check_world[i].x == check_world[j].x &&
          check_world[i].y == check_world[j].y
        ) {
        raise @types.GroundError::InvalidInput(
          "check points contain duplicates",
        )
      }
    }
  }
}

///|
// Both strict and robust paths use the same published geometry solver and
// the same complete calibration-domain validation.
fn fit_control_model(
  control_pixels : Array[@types.Point2],
  control_world : Array[@types.Point2],
  roi : Array[@types.Point2],
  max_meters_per_pixel~ : Double,
  ground_noise_floor_m~ : Double,
) -> GroundCalibration raise @types.GroundError {
  let source = control_pixels.map(fn(point) {
    @geometry.Point2::new(x=point.x, y=point.y)
  })
  let target = control_world.map(fn(point) {
    @geometry.Point2::new(x=point.x, y=point.y)
  })
  let model = @multiview.estimate_homography(source, target) catch {
    _ => raise @types.GroundError::InvalidInput("homography fitting failed")
  }
  let h = model.matrix
  GroundCalibration::from_homography(
    [h.m00, h.m01, h.m02, h.m10, h.m11, h.m12, h.m20, h.m21, h.m22],
    roi,
    max_meters_per_pixel~,
    ground_noise_floor_m~,
  )
}
