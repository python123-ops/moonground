///|
test "signed line offsets preserve shared scale and negative cross contribution" {
  let model = distance_scale_model()
  let result = model.compare_line_offsets(
    { x: 0.0, y: 4.0, },
    { x: 8.0, y: 4.0, },
    { x: 2.0, y: 7.0, },
    { x: 2.0, y: 2.0, },
  )
  assert_eq(result.first.signed_offset_m, 3.0)
  assert_eq(result.second.signed_offset_m, -2.0)
  assert_eq(result.first.mode_responses_m(), [0.375])
  assert_eq(result.second.mode_responses_m(), [-0.25])
  assert_eq(result.cross_contribution_m2, -0.09375)
  assert_eq(result.difference_m, 5.0)
  assert_eq(result.difference_mode_responses_m(), [0.625])
  assert_eq(result.difference_std_m, 0.625)
}

///|
test "both line anchors move with translation rotation and horizontal shear" {
  let modes = sensitivity_translation()
  modes.push(angle_rotation_model().modes()[0])
  modes.push([0.0, 0.0, 0.0, 0.125, 0.0, 0.0, 0.0, 0.0, 0.0])
  let model = @calibration.HomographySensitivity::new(
    sensitivity_identity(),
    modes,
  )
  let result = model.line_offset({ x: 0.0, y: 4.0, }, { x: 8.0, y: 4.0, }, {
    x: 2.0,
    y: 7.0,
  })
  assert_eq(result.signed_offset_m, 3.0)
  assert_eq(result.mode_responses_m(), [0.0, 0.0, 0.0, 0.0])
  assert_eq(result.std_m, 0.0)
}

