///|
fn close(
  actual : Double,
  expected : Double,
  tolerance~ : Double = 1.0e-8,
) -> Unit raise {
  assert_true((actual - expected).abs() <= tolerance)
}

///|
fn invalid(action : () -> Unit raise @types.GroundError) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("unsafe camera input was accepted")
  }
}

///|
fn model() -> @camera.CameraModel raise @types.GroundError {
  @camera.CameraModel::new(
    fx=850.0,
    fy=610.0,
    cx=640.0,
    cy=360.0,
    k1=0.035,
    k2=-0.006,
    p1=0.002,
    p2=-0.0015,
    k3=0.001,
    max_normalized_radius=0.8,
  )
}

///|
// Independent forward fixture: this does not call the inverse or geometry
// dependency, so a swapped tangential term or pixel scale cannot cancel out.
fn raw_pixel(x : Double, y : Double) -> @types.Point2 {
  let radius = x * x + y * y
  let radial = 1.0 +
    0.035 * radius -
    0.006 * radius * radius +
    0.001 * radius * radius * radius
  {
    x: 850.0 * (x * radial + 0.004 * x * y - 0.0015 * (radius + 2.0 * x * x)) +
    640.0,
    y: 610.0 * (y * radial + 0.002 * (radius + 2.0 * y * y) - 0.003 * x * y) +
    360.0,
  }
}

///|
fn ground_calibration() -> @calibration.GroundCalibration raise @types.GroundError {
  @calibration.GroundCalibration::from_homography(
    [0.01, 0.002, -2.0, -0.001, 0.02, 1.0, 0.00005, -0.00003, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 1400.0, y: 0.0, },
      { x: 1400.0, y: 900.0, },
      { x: 0.0, y: 900.0, },
    ],
  )
}

///|
test "identity lens preserves non-square pixel coordinates and covariance" {
  let camera = @camera.CameraModel::new(fx=850.0, fy=610.0, cx=640.0, cy=360.0)
  let point = @types.Point2::new(810.0, 299.0)
  let rectified = camera.rectify(point)
  close(rectified.x, point.x)
  close(rectified.y, point.y)
  assert_eq(camera.jacobian(point), [1.0, 0.0, 0.0, 1.0])
  let covariance = camera.rectify_covariance(
    point,
    @types.Covariance2::new(4.0, 0.5, 9.0),
  )
  close(covariance.xx, 4.0)
  close(covariance.xy, 0.5)
  close(covariance.yy, 9.0)
}

///|
test "radial and tangential distortion recover known ideal pixel fixtures" {
  let camera = model()
  for
    ideal in [
      @types.Point2::{ x: 0.0, y: 0.0, },
      { x: 0.2, y: -0.1, },
      { x: -0.45, y: 0.3, },
      { x: 0.55, y: 0.42, },
    ] {
    let rectified = camera.rectify(raw_pixel(ideal.x, ideal.y))
    close(rectified.x, 850.0 * ideal.x + 640.0)
    close(rectified.y, 610.0 * ideal.y + 360.0)
  }
}

///|
test "camera parameters are copied and the inverse domain is explicit" {
  let camera = model()
  let values = camera.parameters()
  assert_eq(values, [
    850.0, 610.0, 640.0, 360.0, 0.035, -0.006, 0.002, -0.0015, 0.001,
  ])
  assert_eq(camera.max_normalized_radius(), 0.8)
  values[0] = 1.0
  values[4] = -1.0
  let rectified = camera.rectify(raw_pixel(0.2, -0.1))
  close(rectified.x, 810.0)
  close(rectified.y, 299.0)
}

///|
test "inverse Jacobian matches central differences with non-square focal lengths" {
  let camera = model()
  for
    raw in [raw_pixel(0.2, -0.1), raw_pixel(-0.45, 0.3), raw_pixel(0.55, 0.42)] {
    let delta = 0.01
    let px = camera.rectify({ x: raw.x + delta, y: raw.y, })
    let mx = camera.rectify({ x: raw.x - delta, y: raw.y, })
    let py = camera.rectify({ x: raw.x, y: raw.y + delta, })
    let my = camera.rectify({ x: raw.x, y: raw.y - delta, })
    let j = camera.jacobian(raw)
    close(j[0], (px.x - mx.x) / (2.0 * delta), tolerance=1.0e-7)
    close(j[1], (py.x - my.x) / (2.0 * delta), tolerance=1.0e-7)
    close(j[2], (px.y - mx.y) / (2.0 * delta), tolerance=1.0e-7)
    close(j[3], (py.y - my.y) / (2.0 * delta), tolerance=1.0e-7)
  }
}

