///|
fn robust_pixels() -> Array[@types.Point2] {
  [
    { x: 0.0, y: 0.0, },
    { x: 25.0, y: 0.0, },
    { x: 50.0, y: 0.0, },
    { x: 75.0, y: 0.0, },
    { x: 0.0, y: 100.0, },
    { x: 100.0, y: 100.0, },
    { x: 100.0, y: 25.0, },
    { x: 20.0, y: 70.0, },
    { x: 70.0, y: 50.0, },
    { x: 40.0, y: 35.0, },
  ]
}

///|
fn robust_world(points : Array[@types.Point2]) -> Array[@types.Point2] {
  points.map(p => {
    let w = 1.0 + 0.001 * p.x - 0.0003 * p.y
    @types.Point2::{
      x: (0.1 * p.x + 0.015 * p.y + 1.0) / w,
      y: (-0.005 * p.x + 0.08 * p.y + 2.0) / w,
    }
  })
}

///|
fn contaminated_world(points : Array[@types.Point2]) -> Array[@types.Point2] {
  let world = robust_world(points)
  world[1] = { x: world[1].x + 20.0, y: world[1].y - 10.0, }
  world[8] = { x: world[8].x - 15.0, y: world[8].y + 30.0, }
  world
}

///|
fn robust_options(
  threshold~ : Double = 0.000001,
  ratio~ : Double = 0.7,
  trials~ : Int32 = 512,
  seed~ : Int32 = 1,
) -> @calibration.RobustFitOptions raise @types.GroundError {
  @calibration.RobustFitOptions::new(
    inlier_threshold_m=threshold,
    min_inlier_ratio=ratio,
    max_trials=trials,
    seed~,
  )
}

///|
fn assert_robust_consistent(
  result : @calibration.RobustCalibration,
  pixels : Array[@types.Point2],
  world : Array[@types.Point2],
  threshold : Double,
) -> Unit raise {
  let mask = result.inlier_mask()
  let errors = result.control_errors_m()
  assert_eq(mask.length(), pixels.length())
  assert_eq(errors.length(), pixels.length())
  let mut count = 0
  for i in 0..<pixels.length() {
    let p = result.calibration().map_point(pixels[i])
    let dx = p.x - world[i].x
    let dy = p.y - world[i].y
    let expected = (dx * dx + dy * dy).sqrt()
    close(errors[i], expected)
    assert_eq(mask[i], errors[i] <= threshold)
    if mask[i] {
      count += 1
    }
  }
  assert_eq(result.inlier_count(), count)
  assert_eq(result.calibration().report().fit_count(), count)
  assert_true(result.valid_hypotheses() > 0)
  assert_true(result.valid_hypotheses() <= result.trials_run())
  assert_true(result.refinement_steps() >= 1 && result.refinement_steps() <= 8)
}

///|
test "robust calibration recovers a projective map with first four collinear and two outliers" {
  let pixels = robust_pixels()
  let world = contaminated_world(pixels)
  let checks = check_pixels()
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit(
        pixels,
        world,
        checks,
        robust_world(checks),
        rectangle(),
      ),
    )
  })
  let result = @calibration.GroundCalibration::fit_robust(
    pixels,
    world,
    checks,
    robust_world(checks),
    rectangle(),
    options=robust_options(),
  )
  assert_eq(result.inlier_mask(), [
    true, false, true, true, true, true, true, true, false, true,
  ])
  assert_eq(result.inlier_count(), 8)
  assert_eq(result.trials_run(), 210)
  assert_eq(result.calibration().report().check_count(), 2)
  assert_true(
    result.calibration().report().fit_max_error_m().unwrap() < 1.0e-10,
  )
  assert_true(
    result.calibration().report().check_max_error_m().unwrap() < 1.0e-10,
  )
  assert_robust_consistent(result, pixels, world, 0.000001)
  let expected = robust_world([{ x: 45.0, y: 63.0, }])[0]
  let actual = result.calibration().map_point({ x: 45.0, y: 63.0, })
  close(actual.x, expected.x)
  close(actual.y, expected.y)
  let mask = result.inlier_mask()
  let errors = result.control_errors_m()
  mask[0] = false
  errors[0] = 999.0
  assert_true(result.inlier_mask()[0])
  assert_true(result.control_errors_m()[0] < 0.000001)
}

