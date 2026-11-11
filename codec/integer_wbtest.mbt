///|
test "programmatic numeric integers without original tokens remain supported" {
  assert_eq(positive_int(Json(4), "count"), 4)
  assert_eq(positive_int(Json(2147483647), "count"), 2147483647)
  for value in [Json(4.25), Json(2147483648.0)] {
    try positive_int(value, "count") catch {
      _ => ()
    } noraise {
      _ => fail("noninteger programmatic value accepted")
    }
  }
}