///|
test "composed ground Jacobian matches the complete point map" {
  let camera = model()
  let calibration = ground_calibration()
  let raw = raw_pixel(0.2, -0.1)
  let delta = 0.01
  let px = calibration.map_point(
    camera.rectify({ x: raw.x + delta, y: raw.y, }),
  )
  let mx = calibration.map_point(
    camera.rectify({ x: raw.x - delta, y: raw.y, }),
  )
  let py = calibration.map_point(
    camera.rectify({ x: raw.x, y: raw.y + delta, }),
  )
  let my = calibration.map_point(
    camera.rectify({ x: raw.x, y: raw.y - delta, }),
  )
  let j = camera.project_jacobian(calibration, raw)
  close(j[0], (px.x - mx.x) / (2.0 * delta), tolerance=1.0e-9)
  close(j[1], (py.x - my.x) / (2.0 * delta), tolerance=1.0e-9)
  close(j[2], (px.y - mx.y) / (2.0 * delta), tolerance=1.0e-9)
  close(j[3], (py.y - my.y) / (2.0 * delta), tolerance=1.0e-9)
}

///|
test "composed covariance adds the ground floor once and retains correlation" {
  let camera = model()
  let calibration = ground_calibration()
  let raw = raw_pixel(0.2, -0.1)
  let covariance = @types.Covariance2::new(4.0, 0.7, 9.0)
  let result = camera.project(calibration, raw, covariance)
  let expected_position = calibration.map_point({ x: 810.0, y: 299.0, })
  close(result.position().x, expected_position.x)
  close(result.position().y, expected_position.y)
  let j = camera.project_jacobian(calibration, raw)
  let expected_xx = j[0] * j[0] * 4.0 +
    2.0 * j[0] * j[1] * 0.7 +
    j[1] * j[1] * 9.0
  let expected_xy = j[0] * j[2] * 4.0 +
    (j[0] * j[3] + j[1] * j[2]) * 0.7 +
    j[1] * j[3] * 9.0
  let expected_yy = j[2] * j[2] * 4.0 +
    2.0 * j[2] * j[3] * 0.7 +
    j[3] * j[3] * 9.0
  close(result.covariance().xx, expected_xx + 0.000001, tolerance=1.0e-13)
  close(result.covariance().xy, expected_xy, tolerance=1.0e-13)
  close(result.covariance().yy, expected_yy + 0.000001, tolerance=1.0e-13)
}

///|
test "identity composition does not insert an intermediate pixel noise floor" {
  let camera = @camera.CameraModel::new(fx=100.0, fy=200.0, cx=0.0, cy=0.0)
  let calibration = @calibration.GroundCalibration::from_homography(
    [0.1, 0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, 1.0],
    [
      { x: -20.0, y: -20.0, },
      { x: 20.0, y: -20.0, },
      { x: 20.0, y: 20.0, },
      { x: -20.0, y: 20.0, },
    ],
  )
  let result = camera.project(
    calibration,
    { x: 5.0, y: 10.0, },
    @types.Covariance2::isotropic(2.0),
  )
  close(result.covariance().xx, 0.040001, tolerance=1.0e-14)
  close(result.covariance().yy, 0.040001, tolerance=1.0e-14)
}

///|
test "a valid barrel boundary is accepted but a clipped non-root is rejected" {
  let camera = @camera.CameraModel::new(fx=1.0, fy=1.0, cx=0.0, cy=0.0, k1=-0.1)
  let boundary = camera.rectify({ x: 0.9, y: 0.0, })
  close(boundary.x, 1.0, tolerance=2.0e-12)
  close(boundary.y, 0.0)
  invalid(() => ignore(camera.rectify({ x: 0.95, y: 0.0, })))
  invalid(() => ignore(camera.rectify({ x: 1.31, y: 0.0, })))
}

///|
test "tiny camera radii are not enlarged by an absolute solver tolerance" {
  let camera = @camera.CameraModel::new(
    fx=1.0e20,
    fy=1.0e20,
    cx=0.0,
    cy=0.0,
    max_normalized_radius=1.0e-20,
  )
  invalid(() => ignore(camera.rectify({ x: 5.0e7, y: 0.0, })))
  invalid(() => ignore(camera.jacobian({ x: 5.0e7, y: 0.0, })))
  close(camera.rectify({ x: 0.5, y: 0.0, }).x, 0.5)
  close(camera.rectify({ x: 1.0, y: 0.0, }).x, 1.0)
  invalid(() => ignore(camera.rectify({ x: 1.0001, y: 0.0, })))
  assert_eq(camera.jacobian({ x: 0.5, y: 0.0, }), [1.0, 0.0, 0.0, 1.0])
}