///|
test "robust checks remain independent of every original control including excluded pairs" {
  let pixels = robust_pixels()
  let world = contaminated_world(pixels)
  let checks = check_pixels()
  let invalid_checks = [pixels[1], checks[1]]
  let reused_world = robust_world(checks)
  reused_world[0] = world[1]
  for
    (test_pixels, test_world) in [
      (invalid_checks, robust_world(invalid_checks)),
      (checks, reused_world),
    ] {
    try
      @calibration.GroundCalibration::fit_robust(
        pixels,
        world,
        test_pixels,
        test_world,
        rectangle(),
        options=robust_options(),
        max_check_error_m=1000.0,
      )
    catch {
      @types.InvalidInput(message) =>
        assert_true(message.contains("independent"))
    } noraise {
      _ => fail("excluded control leaked into independent checks")
    }
  }
}

///|
test "holdout changes never rank robust models and every holdout must pass" {
  let pixels = robust_pixels()
  let world = contaminated_world(pixels)
  let checks = check_pixels()
  let shifted = robust_world(checks)
  shifted[0] = { x: shifted[0].x + 0.3, y: shifted[0].y, }
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit_robust(
        pixels,
        world,
        checks,
        shifted,
        rectangle(),
        options=robust_options(),
      ),
    )
  })
  let baseline = @calibration.GroundCalibration::fit_robust(
    pixels,
    world,
    checks,
    robust_world(checks),
    rectangle(),
    options=robust_options(),
  )
  let accepted = @calibration.GroundCalibration::fit_robust(
    pixels,
    world,
    checks,
    shifted,
    rectangle(),
    options=robust_options(),
    max_check_error_m=0.31,
  )
  assert_eq(accepted.calibration().matrix(), baseline.calibration().matrix())
  assert_eq(accepted.inlier_mask(), baseline.inlier_mask())
  assert_eq(accepted.control_errors_m(), baseline.control_errors_m())
  close(accepted.calibration().report().check_max_error_m().unwrap(), 0.3)
}

///|
test "robust fit gate is separate from consensus threshold and ground noise floor" {
  let pixels = robust_pixels()
  let world = robust_world(pixels)
  world[9] = { x: world[9].x + 0.02, y: world[9].y, }
  let checks = check_pixels()
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit_robust(
        pixels,
        world,
        checks,
        robust_world(checks),
        rectangle(),
        options=robust_options(threshold=0.1, ratio=1.0),
        max_fit_error_m=0.000000001,
        ground_noise_floor_m=1000.0,
      ),
    )
  })
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit_robust(
        pixels,
        contaminated_world(pixels),
        checks,
        robust_world(checks),
        rectangle(),
        options=robust_options(ratio=0.9),
      ),
    )
  })
}

///|
test "robust search budgets and seeded random runs are bounded and reproducible" {
  let pixels = control_pixels()
  let checks = check_pixels()
  let exact = @calibration.GroundCalibration::fit_robust(
    pixels,
    exact_world(pixels),
    checks,
    exact_world(checks),
    rectangle(),
    options=robust_options(trials=1),
  )
  assert_eq(exact.trials_run(), 1)
  assert_eq(exact.valid_hypotheses(), 1)
  assert_eq(exact.refinement_steps(), 1)
  let more = robust_pixels()
  let options = robust_options(trials=7, seed=17)
  let first = @calibration.GroundCalibration::fit_robust(
    more,
    robust_world(more),
    checks,
    robust_world(checks),
    rectangle(),
    options~,
  )
  let second = @calibration.GroundCalibration::fit_robust(
    more,
    robust_world(more),
    checks,
    robust_world(checks),
    rectangle(),
    options~,
  )
  assert_eq(first.trials_run(), 7)
  assert_eq(first.valid_hypotheses(), second.valid_hypotheses())
  assert_eq(first.calibration().matrix(), second.calibration().matrix())
  assert_eq(first.inlier_mask(), second.inlier_mask())
  assert_eq(first.control_errors_m(), second.control_errors_m())
  assert_robust_consistent(
    first,
    more,
    robust_world(more),
    options.inlier_threshold_m,
  )
}

