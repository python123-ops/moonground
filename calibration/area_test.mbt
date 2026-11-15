///|
fn area_square(x : Double, y : Double, side : Double) -> Array[@types.Point2] {
  [
    { x, y, },
    { x: x + side, y, },
    { x: x + side, y: y + side, },
    { x, y: y + side, },
  ]
}

///|
fn area_triangle(side : Double) -> Array[@types.Point2] {
  [{ x: 0.0, y: 0.0, }, { x: side, y: 0.0, }, { x: 0.0, y: side, }]
}

///|
fn area_perspective_mode(scale : Double) -> Array[Double] {
  [0.125 * scale, 0.0, 0.0, 0.0, 0.125 * scale, 0.0, 0.015625 * scale, 0.0, 0.0]
}

///|
test "convex ground area propagates shared isotropic scale in square metres" {
  let result = distance_scale_model().polygon_area(area_square(0.0, 0.0, 4.0))
  assert_eq(result.signed_area_m2, 16.0)
  assert_eq(result.area_m2, 16.0)
  assert_eq(result.mode_responses_m2(), [4.0])
  assert_eq(result.contribution_m4, 16.0)
  assert_eq(result.std_m2, 4.0)
  assert_eq(sensitivity_values(result.positions_m()), [
    (0.0, 0.0),
    (4.0, 0.0),
    (4.0, 4.0),
    (0.0, 4.0),
  ])
}

///|
test "common scale cancels from an area ratio while retaining correlated area errors" {
  let result = distance_scale_model().compare_areas(
    area_triangle(4.0),
    area_triangle(8.0),
  )
  assert_eq(result.first.area_m2, 8.0)
  assert_eq(result.second.area_m2, 32.0)
  assert_eq(result.cross_contribution_m4, 16.0)
  assert_eq(result.difference_m2, -24.0)
  assert_eq(result.difference_mode_responses_m2(), [-6.0])
  assert_eq(result.difference_contribution_m4, 36.0)
  assert_eq(result.difference_std_m2, 6.0)
  assert_eq(result.ratio, 0.25)
  assert_eq(result.ratio_mode_responses(), [0.0])
  assert_eq(result.ratio_contribution, 0.0)
}

///|
test "shared translation and rotation have zero first order area response with higher order rotation effect" {
  let modes = sensitivity_translation()
  modes.push(angle_rotation_model().modes()[0])
  let result = @calibration.HomographySensitivity::new(
    sensitivity_identity(),
    modes,
  ).polygon_area(area_square(1.0, 2.0, 4.0))
  assert_eq(result.mode_responses_m2(), [0.0, 0.0, 0.0])
  assert_eq(result.std_m2, 0.0)
  // I + xi*[0,-s;s,0] has determinant 1 + xi^2*s^2.
  assert_true(result.area_m2 * (1.0 + 0.125 * 0.125) > result.area_m2)
}

///|
test "perspective modes can give negative area cross contribution and enlarged differences" {
  let model = @calibration.HomographySensitivity::new(sensitivity_identity(), [
    area_perspective_mode(1.0),
  ])
  let result = model.compare_areas(
    area_square(0.0, 0.0, 4.0),
    area_square(8.0, 0.0, 4.0),
  )
  close(result.first.mode_responses_m2()[0], 2.5)
  close(result.second.mode_responses_m2()[0], -3.5)
  close(result.cross_contribution_m4, -8.75)
  close(result.difference_contribution_m4, 36.0)
  close(result.ratio_mode_responses()[0], 0.375)
  close(result.ratio_contribution, 0.140625)
}

///|
test "winding reversal and cyclic vertex origin retain absolute area sensitivity" {
  let model = distance_scale_model()
  let p = area_square(1.0, 2.0, 4.0)
  let forward = model.polygon_area(p)
  let reverse = model.polygon_area([p[3], p[2], p[1], p[0]])
  let cyclic = model.polygon_area([p[1], p[2], p[3], p[0]])
  assert_eq(reverse.signed_area_m2, -forward.signed_area_m2)
  assert_eq(reverse.area_m2, forward.area_m2)
  assert_eq(reverse.mode_responses_m2(), forward.mode_responses_m2())
  assert_eq(cyclic.mode_responses_m2(), forward.mode_responses_m2())
}

