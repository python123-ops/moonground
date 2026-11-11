///|
fn rectangle() -> Array[@types.Point2] {
  [
    { x: 0.0, y: 0.0, },
    { x: 100.0, y: 0.0, },
    { x: 100.0, y: 100.0, },
    { x: 0.0, y: 100.0, },
  ]
}

///|
fn affine_matrix() -> Array[Double] {
  [0.1, 0.02, 1.0, -0.01, 0.2, -2.0, 0.0, 0.0, 1.0]
}

///|
fn close(
  actual : Double,
  expected : Double,
  tolerance~ : Double = 1.0e-10,
) -> Unit raise {
  assert_true((actual - expected).abs() <= tolerance)
}

///|
fn expect_invalid(action : () -> Unit raise @types.GroundError) -> Unit raise {
  try action() catch {
    @types.GroundError::InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid calibration input was accepted")
  }
}

///|
test "affine projection and correlated covariance use metres and a noise floor" {
  let calibration = @calibration.GroundCalibration::from_homography(
    affine_matrix(),
    rectangle(),
  )
  let point = @types.Point2::new(20.0, 30.0)
  let mapped = calibration.project(
    point,
    @types.Covariance2::new(4.0, 1.0, 9.0),
  )
  close(mapped.position().x, 3.6)
  close(mapped.position().y, 3.8)
  close(mapped.covariance().xx, 0.047601)
  close(mapped.covariance().xy, 0.0518)
  close(mapped.covariance().yy, 0.356401)
  let j = calibration.jacobian(point)
  close(j[0], 0.1)
  close(j[1], 0.02)
  close(j[2], -0.01)
  close(j[3], 0.2)
  assert_eq(calibration.report().fit_count(), 0)
  assert_eq(calibration.report().fit_rms_m(), None)
}

///|
test "perspective Jacobian agrees with independent central differences" {
  let calibration = @calibration.GroundCalibration::from_homography(
    [0.1, 0.015, 1.0, -0.005, 0.08, 2.0, 0.001, -0.0003, 1.0],
    rectangle(),
  )
  for
    point in [
      @types.Point2::{ x: 15.0, y: 25.0, },
      { x: 75.0, y: 85.0, },
      { x: 50.0, y: 50.0, },
    ] {
    let delta = 1.0e-4
    let px = calibration.map_point({ x: point.x + delta, y: point.y, })
    let mx = calibration.map_point({ x: point.x - delta, y: point.y, })
    let py = calibration.map_point({ x: point.x, y: point.y + delta, })
    let my = calibration.map_point({ x: point.x, y: point.y - delta, })
    let j = calibration.jacobian(point)
    close(j[0], (px.x - mx.x) / (2.0 * delta), tolerance=1.0e-9)
    close(j[1], (py.x - my.x) / (2.0 * delta), tolerance=1.0e-9)
    close(j[2], (px.y - mx.y) / (2.0 * delta), tolerance=1.0e-9)
    close(j[3], (py.y - my.y) / (2.0 * delta), tolerance=1.0e-9)
  }
}

///|
test "homography scale and sign do not alter mapping or uncertainty" {
  let matrix = affine_matrix()
  let reference = @calibration.GroundCalibration::from_homography(
    matrix,
    rectangle(),
  )
  let point = @types.Point2::new(37.0, 63.0)
  let covariance = @types.Covariance2::new(2.0, -0.3, 1.0)
  let expected = reference.project(point, covariance)
  for multiplier in [1.0e-200, -1.0e-200, 1.0e200, -1.0e200] {
    let scaled = @calibration.GroundCalibration::from_homography(
      matrix.map(fn(value) { value * multiplier }),
      rectangle(),
    ).project(point, covariance)
    close(scaled.position().x, expected.position().x)
    close(scaled.position().y, expected.position().y)
    close(scaled.covariance().xx, expected.covariance().xx)
    close(scaled.covariance().xy, expected.covariance().xy)
    close(scaled.covariance().yy, expected.covariance().yy)
  }
}

///|
test "valid homographies need not have a nonzero bottom-right coefficient" {
  let triangle = [
    @types.Point2::{ x: 100.0, y: 0.0, },
    { x: 200.0, y: 0.0, },
    { x: 100.0, y: 100.0, },
  ]
  let calibration = @calibration.GroundCalibration::from_homography(
    [0.1, 0.0, 1.0, 0.0, 0.1, 0.0, 0.01, 0.0, 0.0],
    triangle,
  )
  let point = calibration.map_point({ x: 125.0, y: 25.0, })
  close(point.x, 10.8)
  close(point.y, 2.0)
  expect_invalid(() => ignore(calibration.map_point({ x: 175.0, y: 75.0, })))
}

///|
test "ROI includes boundaries in both orientations and rejects outside points" {
  let reversed = [
    @types.Point2::{ x: 0.0, y: 100.0, },
    { x: 100.0, y: 100.0, },
    { x: 100.0, y: 0.0, },
    { x: 0.0, y: 0.0, },
  ]
  for polygon in [rectangle(), reversed] {
    let calibration = @calibration.GroundCalibration::from_homography(
      affine_matrix(),
      polygon,
    )
    for point in rectangle() {
      ignore(calibration.map_point(point))
    }
    ignore(calibration.map_point({ x: 0.0, y: 50.0, }))
    expect_invalid(() => ignore(calibration.map_point({ x: -0.01, y: 50.0, })))
    expect_invalid(() => ignore(calibration.map_point({ x: 50.0, y: 100.01, })))
    expect_invalid(() => ignore(calibration.jacobian({ x: 101.0, y: 101.0, })))
  }
}

