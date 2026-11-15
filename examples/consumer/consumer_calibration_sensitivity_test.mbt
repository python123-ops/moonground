///|
fn consumer_sensitivity() -> @calibration.HomographySensitivity raise {
  let calibration = @moonground.GroundCalibration::from_homography(
    [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 10.0, y: 0.0, },
      { x: 10.0, y: 10.0, },
      { x: 0.0, y: 10.0, },
    ],
    max_meters_per_pixel=2.0,
  )
  @calibration.HomographySensitivity::new(calibration, [
    [0.0, 0.0, 0.25, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0],
    [0.125, 0.0, 0.0, 0.0, 0.0, 0.25, 0.0, 0.0, 0.0],
  ])
}

///|
test "packaged calibration modes preserve common translation and asymmetric cross contribution" {
  let model = consumer_sensitivity()
  let pair = model.evaluate_pair({ x: 2.0, y: 1.0, }, { x: 4.0, y: 3.0, })
  assert_eq(pair.first.contribution_m2.xx, 0.125)
  assert_eq(pair.cross_contribution_m2(), [0.1875, 0.1875, 0.25, 0.3125])
  assert_eq(pair.displacement_contribution_m2.xx, 0.0625)
  assert_eq(pair.displacement_contribution_m2.xy, 0.0)
  assert_eq(pair.displacement_contribution_m2.yy, 0.0)
}

///|
test "packaged sensitivity outputs are isolated from mutation and failed pixel probes" {
  let model = consumer_sensitivity()
  let baseline = model.evaluate_pair({ x: 2.0, y: 1.0, }, { x: 4.0, y: 3.0, })
  let cross = baseline.cross_contribution_m2()
  cross.clear()
  let modes = model.modes()
  modes[0][2] = 123.0
  modes.clear()
  let responses = baseline.first.mode_responses_m()
  responses.clear()
  try model.evaluate_pair({ x: 2.0, y: 1.0, }, { x: 11.0, y: 3.0, }) catch {
    _ => ()
  } noraise {
    _ => fail("outside ROI accepted")
  }
  let repeated = model.evaluate_pair({ x: 2.0, y: 1.0, }, { x: 4.0, y: 3.0, })
  assert_eq(repeated.cross_contribution_m2(), baseline.cross_contribution_m2())
  assert_eq(repeated.first.mode_responses_m().length(), 2)
}

///|
test "packaged first order singular contributions and repeated point remain separate from observation covariance" {
  let model = consumer_sensitivity()
  let point : @moonground.Point2 = { x: 2.0, y: 1.0, }
  let repeated = model.evaluate_pair(point, point)
  assert_eq(repeated.displacement_contribution_m2.xx, 0.0)
  assert_eq(repeated.displacement_contribution_m2.yy, 0.0)
  assert_eq(repeated.first.position_m.x, 2.0)
  let empty = @calibration.HomographySensitivity::new(
    @moonground.GroundCalibration::from_homography(
      model.matrix(),
      [
        { x: 0.0, y: 0.0, },
        { x: 10.0, y: 0.0, },
        { x: 10.0, y: 10.0, },
        { x: 0.0, y: 10.0, },
      ],
      max_meters_per_pixel=2.0,
    ),
    [],
  ).evaluate(point)
  assert_eq(empty.contribution_m2.xx, 0.0)
  assert_eq(empty.contribution_m2.xy, 0.0)
  assert_eq(empty.contribution_m2.yy, 0.0)
}