///|
test "a reflected calibration retains ground winding and positive absolute area response" {
  let calibration = @calibration.GroundCalibration::from_homography(
    [-1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    rectangle(),
    max_meters_per_pixel=2.0,
  )
  let result = @calibration.HomographySensitivity::new(calibration, [
    [-0.125, 0.0, 0.0, 0.0, 0.125, 0.0, 0.0, 0.0, 0.0],
  ]).polygon_area(area_square(0.0, 0.0, 4.0))
  assert_eq(result.signed_area_m2, -16.0)
  assert_eq(result.area_m2, 16.0)
  assert_eq(result.mode_responses_m2(), [4.0])
}

///|
test "anchored area avoids cancellation between large absolute ground coordinates" {
  let calibration = @calibration.GroundCalibration::from_homography(
    sensitivity_identity().matrix(),
    area_square(0.0, 0.0, 1.0e12 + 16.0),
    max_meters_per_pixel=2.0,
  )
  let result = @calibration.HomographySensitivity::new(
    calibration,
    sensitivity_translation(),
  ).polygon_area(area_square(1.0e12, 1.0e12, 4.0))
  assert_eq(result.area_m2, 16.0)
  assert_eq(result.mode_responses_m2(), [0.0, 0.0])
}

///|
test "zero rank and 32 modes retain ordered area responses and shared cancellation" {
  let polygon = area_square(0.0, 0.0, 4.0)
  let empty = @calibration.HomographySensitivity::new(sensitivity_identity(), []).polygon_area(
    polygon,
  )
  assert_eq(empty.std_m2, 0.0)
  assert_eq(empty.mode_responses_m2(), [])
  let model = @calibration.HomographySensitivity::new(
    sensitivity_identity(),
    Array::make(32, distance_scale_model().modes()[0]),
  )
  let result = model.compare_areas(polygon, polygon)
  assert_eq(result.first.mode_responses_m2(), Array::make(32, 4.0))
  assert_eq(result.first.contribution_m4, 512.0)
  assert_eq(result.difference_contribution_m4, 0.0)
  assert_eq(result.ratio, 1.0)
  assert_eq(result.ratio_contribution, 0.0)
}

///|
test "polygon input vertices output positions and contrast responses are isolated" {
  let model = distance_scale_model()
  let polygon = area_square(0.0, 0.0, 4.0)
  let result = model.compare_areas(polygon, area_square(0.0, 0.0, 8.0))
  polygon[0] = { x: 999.0, y: 999.0, }
  let positions = result.first.positions_m()
  positions.clear()
  let responses = result.first.mode_responses_m2()
  responses[0] = 999.0
  let differences = result.difference_mode_responses_m2()
  differences.clear()
  let ratios = result.ratio_mode_responses()
  ratios.clear()
  assert_eq(result.first.positions_m().length(), 4)
  assert_eq(result.first.positions_m()[0].x, 0.0)
  assert_eq(result.first.mode_responses_m2(), [4.0])
  assert_eq(result.difference_mode_responses_m2(), [-12.0])
  assert_eq(result.ratio_mode_responses(), [0.0])
}

///|
test "polygon cardinality repeats concavity crossing nonfinite and collinearity reject" {
  let model = distance_scale_model()
  let p = area_square(0.0, 0.0, 4.0)
  let bad : Array[Array[@types.Point2]] = [
    [],
    [p[0], p[1]],
    Array::make(65, p[0]),
    [p[0], p[1], p[2], p[3], p[0]],
    [p[0], p[1], { x: 1.0, y: 1.0, }, p[3]],
    [p[0], p[2], p[1], p[3]],
    [{ x: 0.0, y: 0.0, }, { x: 1.0, y: 0.0, }, { x: 2.0, y: 0.0, }],
    [p[0], p[1], { x: 0.0 / 0.0, y: 1.0, }],
  ]
  for polygon in bad {
    expect_invalid(() => ignore(model.polygon_area(polygon)))
  }
}

///|
test "out of ROI and rounded ground collapse reject and leave later area queries usable" {
  let model = distance_scale_model()
  expect_invalid(() => ignore(model.polygon_area(area_square(99.0, 99.0, 4.0))))
  let shifted = @calibration.GroundCalibration::from_homography(
    [1.0, 0.0, 1.0e16, 0.0, 1.0, 1.0e16, 0.0, 0.0, 1.0],
    rectangle(),
    max_meters_per_pixel=2.0,
  )
  let collapsed = @calibration.HomographySensitivity::new(shifted, [])
  expect_invalid(() => ignore(collapsed.polygon_area(area_triangle(1.0))))
  assert_eq(model.polygon_area(area_square(0.0, 0.0, 4.0)).area_m2, 16.0)
}

///|
test "finite area avoids doubled area overflow while unrepresentable areas and ratios reject" {
  let calibration = @calibration.GroundCalibration::from_homography(
    sensitivity_identity().matrix(),
    area_square(0.0, 0.0, 1.5e154),
    max_meters_per_pixel=2.0,
  )
  let model = @calibration.HomographySensitivity::new(calibration, [])
  let large = model.polygon_area(area_triangle(1.5e154))
  close(large.area_m2 / 1.125e308, 1.0, tolerance=1.0e-14)
  let tiny = model.polygon_area(area_triangle(1.0e-150))
  close(tiny.area_m2 / 5.0e-301, 1.0, tolerance=1.0e-14)
  expect_invalid(() => {
    ignore(model.polygon_area(area_square(0.0, 0.0, 1.5e154)))
  })
  expect_invalid(() => ignore(model.polygon_area(area_triangle(1.0e-200))))
  expect_invalid(() => {
    ignore(model.compare_areas(area_triangle(1.5e154), area_triangle(1.0e-150)))
  })
  expect_invalid(() => {
    ignore(model.compare_areas(area_triangle(1.0e-150), area_triangle(1.5e154)))
  })
}

///|
test "single area variance and late contrast variance overflow reject explicitly" {
  let variance = @calibration.HomographySensitivity::new(
    sensitivity_identity(),
    [[1.0e153, 0.0, 0.0, 0.0, 1.0e153, 0.0, 0.0, 0.0, 0.0]],
  )
  expect_invalid(() => ignore(variance.polygon_area(area_square(0.0, 0.0, 4.0))))
  let model = @calibration.HomographySensitivity::new(sensitivity_identity(), [
    area_perspective_mode(3.2e153),
  ])
  let first = area_square(0.0, 0.0, 4.0)
  let second = area_square(8.0, 0.0, 4.0)
  assert_true(model.polygon_area(first).contribution_m4 > 0.0)
  assert_true(model.polygon_area(second).contribution_m4 > 0.0)
  expect_invalid(() => ignore(model.compare_areas(first, second)))
}

///|
test "64 vertices work and the inherited strict convexity margin is explicit" {
  let polygon : Array[@types.Point2] = []
  for i in 0..<64 {
    let angle = i.to_double() * 6.283185307179586 / 64.0
    polygon.push({
      x: 50.0 + 30.0 * @math.cos(angle),
      y: 50.0 + 30.0 * @math.sin(angle),
    })
  }
  let model = @calibration.HomographySensitivity::new(sensitivity_identity(), [])
  assert_true(model.polygon_area(polygon).area_m2 > 2800.0)
  let thin : Array[@types.Point2] = [
    { x: 0.0, y: 0.0, },
    { x: 1.0, y: 0.0, },
    { x: 0.0, y: 1.0e-12, },
  ]
  expect_invalid(() => ignore(model.polygon_area(thin)))
  close(
    model.polygon_area([
      { x: 0.0, y: 0.0, },
      { x: 1.0, y: 0.0, },
      { x: 0.0, y: 2.0e-12, },
    ]).area_m2,
    1.0e-12,
    tolerance=1.0e-26,
  )
}