///|
test "calibration owns its matrix and ROI and returns defensive copies" {
  let matrix = affine_matrix()
  let polygon = rectangle()
  let calibration = @calibration.GroundCalibration::from_homography(
    matrix, polygon,
  )
  matrix[0] = 0.4
  polygon[0] = { x: 90.0, y: 90.0, }
  let matrix_copy = calibration.matrix()
  matrix_copy[0] = 999.0
  let polygon_copy = calibration.roi()
  polygon_copy[0] = { x: 90.0, y: 90.0, }
  let mapped = calibration.map_point({ x: 0.0, y: 0.0, })
  close(mapped.x, 1.0)
  close(mapped.y, -2.0)
}

///|
test "invalid matrix dimensions nonfinite coefficients and rank loss are rejected" {
  for
    matrix in [
      [],
      [1.0, 0.0],
      [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
      [0.1, 0.0, 0.0, 0.2, 0.0, 0.0, 0.0, 0.0, 1.0],
      [0.1, 0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, 1.0 / 0.0],
      [0.1, 0.0 / 0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, 1.0],
    ] {
    expect_invalid(() => {
      ignore(
        @calibration.GroundCalibration::from_homography(matrix, rectangle()),
      )
    })
  }
}

///|
test "concave crossed duplicate collinear and oversized polygons are rejected" {
  for
    polygon in [
      [],
      [@types.Point2::{ x: 0.0, y: 0.0, }, { x: 1.0, y: 1.0, }],
      [{ x: 0.0, y: 0.0, }, { x: 50.0, y: 0.0, }, { x: 100.0, y: 0.0, }],
      [
        { x: 0.0, y: 0.0, },
        { x: 100.0, y: 0.0, },
        { x: 10.0, y: 10.0, },
        { x: 0.0, y: 100.0, },
      ],
      [
        { x: 0.0, y: 0.0, },
        { x: 100.0, y: 100.0, },
        { x: 0.0, y: 100.0, },
        { x: 100.0, y: 0.0, },
      ],
      [
        { x: 0.0, y: 0.0, },
        { x: 100.0, y: 0.0, },
        { x: 100.0, y: 100.0, },
        { x: 0.0, y: 0.0, },
      ],
      Array::make(65, @types.Point2::{ x: 0.0, y: 0.0, }),
    ] {
    expect_invalid(() => {
      ignore(
        @calibration.GroundCalibration::from_homography(
          affine_matrix(),
          polygon,
        ),
      )
    })
  }
}

///|
test "finite corners do not conceal a horizon crossing the ROI" {
  // Denominator x - 50 is nonzero at all four corners and zero inside.
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::from_homography(
        [0.1, 0.0, 0.0, 0.0, 0.1, 0.0, 1.0, 0.0, -50.0],
        rectangle(),
      ),
    )
  })
  // Horizon on an ROI edge is also invalid.
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::from_homography(
        [0.1, 0.0, 1.0, 0.0, 0.1, 0.0, 1.0, 0.0, 0.0],
        rectangle(),
      ),
    )
  })
}

///|
test "mapping amplification is bounded over the complete ROI" {
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::from_homography(
        [0.1, 0.0, 0.0, 0.0, 0.1, 0.0, -0.009, 0.0, 1.0],
        rectangle(),
      ),
    )
  })
  let calibrated = @calibration.GroundCalibration::from_homography(
    [0.1, 0.0, 0.0, 0.0, 0.2, 0.0, 0.0, 0.0, 1.0],
    rectangle(),
    max_meters_per_pixel=0.2,
  )
  close(calibrated.report().roi_scale_bound_m_per_pixel(), 0.2)
}

///|
test "nonfinite points covariance and underflowed noise floor cannot enter projection" {
  let calibration = @calibration.GroundCalibration::from_homography(
    affine_matrix(),
    rectangle(),
  )
  expect_invalid(() => ignore(calibration.map_point({ x: 1.0 / 0.0, y: 20.0, })))
  expect_invalid(() => {
    ignore(
      calibration.project({ x: 20.0, y: 20.0, }, { xx: 1.0, xy: 2.0, yy: 1.0, }),
    )
  })
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::from_homography(
        affine_matrix(),
        rectangle(),
        ground_noise_floor_m=1.0e-200,
      ),
    )
  })
  expect_invalid(() => {
    ignore(
      @calibration.GroundCalibration::from_homography(
        affine_matrix(),
        rectangle(),
        max_meters_per_pixel=0.0 / 0.0,
      ),
    )
  })
  let high_scale = @calibration.GroundCalibration::from_homography(
    [2.0, 1.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 1.0],
    rectangle(),
    max_meters_per_pixel=10.0,
  )
  expect_invalid(() => {
    ignore(
      high_scale.project({ x: 20.0, y: 20.0, }, {
        xx: 1.0e308,
        xy: 0.0,
        yy: 1.0e308,
      }),
    )
  })
}
