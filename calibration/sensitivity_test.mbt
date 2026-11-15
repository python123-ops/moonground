///|
fn sensitivity_identity() -> @calibration.GroundCalibration raise {
  @calibration.GroundCalibration::from_homography(
    [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    rectangle(),
    max_meters_per_pixel=2.0,
  )
}

///|
fn sensitivity_translation() -> Array[Array[Double]] {
  [
    [0.0, 0.0, 0.25, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0],
    [0.0, 0.0, -0.5, 0.0, 0.0, 0.25, 0.0, 0.0, 0.0],
  ]
}

///|
fn sensitivity_values(points : Array[@types.Point2]) -> Array[(Double, Double)] {
  points.map(point => (point.x, point.y))
}

///|
test "shared translation has nonzero point error and exactly zero relative error" {
  let calibration = sensitivity_identity()
  let model = @calibration.HomographySensitivity::new(
    calibration,
    sensitivity_translation(),
  )
  let result = model.evaluate_pair({ x: 10.0, y: 20.0, }, { x: 40.0, y: 50.0, })
  close(result.first.contribution_m2.xx, 0.3125)
  close(result.first.contribution_m2.xy, 0.0)
  close(result.second.contribution_m2.yy, 0.3125)
  assert_eq(result.cross_contribution_m2(), [0.3125, 0.0, 0.0, 0.3125])
  assert_eq(result.displacement_contribution_m2.xx, 0.0)
  assert_eq(result.displacement_contribution_m2.xy, 0.0)
  assert_eq(result.displacement_contribution_m2.yy, 0.0)
  close(result.displacement_m.x, 30.0)
  close(result.displacement_m.y, 30.0)
}

///|
test "full correlated modes produce a nonsymmetric cross block" {
  let model = @calibration.HomographySensitivity::new(sensitivity_identity(), [
    [0.125, 0.0, 0.0, 0.0, 0.0, 0.25, 0.0, 0.0, 0.0],
  ])
  let result = model.evaluate_pair({ x: 2.0, y: 1.0, }, { x: 4.0, y: 3.0, })
  assert_eq(sensitivity_values(result.first.mode_responses_m()), [(0.25, 0.25)])
  assert_eq(sensitivity_values(result.second.mode_responses_m()), [(0.5, 0.25)])
  assert_eq(result.cross_contribution_m2(), [0.125, 0.0625, 0.125, 0.0625])
  assert_eq(result.displacement_contribution_m2.xx, 0.0625)
  assert_eq(result.displacement_contribution_m2.yy, 0.0)
  let reverse = model.evaluate_pair({ x: 4.0, y: 3.0, }, { x: 2.0, y: 1.0, })
  assert_eq(reverse.cross_contribution_m2(), [0.125, 0.125, 0.0625, 0.0625])
  assert_eq(reverse.displacement_contribution_m2.xx, 0.0625)
}

///|
test "perspective denominator modes and h22 participate in the analytic derivative" {
  let model = @calibration.HomographySensitivity::new(sensitivity_identity(), [
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.125, 0.0, 0.0],
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5],
  ])
  let response = model.evaluate({ x: 2.0, y: 4.0, })
  assert_eq(sensitivity_values(response.mode_responses_m()), [
    (-0.5, -1.0),
    (-1.0, -2.0),
  ])
  assert_eq(response.contribution_m2.xx, 1.25)
  assert_eq(response.contribution_m2.xy, 2.5)
  assert_eq(response.contribution_m2.yy, 5.0)
}

///|
test "empty zero rank and pure scale directions remain valid contributions" {
  let calibration = sensitivity_identity()
  for
    modes in [
      [],
      [[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]],
      [calibration.matrix()],
    ] {
    let model = @calibration.HomographySensitivity::new(calibration, modes)
    let result = model.evaluate_pair({ x: 2.0, y: 4.0, }, { x: 2.0, y: 4.0, })
    assert_eq(result.first.contribution_m2.xx, 0.0)
    assert_eq(result.first.contribution_m2.yy, 0.0)
    assert_eq(result.displacement_contribution_m2.xx, 0.0)
    assert_eq(result.displacement_contribution_m2.yy, 0.0)
  }
}

