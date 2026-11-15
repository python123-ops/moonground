///|
fn consumer_area_model() -> @calibration.HomographySensitivity raise {
  @calibration.HomographySensitivity::new(
    @calibration.GroundCalibration::from_homography(
      [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      [
        { x: 0.0, y: 0.0, },
        { x: 10.0, y: 0.0, },
        { x: 10.0, y: 10.0, },
        { x: 0.0, y: 10.0, },
      ],
      max_meters_per_pixel=2.0,
      ground_noise_floor_m=10.0,
    ),
    [[0.125, 0.0, 0.0, 0.0, 0.125, 0.0, 0.0, 0.0, 0.0]],
  )
}

///|
fn consumer_area_triangle(side : Double) -> Array[@moonground.Point2] {
  [{ x: 0.0, y: 0.0, }, { x: side, y: 0.0, }, { x: 0.0, y: side, }]
}

///|
test "packaged convex area contrasts keep shared covariance and ratio cancellation" {
  let result = consumer_area_model().compare_areas(
    consumer_area_triangle(4.0),
    consumer_area_triangle(8.0),
  )
  assert_eq(result.first.area_m2, 8.0)
  assert_eq(result.second.area_m2, 32.0)
  assert_eq(result.cross_contribution_m4, 16.0)
  assert_eq(result.difference_std_m2, 6.0)
  assert_eq(result.ratio, 0.25)
  assert_eq(result.ratio_std, 0.0)
}

///|
test "packaged reversed winding retains absolute area and original ground vertex order" {
  let model = consumer_area_model()
  let polygon = consumer_area_triangle(4.0)
  let result = model.polygon_area([polygon[2], polygon[1], polygon[0]])
  assert_eq(result.signed_area_m2, -8.0)
  assert_eq(result.area_m2, 8.0)
  assert_eq(result.mode_responses_m2(), [2.0])
  assert_eq(result.positions_m()[0].y, 4.0)
}

///|
test "packaged area copies and rejected queries preserve subsequent comparisons" {
  let model = consumer_area_model()
  let polygon = consumer_area_triangle(4.0)
  let result = model.compare_areas(polygon, polygon)
  result.first.positions_m().clear()
  result.first.mode_responses_m2().clear()
  result.difference_mode_responses_m2().clear()
  result.ratio_mode_responses().clear()
  polygon[0] = { x: 100.0, y: 100.0, }
  try model.polygon_area(polygon) catch {
    _ => ()
  } noraise {
    _ => fail("out of ROI accepted")
  }
  assert_eq(result.first.positions_m().length(), 3)
  assert_eq(result.first.mode_responses_m2(), [2.0])
  assert_eq(result.ratio_mode_responses(), [0.0])
  assert_eq(model.polygon_area(consumer_area_triangle(4.0)).area_m2, 8.0)
}
