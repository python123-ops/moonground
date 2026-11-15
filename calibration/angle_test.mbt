///|
fn angle_rotation_model() -> @calibration.HomographySensitivity raise {
  @calibration.HomographySensitivity::new(sensitivity_identity(), [
    [0.0, -0.125, 0.0, 0.125, 0.0, 0.0, 0.0, 0.0, 0.0],
  ])
}

///|
test "static segment direction propagates the perpendicular response in radians" {
  let result = angle_rotation_model().segment_direction({ x: 0.0, y: 0.0, }, {
    x: 3.0,
    y: 4.0,
  })
  assert_eq(result.distance_m, 5.0)
  close(result.angle_rad, 0.9272952180016122)
  assert_eq(result.mode_responses_rad(), [0.125])
  assert_eq(result.contribution_rad2, 0.015625)
  assert_eq(result.std_rad, 0.125)
}

///|
test "common rotation cancels in a relative angle while both directions have error" {
  let result = angle_rotation_model().compare_directions(
    { x: 0.0, y: 0.0, },
    { x: 3.0, y: 4.0, },
    { x: 0.0, y: 0.0, },
    { x: 0.0, y: 8.0, },
  )
  close(result.angle_rad, 0.6435011087932844)
  assert_eq(result.first.std_rad, 0.125)
  assert_eq(result.second.std_rad, 0.125)
  assert_eq(result.cross_contribution_rad2, 0.015625)
  assert_eq(result.mode_responses_rad(), [0.0])
  assert_eq(result.contribution_rad2, 0.0)
  assert_eq(result.std_rad, 0.0)
}

///|
test "translation and shared isotropic scale have exactly zero angular response" {
  let translation = @calibration.HomographySensitivity::new(
    sensitivity_identity(),
    sensitivity_translation(),
  ).segment_direction({ x: 1.0, y: 2.0, }, { x: 4.0, y: 6.0, })
  assert_eq(translation.mode_responses_rad(), [0.0, 0.0])
  assert_eq(translation.std_rad, 0.0)
  let scale = distance_scale_model().segment_direction({ x: 0.0, y: 0.0, }, {
    x: 3.0,
    y: 4.0,
  })
  assert_eq(scale.mode_responses_rad(), [0.0])
  assert_eq(scale.std_rad, 0.0)
}

///|
test "opposite direction responses retain negative cross contribution" {
  let model = @calibration.HomographySensitivity::new(sensitivity_identity(), [
    [0.0, 0.125, 0.0, 0.125, 0.0, 0.0, 0.0, 0.0, 0.0],
  ])
  let result = model.compare_directions(
    { x: 0.0, y: 0.0, },
    { x: 4.0, y: 0.0, },
    { x: 0.0, y: 0.0, },
    { x: 0.0, y: 8.0, },
  )
  assert_eq(result.first.mode_responses_rad(), [0.125])
  assert_eq(result.second.mode_responses_rad(), [-0.125])
  assert_eq(result.cross_contribution_rad2, -0.015625)
  assert_eq(result.mode_responses_rad(), [-0.25])
  assert_eq(result.contribution_rad2, 0.0625)
  close(result.angle_rad, 1.5707963267948966)
}

///|
test "swapping directed segments reverses the signed angle and its local response" {
  let model = @calibration.HomographySensitivity::new(sensitivity_identity(), [
    [0.0, 0.125, 0.0, 0.125, 0.0, 0.0, 0.0, 0.0, 0.0],
  ])
  let a : @types.Point2 = { x: 0.0, y: 0.0, }
  let b : @types.Point2 = { x: 4.0, y: 0.0, }
  let c : @types.Point2 = { x: 0.0, y: 8.0, }
  let forward = model.compare_directions(a, b, a, c)
  let reverse = model.compare_directions(a, c, a, b)
  assert_eq(reverse.angle_rad, -forward.angle_rad)
  assert_eq(reverse.mode_responses_rad()[0], -forward.mode_responses_rad()[0])
  assert_eq(reverse.contribution_rad2, forward.contribution_rad2)
  assert_eq(reverse.cross_contribution_rad2, forward.cross_contribution_rad2)
}

///|
test "reversing endpoints shifts the displayed bearing by pi and retains its tangent" {
  let model = angle_rotation_model()
  let a : @types.Point2 = { x: 0.0, y: 0.0, }
  let b : @types.Point2 = { x: 3.0, y: 4.0, }
  let forward = model.segment_direction(a, b)
  let reverse = model.segment_direction(b, a)
  close(forward.angle_rad - reverse.angle_rad, 3.141592653589793)
  assert_eq(reverse.mode_responses_rad(), forward.mode_responses_rad())
  let opposite = model.compare_directions(a, b, b, a)
  assert_eq(opposite.angle_rad, 3.141592653589793)
  assert_eq(opposite.mode_responses_rad(), [0.0])
}