///|
test "modes baseline responses and cross arrays are defensive copies" {
  let modes = sensitivity_translation()
  let calibration = sensitivity_identity()
  let model = @calibration.HomographySensitivity::new(calibration, modes)
  let before = model.evaluate_pair({ x: 1.0, y: 2.0, }, { x: 3.0, y: 4.0, })
  modes[0][2] = 999.0
  modes.clear()
  let exported = model.modes()
  exported[0][2] = 888.0
  exported.clear()
  let matrix = model.matrix()
  matrix[0] = 0.0
  let response = before.first.mode_responses_m()
  response.clear()
  let cross = before.cross_contribution_m2()
  cross[0] = 0.0
  let after = model.evaluate_pair({ x: 1.0, y: 2.0, }, { x: 3.0, y: 4.0, })
  assert_eq(
    sensitivity_values(after.first.mode_responses_m()),
    sensitivity_values(before.first.mode_responses_m()),
  )
  assert_eq(after.cross_contribution_m2(), before.cross_contribution_m2())
  assert_eq(model.matrix(), calibration.matrix())
}

///|
test "finite mode dimensions ROI and both point failures are rejected statelessly" {
  let calibration = sensitivity_identity()
  for
    modes in [
      [[0.0]],
      [[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0 / 0.0]],
      Array::make(33, calibration.matrix()),
    ] {
    expect_invalid(() => {
      ignore(@calibration.HomographySensitivity::new(calibration, modes))
    })
  }
  let model = @calibration.HomographySensitivity::new(
    calibration,
    sensitivity_translation(),
  )
  let invalid_points : Array[@types.Point2] = [
    { x: -1.0, y: 0.0, },
    { x: 1.0 / 0.0, y: 0.0, },
  ]
  for point in invalid_points {
    expect_invalid(() => ignore(model.evaluate_pair({ x: 1.0, y: 2.0, }, point)))
    expect_invalid(() => ignore(model.evaluate_pair(point, { x: 1.0, y: 2.0, })))
  }
  assert_eq(model.evaluate({ x: 0.0, y: 0.0, }).contribution_m2.xx, 0.3125)
}

///|
test "sensitivity rejects overflowing or erased nonzero mode products" {
  let calibration = sensitivity_identity()
  for amplitude in [1.0e200, 1.0e-200] {
    let model = @calibration.HomographySensitivity::new(calibration, [
      [0.0, 0.0, amplitude, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    ])
    expect_invalid(() => ignore(model.evaluate({ x: 0.0, y: 0.0, })))
  }
}

///|
test "32 correlated modes repeated point and original covariance remain separate" {
  let calibration = sensitivity_identity()
  let pixel = @types.Point2::new(10.0, 20.0)
  let measurement = @types.Covariance2::new(0.25, 0.125, 0.5)
  let original = calibration.project(pixel, measurement).covariance()
  let model = @calibration.HomographySensitivity::new(
    calibration,
    Array::make(32, sensitivity_translation()[0]),
  )
  let result = model.evaluate_pair(pixel, pixel)
  assert_eq(result.first.contribution_m2.xx, 2.0)
  assert_eq(result.first.contribution_m2.xy, 4.0)
  assert_eq(result.first.contribution_m2.yy, 8.0)
  assert_eq(result.displacement_contribution_m2.xx, 0.0)
  assert_eq(result.displacement_contribution_m2.yy, 0.0)
  let unchanged = calibration.project(pixel, measurement).covariance()
  assert_eq(original.xx, unchanged.xx)
  assert_eq(original.xy, unchanged.xy)
  assert_eq(original.yy, unchanged.yy)
}
