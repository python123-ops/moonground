///|
fn consumer_angle_model() -> @calibration.HomographySensitivity raise {
  let calibration = @calibration.GroundCalibration::from_homography(
    [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 10.0, y: 0.0, },
      { x: 10.0, y: 10.0, },
      { x: 0.0, y: 10.0, },
    ],
    max_meters_per_pixel=2.0,
    ground_noise_floor_m=10.0,
  )
  @calibration.HomographySensitivity::new(calibration, [
    [0.0, -0.125, 0.0, 0.125, 0.0, 0.0, 0.0, 0.0, 0.0],
  ])
}

///|
test "packaged directions retain common rotation and cancel it in a relative angle" {
  let result = consumer_angle_model().compare_directions(
    { x: 0.0, y: 0.0, },
    { x: 3.0, y: 4.0, },
    { x: 0.0, y: 0.0, },
    { x: 0.0, y: 8.0, },
  )
  assert_eq(result.first.distance_m, 5.0)
  assert_eq(result.first.std_rad, 0.125)
  assert_eq(result.second.std_rad, 0.125)
  assert_eq(result.cross_contribution_rad2, 0.015625)
  assert_eq(result.mode_responses_rad(), [0.0])
  assert_eq(result.std_rad, 0.0)
  assert_true((result.angle_rad - 0.6435011087932844).abs() < 1.0e-14)
}

///|
test "packaged direction reversal keeps its local tangent at the canonical angle cut" {
  let model = consumer_angle_model()
  let origin : @moonground.Point2 = { x: 0.0, y: 0.0, }
  let end : @moonground.Point2 = { x: 3.0, y: 4.0, }
  let result = model.compare_directions(origin, end, end, origin)
  assert_eq(result.angle_rad, 3.141592653589793)
  assert_eq(
    result.first.mode_responses_rad(),
    result.second.mode_responses_rad(),
  )
  assert_eq(result.contribution_rad2, 0.0)
}

///|
test "packaged angular response copies and failed queries leave the model reusable" {
  let model = consumer_angle_model()
  let origin : @moonground.Point2 = { x: 0.0, y: 0.0, }
  let end : @moonground.Point2 = { x: 3.0, y: 4.0, }
  let result = model.compare_directions(origin, end, end, origin)
  let first = result.first.mode_responses_rad()
  first[0] = 999.0
  let angle = result.mode_responses_rad()
  angle.clear()
  try model.segment_direction(origin, origin) catch {
    _ => ()
  } noraise {
    _ => fail("undefined direction accepted")
  }
  let repeated = model.compare_directions(origin, end, end, origin)
  assert_eq(repeated.first.mode_responses_rad(), [0.125])
  assert_eq(repeated.mode_responses_rad(), [0.0])
}
