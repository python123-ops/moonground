///|
priv struct CalibrationConsensus {
  mask : Array[Bool]
  errors : Array[Double]
  count : Int32
  rms : Double
}

///|
fn require_robust_inputs(
  control_pixels : Array[@types.Point2],
  control_world : Array[@types.Point2],
  check_pixels : Array[@types.Point2],
  check_world : Array[@types.Point2],
  roi : Array[@types.Point2],
  max_fit_error_m : Double,
  max_check_error_m : Double,
  max_meters_per_pixel : Double,
  ground_noise_floor_m : Double,
) -> Unit raise @types.GroundError {
  if control_pixels.length() != control_world.length() ||
    control_pixels.length() < 6 ||
    control_pixels.length() > 4096 ||
    check_pixels.length() != check_world.length() ||
    check_pixels.length() < 2 ||
    check_pixels.length() > 4096 {
    raise @types.InvalidInput(
      "calibration needs 6 to 4096 control pairs and 2 to 4096 check pairs",
    )
  }
  if !@types.is_finite(max_fit_error_m) ||
    max_fit_error_m <= 0.0 ||
    !@types.is_finite(max_check_error_m) ||
    max_check_error_m <= 0.0 {
    raise @types.InvalidInput("residual limits must be finite and positive")
  }
  if !@types.is_finite(max_meters_per_pixel) || max_meters_per_pixel <= 0.0 {
    raise @types.InvalidInput(
      "metres-per-pixel limit must be finite and positive",
    )
  }
  let variance = ground_noise_floor_m * ground_noise_floor_m
  if !@types.is_finite(ground_noise_floor_m) ||
    ground_noise_floor_m <= 0.0 ||
    !@types.is_finite(variance) ||
    variance <= 0.0 {
    raise @types.InvalidInput(
      "ground noise floor must have finite positive variance",
    )
  }
  let domain = make_roi(roi)
  for i in 0..<control_pixels.length() {
    require_domain_point(domain, control_pixels[i])
    control_world[i].validate()
    for j in 0..<i {
      if (
          control_pixels[i].x == control_pixels[j].x &&
          control_pixels[i].y == control_pixels[j].y
        ) ||
        (
          control_world[i].x == control_world[j].x &&
          control_world[i].y == control_world[j].y
        ) {
        raise @types.InvalidInput("control points contain duplicates")
      }
    }
  }
  // Check every original control, including pairs that consensus may exclude.
  require_independent_checks(
    control_pixels, control_world, check_pixels, check_world, domain,
  )
}

///|
// All pixels have already passed the common ROI check. Use the same checked
// homogeneous arithmetic as map_point without repeating polygon membership.
fn classify_controls(
  model : GroundCalibration,
  pixels : Array[@types.Point2],
  world : Array[@types.Point2],
  threshold : Double,
) -> CalibrationConsensus raise @types.GroundError {
  let errors : Array[Double] = []
  let mask : Array[Bool] = []
  let mut count = 0
  let mut maximum = 0.0
  for i in 0..<pixels.length() {
    let error = stable_distance(
      map_unchecked(model.coefficients, pixels[i]),
      world[i],
    )
    let inlier = error <= threshold
    errors.push(error)
    mask.push(inlier)
    if inlier {
      count += 1
      maximum = maximum.max(error)
    }
  }
  let mut squares = 0.0
  if maximum > 0.0 {
    for i in 0..<errors.length() {
      if mask[i] {
        let scaled = errors[i] / maximum
        squares += scaled * scaled / count.to_double()
      }
    }
  }
  let rms = maximum * squares.sqrt()
  if !@types.is_finite(rms) {
    raise @types.InvalidInput("robust residual score is not finite")
  }
  { mask, errors, count, rms, }
}

///|
fn require_consensus(
  consensus : CalibrationConsensus,
  options : RobustFitOptions,
) -> Unit raise @types.GroundError {
  if consensus.count < 6 ||
    consensus.count.to_double() / consensus.mask.length().to_double() <
    options.min_inlier_ratio {
    raise @types.InvalidInput("robust calibration has insufficient consensus")
  }
}

///|
fn select_inlier_points(
  points : Array[@types.Point2],
  mask : Array[Bool],
) -> Array[@types.Point2] {
  let result : Array[@types.Point2] = []
  for i in 0..<points.length() {
    if mask[i] {
      result.push(points[i])
    }
  }
  result
}

///|
fn exhaustive_six_count(length : Int32, budget : Int32) -> Int32? {
  if length > 12 {
    return None
  }
  let mut count = 1
  for i in 1..<=6 {
    count = count * (length - 6 + i) / i
  }
  if count <= budget {
    Some(count)
  } else {
    None
  }
}

///|
fn next_six_combination(indices : Array[Int32], length : Int32) -> Unit {
  let mut index = 5
  while index >= 0 {
    if indices[index] < length - 6 + index {
      indices[index] += 1
      for next in (index + 1)..<6 {
        indices[next] = indices[next - 1] + 1
      }
      return
    }
    index -= 1
  }
}

///|
// Explicit little-endian Int32 followed by 28 zero bytes, independent of the
// host, locale and platform entropy. The pinned core supplies ChaCha8/shuffle.
fn robust_random(seed : Int32) -> @random.Rand {
  let bytes = FixedArray::make(32, b'\x00')
  for i in 0..<4 {
    bytes[i] = (seed.reinterpret_as_uint() >> (i * 8)).to_byte()
  }
  @random.Rand::chacha8(seed=Bytes::from_array(bytes))
}
