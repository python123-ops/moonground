///|
fn line_offset_request(comparisons : String, modes~ : String = "[]") -> String {
  "{\"calibration\":{\"matrix\":[1,0,0,0,1,0,0,0,1],\"roi\":[[0,0],[100,0],[100,100],[0,100]],\"max_meters_per_pixel\":2},\"modes\":" +
  modes +
  ",\"comparisons\":" +
  comparisons +
  "}"
}

///|
test "line offset codec returns signed offsets and directly formed differences" {
  let source = line_offset_request(
    "[{\"probe_id\":\"opposite\",\"line_start\":[0,4],\"line_end\":[8,4],\"first_pixel\":[2,7],\"second_pixel\":[2,2]}]",
    modes="[[0.125,0,0,0,0.125,0,0,0,0]]",
  )
  let actual = @codec.calibration_line_offset_json(source)
  assert_true(
    actual.contains("\"kind\":\"calibration_line_offset_comparison\""),
  )
  assert_true(actual.contains("\"signed_offset_m\":3"))
  assert_true(actual.contains("\"difference_m\":5"))
  assert_true(actual.contains("\"cross_contribution_m2\":-0.09375"))
  assert_true(actual.contains("\"difference_std_m\":0.625"))
}

///|
test "empty line offset batches retain normalized baseline and mode count" {
  let actual = @codec.calibration_line_offset_json(line_offset_request("[]"))
  assert_true(actual.contains("\"comparisons\":[]"))
  assert_true(actual.contains("\"mode_count\":0"))
}

///|
fn line_offset_invalid(source : String) -> Unit raise {
  try @codec.calibration_line_offset_json(source) catch {
    _ => ()
  } noraise {
    _ => fail("invalid line offset request accepted")
  }
}

///|
test "line offset codec validates every row before returning any result" {
  let good = "{\"probe_id\":\"good\",\"line_start\":[0,4],\"line_end\":[8,4],\"first_pixel\":[2,7],\"second_pixel\":[2,2]}"
  let bad = "{\"probe_id\":\"bad\",\"line_start\":[0,4],\"line_end\":[0,4],\"first_pixel\":[2,7],\"second_pixel\":[2,2]}"
  line_offset_invalid(line_offset_request("[" + good + "," + bad + "]"))
  line_offset_invalid(line_offset_request("[" + good + "," + good + "]"))
}
