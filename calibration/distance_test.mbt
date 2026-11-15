///|
fn distance_scale_model() -> @calibration.HomographySensitivity raise {
  @calibration.HomographySensitivity::new(sensitivity_identity(), [
    [0.125, 0.0, 0.0, 0.0, 0.125, 0.0, 0.0, 0.0, 0.0],
  ])
}

///|
test "Euclidean distance propagates the full correlated displacement along its own direction" {
  let result = distance_scale_model().distance({ x: 0.0, y: 0.0, }, {
    x: 3.0,
    y: 4.0,
  })
  assert_eq(result.distance_m, 5.0)
  close(result.direction.x, 0.6)
  close(result.direction.y, 0.8)
  assert_eq(result.mode_responses_m(), [0.625])
  assert_eq(result.contribution_m2, 0.390625)
  assert_eq(result.std_m, 0.625)
}

///|
test "common scale cancels in a length ratio while keeping correlated length errors" {
  let result = distance_scale_model().compare_distances(
    { x: 0.0, y: 0.0, },
    { x: 3.0, y: 4.0, },
    { x: 0.0, y: 0.0, },
    { x: 10.0, y: 0.0, },
  )
  assert_eq(result.cross_contribution_m2, 0.78125)
  assert_eq(result.difference_m, -5.0)
  assert_eq(result.difference_mode_responses_m(), [-0.625])
  assert_eq(result.difference_contribution_m2, 0.390625)
  assert_eq(result.difference_std_m, 0.625)
  assert_eq(result.ratio, 0.5)
  assert_eq(result.ratio_mode_responses(), [0.0])
  assert_eq(result.ratio_contribution, 0.0)
  assert_eq(result.ratio_std, 0.0)
  assert_true(
    result.first.contribution_m2 + result.second.contribution_m2 >
    result.difference_contribution_m2,
  )
}

///|
test "opposite anisotropic responses retain negative cross covariance and enlarge contrasts" {
  let model = @calibration.HomographySensitivity::new(sensitivity_identity(), [
    [0.25, 0.0, 0.0, 0.0, -0.125, 0.0, 0.0, 0.0, 0.0],
  ])
  let result = model.compare_distances(
    { x: 0.0, y: 0.0, },
    { x: 4.0, y: 0.0, },
    { x: 0.0, y: 0.0, },
    { x: 0.0, y: 8.0, },
  )
  assert_eq(result.first.mode_responses_m(), [1.0])
  assert_eq(result.second.mode_responses_m(), [-1.0])
  assert_eq(result.cross_contribution_m2, -1.0)
  assert_eq(result.difference_contribution_m2, 4.0)
  assert_eq(result.ratio_mode_responses(), [0.1875])
  assert_eq(result.ratio_contribution, 0.03515625)
}

///|
test "translation cancels and a tangent mode can have a zero first order distance response" {
  let translation = @calibration.HomographySensitivity::new(
    sensitivity_identity(),
    sensitivity_translation(),
  ).distance({ x: 0.0, y: 0.0, }, { x: 3.0, y: 4.0, })
  assert_eq(translation.contribution_m2, 0.0)
  assert_eq(translation.mode_responses_m(), [0.0, 0.0])
  let tangent = @calibration.HomographySensitivity::new(
    sensitivity_identity(),
    [[0.0, 0.0, 0.0, 0.25, 0.0, 0.0, 0.0, 0.0, 0.0]],
  ).distance({ x: 0.0, y: 0.0, }, { x: 4.0, y: 0.0, })
  assert_eq(tangent.contribution_m2, 0.0)
  // At xi=1 the nonlinear length is sqrt(4^2+1^2), despite zero derivative.
  assert_true(17.0.sqrt() > tangent.distance_m)
}

///|
test "reversing both segment endpoints leaves scalar responses unchanged" {
  let model = distance_scale_model()
  let forward = model.distance({ x: 1.0, y: 2.0, }, { x: 4.0, y: 6.0, })
  let reverse = model.distance({ x: 4.0, y: 6.0, }, { x: 1.0, y: 2.0, })
  assert_eq(forward.distance_m, reverse.distance_m)
  assert_eq(forward.contribution_m2, reverse.contribution_m2)
  assert_eq(forward.mode_responses_m(), reverse.mode_responses_m())
  assert_eq(forward.direction.x, -reverse.direction.x)
  assert_eq(forward.direction.y, -reverse.direction.y)
}

///|
test "swapping the two distances reverses differences and transforms reciprocal ratio response" {
  let model = @calibration.HomographySensitivity::new(sensitivity_identity(), [
    [0.25, 0.0, 0.0, 0.0, -0.125, 0.0, 0.0, 0.0, 0.0],
  ])
  let a : @types.Point2 = { x: 0.0, y: 0.0, }
  let b : @types.Point2 = { x: 4.0, y: 0.0, }
  let c : @types.Point2 = { x: 0.0, y: 8.0, }
  let forward = model.compare_distances(a, b, a, c)
  let reverse = model.compare_distances(a, c, a, b)
  assert_eq(forward.cross_contribution_m2, reverse.cross_contribution_m2)
  assert_eq(forward.difference_m, -reverse.difference_m)
  assert_eq(
    forward.difference_contribution_m2,
    reverse.difference_contribution_m2,
  )
  assert_eq(reverse.ratio, 1.0 / forward.ratio)
  assert_eq(
    reverse.ratio_mode_responses()[0],
    -forward.ratio_mode_responses()[0] / (forward.ratio * forward.ratio),
  )
}

