///|
test "packaged signed offsets share moving reference anchors and retain negative correlation" {
  let result = consumer_area_model().compare_line_offsets(
    { x: 0.0, y: 4.0, },
    { x: 8.0, y: 4.0, },
    { x: 2.0, y: 7.0, },
    { x: 2.0, y: 2.0, },
  )
  assert_eq(result.first.signed_offset_m, 3.0)
  assert_eq(result.second.signed_offset_m, -2.0)
  assert_eq(result.cross_contribution_m2, -0.09375)
  assert_eq(result.difference_mode_responses_m(), [0.625])
  assert_eq(result.difference_std_m, 0.625)
  // The configured 10 m ground noise floor is not part of calibration modes.
  assert_eq(result.first.std_m, 0.375)
}

///|
test "packaged on line offsets and repeated probes remain valid and independently copied" {
  let model = consumer_area_model()
  let a : @moonground.Point2 = { x: 0.0, y: 4.0, }
  let b : @moonground.Point2 = { x: 8.0, y: 4.0, }
  let p : @moonground.Point2 = { x: 10.0, y: 4.0, }
  let offset = model.line_offset(a, b, p)
  assert_eq(offset.signed_offset_m, 0.0)
  let contrast = model.compare_line_offsets(a, b, p, p)
  contrast.first.mode_responses_m().clear()
  contrast.difference_mode_responses_m().clear()
  assert_eq(contrast.first.mode_responses_m(), [0.0])
  assert_eq(contrast.difference_mode_responses_m(), [0.0])
  try model.line_offset(a, a, p) catch {
    _ => ()
  } noraise {
    _ => fail("coincident reference accepted")
  }
  assert_eq(model.line_offset(b, a, { x: 2.0, y: 7.0, }).signed_offset_m, -3.0)
}