///|
test "anisotropic scale differentiates the moving oblique reference normal" {
  let model = @calibration.HomographySensitivity::new(sensitivity_identity(), [
    [0.125, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
  ])
  let value = model.line_offset({ x: 0.0, y: 0.0, }, { x: 3.0, y: 4.0, }, {
    x: 4.0,
    y: 0.0,
  })
  close(value.signed_offset_m, -3.2)
  close(value.mode_responses_m()[0], -0.256)
}

///|
test "on line pixels and points beyond an anchor remain valid signed offsets" {
  let value = distance_scale_model().line_offset(
    { x: 0.0, y: 4.0, },
    { x: 8.0, y: 4.0, },
    { x: 12.0, y: 4.0, },
  )
  assert_eq(value.signed_offset_m, 0.0)
  assert_eq(value.mode_responses_m(), [0.0])
  assert_eq(value.std_m, 0.0)
}

///|
test "reversing anchors reverses signed offsets and contrasts but not contributions" {
  let model = distance_scale_model()
  let a : @types.Point2 = { x: 0.0, y: 4.0, }
  let b : @types.Point2 = { x: 8.0, y: 4.0, }
  let p : @types.Point2 = { x: 2.0, y: 7.0, }
  let q : @types.Point2 = { x: 2.0, y: 2.0, }
  let forward = model.compare_line_offsets(a, b, p, q)
  let reverse = model.compare_line_offsets(b, a, p, q)
  assert_eq(reverse.first.signed_offset_m, -forward.first.signed_offset_m)
  assert_eq(reverse.first.mode_responses_m(), [-0.375])
  assert_eq(reverse.difference_m, -forward.difference_m)
  assert_eq(reverse.difference_mode_responses_m(), [-0.625])
  assert_eq(reverse.cross_contribution_m2, forward.cross_contribution_m2)
  assert_eq(
    reverse.difference_contribution_m2,
    forward.difference_contribution_m2,
  )
}

///|
test "the same point has zero difference despite nonzero marginal contributions" {
  let point : @types.Point2 = { x: 2.0, y: 7.0, }
  let result = distance_scale_model().compare_line_offsets(
    { x: 0.0, y: 4.0, },
    { x: 8.0, y: 4.0, },
    point,
    point,
  )
  assert_eq(result.first.std_m, 0.375)
  assert_eq(result.difference_m, 0.0)
  assert_eq(result.difference_mode_responses_m(), [0.0])
  assert_eq(result.difference_std_m, 0.0)
  let detached = result.first.mode_responses_m()
  detached[0] = 19.0
  let differences = result.difference_mode_responses_m()
  differences[0] = 17.0
  assert_eq(result.first.mode_responses_m(), [0.375])
  assert_eq(result.difference_mode_responses_m(), [0.0])
}

///|
test "empty modes allow zero offset and very short represented reference lines" {
  let model = @calibration.HomographySensitivity::new(sensitivity_identity(), [])
  let value = model.line_offset({ x: 0.0, y: 0.0, }, { x: 1.0e-200, y: 0.0, }, {
    x: 0.0,
    y: 3.0,
  })
  assert_eq(value.signed_offset_m, 3.0)
  assert_eq(value.std_m, 0.0)
  assert_eq(value.mode_responses_m(), [])
}

///|
test "coincident represented reference anchors are rejected even with no modes" {
  let model = @calibration.HomographySensitivity::new(sensitivity_identity(), [])
  let point : @types.Point2 = { x: 1.0, y: 1.0, }
  expect_invalid(() => ignore(model.line_offset(point, point, point)))
}

///|
test "every line anchor and query pixel must satisfy the original closed ROI" {
  let model = distance_scale_model()
  let a : @types.Point2 = { x: 0.0, y: 4.0, }
  let b : @types.Point2 = { x: 8.0, y: 4.0, }
  let p : @types.Point2 = { x: 2.0, y: 7.0, }
  let bad : @types.Point2 = { x: -1.0, y: 0.0, }
  expect_invalid(() => ignore(model.line_offset(bad, b, p)))
  expect_invalid(() => ignore(model.line_offset(a, bad, p)))
  expect_invalid(() => ignore(model.line_offset(a, b, bad)))
  expect_invalid(() => ignore(model.compare_line_offsets(a, b, p, bad)))
}

///|
test "direct offset contrast retains a small separation far from the reference line" {
  let calibration = @calibration.GroundCalibration::from_homography(
    [1.0e15, 0.0, 0.0, 0.0, 1.0e15, -1.0e15, 0.0, 0.0, 1.0],
    rectangle(),
    max_meters_per_pixel=2.0e15,
  )
  let result = @calibration.HomographySensitivity::new(calibration, []).compare_line_offsets(
    { x: 0.0, y: 0.0, },
    { x: 1.0, y: 0.0, },
    { x: 0.0, y: 1.0, },
    { x: 0.0, y: 1.0000000000000002, },
  )
  assert_eq(
    result.difference_m,
    result.first.position_m.y - result.second.position_m.y,
  )
  assert_true(
    result.difference_m !=
    result.first.signed_offset_m - result.second.signed_offset_m,
  )
  assert_true(result.difference_m < 0.0)
}

///|
test "maximum mode count and zero homogeneous gauge retain exact mode order" {
  let modes = Array::make(32, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
  modes[4] = sensitivity_translation()[0]
  modes[13] = [0.125, 0.0, 0.0, 0.0, 0.125, 0.0, 0.0, 0.0, 0.125]
  modes[31] = distance_scale_model().modes()[0]
  let value = @calibration.HomographySensitivity::new(
    sensitivity_identity(),
    modes,
  ).line_offset({ x: 0.0, y: 4.0, }, { x: 8.0, y: 4.0, }, { x: 2.0, y: 7.0, })
  assert_eq(value.mode_responses_m().length(), 32)
  assert_eq(value.mode_responses_m()[4], 0.0)
  assert_eq(value.mode_responses_m()[13], 0.0)
  assert_eq(value.mode_responses_m()[31], 0.375)
}

///|
test "reflected calibration reverses ground side and malformed points do not poison later queries" {
  let calibration = @calibration.GroundCalibration::from_homography(
    [-1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    rectangle(),
    max_meters_per_pixel=2.0,
  )
  let model = @calibration.HomographySensitivity::new(calibration, [])
  let a : @types.Point2 = { x: 0.0, y: 4.0, }
  let b : @types.Point2 = { x: 8.0, y: 4.0, }
  expect_invalid(() => {
    ignore(model.line_offset(a, b, { x: 0.0 / 0.0, y: 0.0, }))
  })
  let value = model.line_offset(a, b, { x: 2.0, y: 7.0, })
  assert_eq(value.signed_offset_m, -3.0)
  assert_eq(value.std_m, 0.0)
}