///|
test "coincident and rounded coincident endpoints reject even empty mode models" {
  let identity = sensitivity_identity()
  let empty = @calibration.HomographySensitivity::new(identity, [])
  expect_invalid(() => {
    ignore(empty.distance({ x: 2.0, y: 3.0, }, { x: 2.0, y: 3.0, }))
  })
  let large_offset = @calibration.GroundCalibration::from_homography(
    [1.0, 0.0, 1.0e16, 0.0, 1.0, 1.0e16, 0.0, 0.0, 1.0],
    rectangle(),
    max_meters_per_pixel=2.0,
  )
  let model = @calibration.HomographySensitivity::new(large_offset, [])
  expect_invalid(() => {
    ignore(model.distance({ x: 0.0, y: 0.0, }, { x: 1.0, y: 0.0, }))
  })
}

///|
test "zero rank and all 32 original shared modes preserve their ordered scalar responses" {
  let identity = sensitivity_identity()
  let a : @types.Point2 = { x: 0.0, y: 0.0, }
  let b : @types.Point2 = { x: 4.0, y: 0.0, }
  let empty = @calibration.HomographySensitivity::new(identity, []).compare_distances(
    a, b, a, b,
  )
  assert_eq(empty.ratio, 1.0)
  assert_eq(empty.first.std_m, 0.0)
  assert_eq(empty.difference_mode_responses_m(), [])
  let model = @calibration.HomographySensitivity::new(
    identity,
    Array::make(32, distance_scale_model().modes()[0]),
  )
  let result = model.compare_distances(a, b, a, b)
  assert_eq(result.first.contribution_m2, 8.0)
  assert_eq(result.first.mode_responses_m(), Array::make(32, 0.5))
  assert_eq(result.difference_contribution_m2, 0.0)
  assert_eq(result.ratio_contribution, 0.0)
}

///|
test "distance and contrast response arrays are isolated and failed queries leave the model reusable" {
  let model = distance_scale_model()
  let a : @types.Point2 = { x: 0.0, y: 0.0, }
  let b : @types.Point2 = { x: 4.0, y: 0.0, }
  let c : @types.Point2 = { x: 8.0, y: 0.0, }
  let result = model.compare_distances(a, b, a, c)
  let responses = result.first.mode_responses_m()
  responses[0] = 999.0
  let differences = result.difference_mode_responses_m()
  differences.clear()
  let ratios = result.ratio_mode_responses()
  ratios.clear()
  expect_invalid(() => ignore(model.compare_distances(a, b, a, a)))
  expect_invalid(() => ignore(model.distance(a, { x: 101.0, y: 0.0, })))
  let repeated = model.compare_distances(a, b, a, c)
  assert_eq(repeated.first.mode_responses_m(), [0.5])
  assert_eq(
    repeated.difference_mode_responses_m(),
    result.difference_mode_responses_m(),
  )
  assert_eq(repeated.ratio_mode_responses(), result.ratio_mode_responses())
}

///|
test "distance comparisons reject unrepresentable ratios and late contrast variance overflow" {
  let huge_roi : Array[@types.Point2] = [
    { x: 0.0, y: 0.0, },
    { x: 1.0e200, y: 0.0, },
    { x: 1.0e200, y: 1.0e200, },
    { x: 0.0, y: 1.0e200, },
  ]
  let identity = @calibration.GroundCalibration::from_homography(
    sensitivity_identity().matrix(),
    huge_roi,
    max_meters_per_pixel=2.0,
  )
  let empty = @calibration.HomographySensitivity::new(identity, [])
  let zero : @types.Point2 = { x: 0.0, y: 0.0, }
  let big : @types.Point2 = { x: 1.0e200, y: 0.0, }
  let tiny : @types.Point2 = { x: 1.0e-200, y: 0.0, }
  assert_eq(empty.distance(zero, big).distance_m, 1.0e200)
  expect_invalid(() => ignore(empty.compare_distances(zero, big, zero, tiny)))
  expect_invalid(() => ignore(empty.compare_distances(zero, tiny, zero, big)))
  let large = @calibration.HomographySensitivity::new(sensitivity_identity(), [
    [1.0e154, 0.0, 0.0, 0.0, -1.0e154, 0.0, 0.0, 0.0, 0.0],
  ])
  assert_true(large.distance(zero, { x: 1.0, y: 0.0, }).contribution_m2 > 0.0)
  expect_invalid(() => {
    ignore(
      large.compare_distances(zero, { x: 1.0, y: 0.0, }, zero, {
        x: 0.0,
        y: 1.0,
      }),
    )
  })
}
