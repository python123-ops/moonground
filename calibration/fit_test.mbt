///|
fn control_pixels() -> Array[@types.Point2] {
  [
    { x: 0.0, y: 0.0, },
    { x: 100.0, y: 0.0, },
    { x: 100.0, y: 100.0, },
    { x: 0.0, y: 100.0, },
    { x: 25.0, y: 50.0, },
    { x: 70.0, y: 30.0, },
  ]
}

///|
fn exact_world(pixels : Array[@types.Point2]) -> Array[@types.Point2] {
  pixels.map(fn(p) {
    @types.Point2::{
      x: 0.1 * p.x + 0.02 * p.y + 1.0,
      y: -0.01 * p.x + 0.2 * p.y - 2.0,
    }
  })
}

///|
fn check_pixels() -> Array[@types.Point2] {
  [{ x: 30.0, y: 20.0, }, { x: 60.0, y: 80.0, }]
}

///|
test "multi-point fit accepts independent exact holdout pairs" {
  let controls = control_pixels()
  let checks = check_pixels()
  let calibration = @calibration.GroundCalibration::fit(
    controls,
    exact_world(controls),
    checks,
    exact_world(checks),
    rectangle(),
  )
  let report = calibration.report()
  assert_eq(report.fit_count(), 6)
  assert_eq(report.check_count(), 2)
  assert_true(report.fit_rms_m().unwrap() < 1.0e-10)
  assert_true(report.fit_max_error_m().unwrap() < 1.0e-10)
  assert_true(report.check_rms_m().unwrap() < 1.0e-10)
  assert_true(report.check_max_error_m().unwrap() < 1.0e-10)
  let point = @types.Point2::new(40.0, 70.0)
  let mapped = calibration.map_point(point)
  close(mapped.x, 6.4)
  close(mapped.y, 11.6)
}

///|
test "multi-point calibration fits a projective rather than only affine map" {
  let project = fn(p : @types.Point2) {
    let denominator = 1.0 + 0.001 * p.x - 0.0003 * p.y
    @types.Point2::{
      x: (0.1 * p.x + 0.015 * p.y + 1.0) / denominator,
      y: (-0.005 * p.x + 0.08 * p.y + 2.0) / denominator,
    }
  }
  let controls = control_pixels()
  let checks = check_pixels()
  let calibration = @calibration.GroundCalibration::fit(
    controls,
    controls.map(project),
    checks,
    checks.map(project),
    rectangle(),
  )
  let expected = project({ x: 45.0, y: 70.0, })
  let actual = calibration.map_point({ x: 45.0, y: 70.0, })
  close(actual.x, expected.x)
  close(actual.y, expected.y)
}

///|
test "fit and independent validation have separate maximum residual gates" {
  let controls = control_pixels()
  let checks = check_pixels()
  let bad_world = exact_world(controls)
  bad_world[4] = { x: bad_world[4].x + 1.0, y: bad_world[4].y, }
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit(
        controls,
        bad_world,
        checks,
        exact_world(checks),
        rectangle(),
        max_fit_error_m=0.01,
      ),
    )
  })
  let shifted_checks = exact_world(checks)
  shifted_checks[0] = { x: shifted_checks[0].x + 0.21, y: shifted_checks[0].y, }
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit(
        controls,
        exact_world(controls),
        checks,
        shifted_checks,
        rectangle(),
      ),
    )
  })
  let accepted = @calibration.GroundCalibration::fit(
    controls,
    exact_world(controls),
    checks,
    shifted_checks,
    rectangle(),
    max_check_error_m=0.22,
  )
  close(accepted.report().check_max_error_m().unwrap(), 0.21)
  close(accepted.report().check_rms_m().unwrap(), 0.21 / 2.0.sqrt())
}

///|
test "fit rejects insufficient mismatched duplicate and collinear controls" {
  let controls = control_pixels()
  let checks = check_pixels()
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit(
        controls[:5].to_owned(),
        exact_world(controls)[:5].to_owned(),
        checks,
        exact_world(checks),
        rectangle(),
      ),
    )
  })
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit(
        controls,
        [],
        checks,
        exact_world(checks),
        rectangle(),
      ),
    )
  })
  let duplicate = control_pixels()
  duplicate[5] = duplicate[4]
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit(
        duplicate,
        exact_world(duplicate),
        checks,
        exact_world(checks),
        rectangle(),
      ),
    )
  })
  let collinear = [
    @types.Point2::{ x: 0.0, y: 0.0, },
    { x: 10.0, y: 10.0, },
    { x: 20.0, y: 20.0, },
    { x: 30.0, y: 30.0, },
    { x: 40.0, y: 40.0, },
    { x: 50.0, y: 50.0, },
  ]
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit(
        collinear,
        exact_world(collinear),
        checks,
        exact_world(checks),
        rectangle(),
      ),
    )
  })
}

///|
test "holdout points cannot reuse controls or each other" {
  let controls = control_pixels()
  let checks = check_pixels()
  for invalid_checks in [[controls[0], checks[0]], [checks[0], checks[0]]] {
    expect_invalid(() => {
      ignore(
        @calibration.GroundCalibration::fit(
          controls,
          exact_world(controls),
          invalid_checks,
          exact_world(invalid_checks),
          rectangle(),
        ),
      )
    })
  }
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit(
        controls,
        exact_world(controls),
        [checks[0]],
        exact_world([checks[0]]),
        rectangle(),
      ),
    )
  })
}

///|
test "fitting refuses out-of-domain controls and nonfinite limits" {
  let controls = control_pixels()
  let checks = check_pixels()
  let outside = control_pixels()
  outside[5] = { x: 101.0, y: 30.0, }
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit(
        outside,
        exact_world(outside),
        checks,
        exact_world(checks),
        rectangle(),
      ),
    )
  })
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::fit(
        controls,
        exact_world(controls),
        checks,
        exact_world(checks),
        rectangle(),
        max_check_error_m=1.0 / 0.0,
      ),
    )
  })
}
