///|
fn robust_candidate(
  pixels : Array[@types.Point2],
  world : Array[@types.Point2],
  indices : Array[Int32],
  roi : Array[@types.Point2],
  options : RobustFitOptions,
  maximum_scale : Double,
  noise_floor : Double,
) -> CalibrationConsensus raise @types.GroundError {
  let sample_pixels = indices.map(index => pixels[index])
  let sample_world = indices.map(index => world[index])
  require_distributed_points(sample_pixels)
  require_distributed_points(sample_world)
  let model = fit_control_model(
    sample_pixels,
    sample_world,
    roi,
    max_meters_per_pixel=maximum_scale,
    ground_noise_floor_m=noise_floor,
  )
  classify_controls(model, pixels, world, options.inlier_threshold_m)
}

///|
fn refine_consensus(
  initial : CalibrationConsensus,
  pixels : Array[@types.Point2],
  world : Array[@types.Point2],
  roi : Array[@types.Point2],
  options : RobustFitOptions,
  maximum_scale : Double,
  noise_floor : Double,
) -> (CalibrationConsensus, Int32) raise @types.GroundError {
  let mut previous = initial
  require_consensus(previous, options)
  for step in 1..<=8 {
    let inlier_pixels = select_inlier_points(pixels, previous.mask)
    let inlier_world = select_inlier_points(world, previous.mask)
    require_distributed_points(inlier_pixels)
    require_distributed_points(inlier_world)
    let model = fit_control_model(
      inlier_pixels,
      inlier_world,
      roi,
      max_meters_per_pixel=maximum_scale,
      ground_noise_floor_m=noise_floor,
    )
    let current = classify_controls(
      model,
      pixels,
      world,
      options.inlier_threshold_m,
    )
    require_consensus(current, options)
    if current.mask == previous.mask {
      return (current, step)
    }
    previous = current
  }
  raise @types.InvalidInput(
    "robust calibration consensus did not stabilize in 8 refits",
  )
}

///|
/// Search only the control pairs using six-point normalized geometry fits.
/// At least six final inliers and all independent hold-out pairs must pass.
/// Every error and mask entry is recomputed from the returned calibration;
/// the ground noise floor does not relax any correspondence residual gate.
pub fn GroundCalibration::fit_robust(
  control_pixels : Array[@types.Point2],
  control_world : Array[@types.Point2],
  check_pixels : Array[@types.Point2],
  check_world : Array[@types.Point2],
  roi : Array[@types.Point2],
  options? : RobustFitOptions,
  max_fit_error_m~ : Double = 0.1,
  max_check_error_m~ : Double = 0.2,
  max_meters_per_pixel~ : Double = 0.5,
  ground_noise_floor_m~ : Double = 0.001,
) -> RobustCalibration raise @types.GroundError {
  let options = match options {
    Some(options) => options
    None => RobustFitOptions::new()
  }
  require_robust_inputs(
    control_pixels, control_world, check_pixels, check_world, roi, max_fit_error_m,
    max_check_error_m, max_meters_per_pixel, ground_noise_floor_m,
  )
  let exhaustive = exhaustive_six_count(
    control_pixels.length(),
    options.max_trials,
  )
  let trials = exhaustive.unwrap_or(options.max_trials)
  let indices = Array::makei(6, i => i)
  let pool = Array::makei(control_pixels.length(), i => i)
  let random = robust_random(options.seed)
  let mut best : CalibrationConsensus? = None
  let mut valid_hypotheses = 0
  for _ in 0..<trials {
    let selected = match exhaustive {
      Some(_) => indices.copy()
      None => {
        random.shuffle(pool.length(), fn(i, j) {
          let temporary = pool[i]
          pool[i] = pool[j]
          pool[j] = temporary
        })
        pool[:6].to_owned()
      }
    }
    if exhaustive is Some(_) {
      next_six_combination(indices, control_pixels.length())
    }
    let candidate = robust_candidate(
      control_pixels, control_world, selected, roi, options, max_meters_per_pixel,
      ground_noise_floor_m,
    ) catch {
      _ => continue
    }
    valid_hypotheses += 1
    match best {
      None => best = Some(candidate)
      Some(incumbent) =>
        if candidate.count > incumbent.count ||
          (candidate.count == incumbent.count && candidate.rms < incumbent.rms) {
          best = Some(candidate)
        }
    }
  }
  let best = match best {
    Some(best) => best
    None =>
      raise @types.InvalidInput("robust calibration found no valid hypothesis")
  }
  let (refined, refinement_steps) = refine_consensus(
    best, control_pixels, control_world, roi, options, max_meters_per_pixel, ground_noise_floor_m,
  )
  let calibration = GroundCalibration::fit(
    select_inlier_points(control_pixels, refined.mask),
    select_inlier_points(control_world, refined.mask),
    check_pixels,
    check_world,
    roi,
    max_fit_error_m~,
    max_check_error_m~,
    max_meters_per_pixel~,
    ground_noise_floor_m~,
  )
  let validated = classify_controls(
    calibration,
    control_pixels,
    control_world,
    options.inlier_threshold_m,
  )
  require_consensus(validated, options)
  if validated.mask != refined.mask {
    raise @types.InvalidInput("final calibration changed the robust consensus")
  }
  {
    calibration_value: calibration,
    mask_value: validated.mask,
    errors_value: validated.errors,
    inlier_count_value: validated.count,
    trials_value: trials,
    valid_hypotheses_value: valid_hypotheses,
    refinement_steps_value: refinement_steps,
  }
}