///|
test "branch cut is canonical and near-cut uncertainty remains a circular tangent" {
  let model = angle_rotation_model()
  let origin : @types.Point2 = { x: 10.0, y: 10.0, }
  let left : @types.Point2 = { x: 0.0, y: 10.0, }
  let exact = model.segment_direction(origin, left)
  assert_eq(exact.angle_rad, 3.141592653589793)
  assert_eq(exact.mode_responses_rad(), [0.125])
  let above = model.segment_direction(origin, { x: 0.0, y: 10.00000001, })
  let below = model.segment_direction(origin, { x: 0.0, y: 9.99999999, })
  assert_true(above.angle_rad > 3.14)
  assert_true(below.angle_rad < -3.14)
  close(above.std_rad, below.std_rad)
  let zero = model.segment_direction(left, origin).angle_rad
  assert_eq(zero, 0.0)
  assert_true(1.0 / zero > 0.0)
}

///|
test "raw compensated direction determinant retains a very small nonzero relative angle" {
  let empty = @calibration.HomographySensitivity::new(sensitivity_identity(), [])
  let result = empty.compare_directions(
    { x: 0.0, y: 0.0, },
    { x: 4.0, y: 3.0, },
    { x: 0.0, y: 0.0, },
    { x: 8.0, y: 6.000000000000001, },
  )
  assert_true(result.angle_rad > 0.0 && result.angle_rad < 1.0e-15)
  assert_eq(result.std_rad, 0.0)
}

///|
test "zero rank and 32 modes retain original order and isolate response arrays" {
  let a : @types.Point2 = { x: 0.0, y: 0.0, }
  let b : @types.Point2 = { x: 4.0, y: 0.0, }
  let c : @types.Point2 = { x: 0.0, y: 8.0, }
  let empty = @calibration.HomographySensitivity::new(sensitivity_identity(), []).compare_directions(
    a, b, a, c,
  )
  assert_eq(empty.mode_responses_rad(), [])
  assert_eq(empty.first.contribution_rad2, 0.0)
  let model = @calibration.HomographySensitivity::new(
    sensitivity_identity(),
    Array::make(32, angle_rotation_model().modes()[0]),
  )
  let result = model.compare_directions(a, b, a, c)
  assert_eq(result.first.contribution_rad2, 0.5)
  assert_eq(result.first.mode_responses_rad(), Array::make(32, 0.125))
  let first = result.first.mode_responses_rad()
  first[0] = 9.0
  let relative = result.mode_responses_rad()
  relative.clear()
  assert_eq(result.first.mode_responses_rad()[0], 0.125)
  assert_eq(result.mode_responses_rad(), Array::make(32, 0.0))
}

///|
test "coincident rounded coincident and outside segments reject without changing the model" {
  let empty = @calibration.HomographySensitivity::new(sensitivity_identity(), [])
  let a : @types.Point2 = { x: 0.0, y: 0.0, }
  let b : @types.Point2 = { x: 4.0, y: 0.0, }
  expect_invalid(() => ignore(empty.segment_direction(a, a)))
  expect_invalid(() => ignore(empty.compare_directions(a, b, a, a)))
  expect_invalid(() => ignore(empty.segment_direction(a, { x: 101.0, y: 0.0, })))
  let offset = @calibration.GroundCalibration::from_homography(
    [1.0, 0.0, 1.0e16, 0.0, 1.0, 1.0e16, 0.0, 0.0, 1.0],
    rectangle(),
    max_meters_per_pixel=2.0,
  )
  let model = @calibration.HomographySensitivity::new(offset, [])
  expect_invalid(() => ignore(model.segment_direction(a, { x: 1.0, y: 0.0, })))
  assert_eq(empty.segment_direction(a, b).angle_rad, 0.0)
}

///|
test "direction supports vastly different segment scales without forming a squared norm" {
  let calibration = @calibration.GroundCalibration::from_homography(
    sensitivity_identity().matrix(),
    [
      { x: 0.0, y: 0.0, },
      { x: 1.0e200, y: 0.0, },
      { x: 1.0e200, y: 1.0e200, },
      { x: 0.0, y: 1.0e200, },
    ],
    max_meters_per_pixel=2.0,
  )
  let result = @calibration.HomographySensitivity::new(calibration, []).compare_directions(
    { x: 0.0, y: 0.0, },
    { x: 1.0e200, y: 0.0, },
    { x: 0.0, y: 0.0, },
    { x: 0.0, y: 1.0e-200, },
  )
  assert_eq(result.first.distance_m, 1.0e200)
  assert_eq(result.second.distance_m, 1.0e-200)
  close(result.angle_rad, 1.5707963267948966)
}

///|
test "angular variance overflow and late relative variance overflow are typed errors" {
  let a : @types.Point2 = { x: 0.0, y: 0.0, }
  let model = @calibration.HomographySensitivity::new(sensitivity_identity(), [
    [0.0, 0.0, 0.0, 1.0e200, 0.0, 0.0, 0.0, 0.0, 0.0],
  ])
  expect_invalid(() => {
    ignore(model.segment_direction(a, { x: 1.0e-200, y: 0.0, }))
  })
  let large = @calibration.HomographySensitivity::new(sensitivity_identity(), [
    [0.0, 1.0e154, 0.0, 1.0e154, 0.0, 0.0, 0.0, 0.0, 0.0],
  ])
  assert_true(large.segment_direction(a, { x: 1.0, y: 0.0, }).std_rad > 0.0)
  expect_invalid(() => {
    ignore(
      large.compare_directions(a, { x: 1.0, y: 0.0, }, a, { x: 0.0, y: 1.0, }),
    )
  })
}