///|
test "robust options reject nonfinite values invalid ranges and unbounded budgets" {
  let nan = 0.0 / 0.0
  let inf = 1.0 / 0.0
  for value in [nan, inf, -1.0, 0.0] {
    expect_invalid(() => {
      ignore(@calibration.RobustFitOptions::new(inlier_threshold_m=value))
    })
    expect_invalid(() => {
      ignore(@calibration.RobustFitOptions::new(min_inlier_ratio=value))
    })
  }
  expect_invalid(() => {
    ignore(@calibration.RobustFitOptions::new(min_inlier_ratio=1.01))
  })
  for trials in [0, -1, 4097] {
    expect_invalid(() => {
      ignore(@calibration.RobustFitOptions::new(max_trials=trials))
    })
  }
  for seed in [0, -1] {
    expect_invalid(() => ignore(@calibration.RobustFitOptions::new(seed~)))
  }
  let endpoint = @calibration.RobustFitOptions::new(
    min_inlier_ratio=1.0,
    max_trials=4096,
    seed=2147483647,
  )
  assert_eq(endpoint.seed, 2147483647)
  assert_eq(endpoint.max_trials, 4096)
}

///|
test "extreme finite excluded worlds do not invalidate the distributed inlier set" {
  let pixels = robust_pixels()
  let world = robust_world(pixels)
  world[1] = { x: 1.0e100, y: -1.0e100, }
  world[8] = { x: 2.0e100, y: 1.0e100, }
  let checks = check_pixels()
  let result = @calibration.GroundCalibration::fit_robust(
    pixels,
    world,
    checks,
    robust_world(checks),
    rectangle(),
    options=robust_options(),
  )
  assert_eq(result.inlier_count(), 8)
  let errors = result.control_errors_m()
  assert_true(@types.is_finite(errors[1]) && @types.is_finite(errors[8]))
  assert_true(errors[1] > 1.0e100 && errors[8] > 2.0e100)
  assert_true(
    result.calibration().report().check_max_error_m().unwrap() < 1.0e-10,
  )
}

///|
test "robust normalized fitting supports translated large pixel coordinates" {
  let original = robust_pixels()
  let checks = check_pixels()
  let transform = (p : @types.Point2) => @types.Point2::{
    x: 100000000.0 + 1000.0 * p.x,
    y: -200000000.0 + 1000.0 * p.y,
  }
  let pixels = original.map(transform)
  let shifted_checks = checks.map(transform)
  let result = @calibration.GroundCalibration::fit_robust(
    pixels,
    contaminated_world(original),
    shifted_checks,
    robust_world(checks),
    rectangle().map(transform),
    options=robust_options(),
  )
  assert_eq(result.inlier_count(), 8)
  assert_true(
    result.calibration().report().check_max_error_m().unwrap() < 0.000001,
  )
  assert_robust_consistent(
    result,
    pixels,
    contaminated_world(original),
    0.000001,
  )
}

///|
test "robust structural validation rejects duplicates invalid points and insufficient consensus" {
  let pixels = robust_pixels()
  let checks = check_pixels()
  let world = robust_world(pixels)
  let duplicate_pixels = pixels.copy()
  duplicate_pixels[1] = duplicate_pixels[0]
  let duplicate_world = world.copy()
  duplicate_world[1] = duplicate_world[0]
  let nonfinite_world = world.copy()
  nonfinite_world[1] = { x: 1.0 / 0.0, y: 0.0, }
  for
    (p, w) in [
      (duplicate_pixels, world),
      (pixels, duplicate_world),
      (pixels, nonfinite_world),
    ] {
    expect_invalid(() => {
      ignore(
        @calibration.GroundCalibration::fit_robust(
          p,
          w,
          checks,
          robust_world(checks),
          rectangle(),
        ),
      )
    })
  }
  let few = pixels[:5].to_owned()
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit_robust(
        few,
        robust_world(few),
        checks,
        robust_world(checks),
        rectangle(),
      ),
    )
  })
  let too_few_inliers = world.copy()
  for i in 0..<5 {
    too_few_inliers[i] = {
      x: world[i].x + 10.0 + i.to_double(),
      y: world[i].y - 17.0,
    }
  }
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit_robust(
        pixels,
        too_few_inliers,
        checks,
        robust_world(checks),
        rectangle(),
        options=robust_options(ratio=0.1),
      ),
    )
  })
}