///|
test "uniform focal rescaling does not overflow a finite inverse pixel Jacobian" {
  let reference = @camera.CameraModel::new(
    fx=1.0,
    fy=1.0,
    cx=0.0,
    cy=0.0,
    k1=-0.3,
  ).jacobian({ x: 0.4942, y: 0.4942, })
  let tiny = @camera.CameraModel::new(
    fx=1.0e-308,
    fy=1.0e-308,
    cx=0.0,
    cy=0.0,
    k1=-0.3,
  ).jacobian({ x: 4.942e-309, y: 4.942e-309, })
  for i in 0..<4 {
    close(tiny[i], reference[i])
  }
  let extreme_identity = @camera.CameraModel::new(
    fx=1.0e300,
    fy=1.0e-300,
    cx=0.0,
    cy=0.0,
  )
  assert_eq(extreme_identity.jacobian({ x: 0.0, y: 0.0, }), [1.0, 0.0, 0.0, 1.0])
}

///|
test "iteration exhaustion rejects an unresolved near-folding boundary" {
  let camera = @camera.CameraModel::new(
    fx=1.0,
    fy=1.0,
    cx=0.0,
    cy=0.0,
    k1=-0.3333333,
  )
  try camera.rectify({ x: 0.6666667, y: 0.0, }) catch {
    error => assert_true(error.message().contains("did not converge"))
  } noraise {
    _ => fail("unresolved nearly singular inverse was accepted")
  }
}

///|
test "folding coefficients can only be used with a certified smaller disk" {
  invalid(() => {
    ignore(@camera.CameraModel::new(fx=1.0, fy=1.0, cx=0.0, cy=0.0, k1=-0.5))
  })
  invalid(() => {
    ignore(@camera.CameraModel::new(fx=1.0, fy=1.0, cx=0.0, cy=0.0, p1=0.2))
  })
  let small = @camera.CameraModel::new(
    fx=1.0,
    fy=1.0,
    cx=0.0,
    cy=0.0,
    k1=-0.5,
    max_normalized_radius=0.3,
  )
  close(small.rectify({ x: 0.196, y: 0.0, }).x, 0.2)
}

///|
test "nonfinite camera parameters input covariance and arithmetic are rejected" {
  invalid(() => ignore(@camera.CameraModel::new(fx=0.0, fy=1.0, cx=0.0, cy=0.0)))
  invalid(() => {
    ignore(@camera.CameraModel::new(fx=1.0, fy=-1.0, cx=0.0, cy=0.0))
  })
  invalid(() => {
    ignore(
      @camera.CameraModel::new(
        fx=1.0,
        fy=1.0,
        cx=0.0,
        cy=0.0,
        max_normalized_radius=0.0,
      ),
    )
  })
  invalid(() => {
    ignore(@camera.CameraModel::new(fx=1.0, fy=1.0, cx=0.0, cy=1.0 / 0.0))
  })
  invalid(() => {
    ignore(
      @camera.CameraModel::new(fx=1.0, fy=1.0, cx=0.0, cy=0.0, k3=0.0 / 0.0),
    )
  })
  invalid(() => {
    ignore(
      @camera.CameraModel::new(
        fx=1.0,
        fy=1.0,
        cx=0.0,
        cy=0.0,
        max_normalized_radius=1.0e100,
      ),
    )
  })
  let camera = model()
  invalid(() => ignore(camera.rectify({ x: 1.0 / 0.0, y: 0.0, })))
  invalid(() => {
    ignore(
      camera.rectify_covariance(raw_pixel(0.1, 0.1), {
        xx: 1.0,
        xy: 2.0,
        yy: 1.0,
      }),
    )
  })
  let offset = @camera.CameraModel::new(fx=1.0, fy=1.0, cx=-1.0e308, cy=0.0)
  invalid(() => ignore(offset.rectify({ x: 1.0e308, y: 0.0, })))
}

///|
test "the homography ROI is tested after lens correction" {
  let camera = @camera.CameraModel::new(
    fx=10.0,
    fy=10.0,
    cx=0.0,
    cy=0.0,
    k1=0.1,
  )
  let calibration = @calibration.GroundCalibration::from_homography(
    [0.1, 0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, 1.0],
    [
      { x: -10.0, y: -10.0, },
      { x: 10.0, y: -10.0, },
      { x: 10.0, y: 10.0, },
      { x: -10.0, y: 10.0, },
    ],
  )
  let point = camera.project(
    calibration,
    { x: 10.870299, y: 0.0, },
    @types.Covariance2::isotropic(1.0),
  )
  close(point.position().x, 0.99)
  invalid(() => ignore(calibration.map_point({ x: 10.870299, y: 0.0, })))
}
