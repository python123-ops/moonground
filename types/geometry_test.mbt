///|
test "finite points and strictly positive measurement covariance" {
  let point = @types.Point2::new(1.0, -2.0)
  assert_eq(point.x, 1.0)
  assert_eq(point.y, -2.0)
  let covariance = @types.Covariance2::isotropic(2.0)
  assert_eq(covariance.xx, 4.0)
  assert_eq(covariance.yy, 4.0)
  assert_eq(covariance.xy, 0.0)
  let sample = @types.GroundObservation::new(1, point, covariance)
  assert_eq(sample.track_id, 1)
  try @types.Point2::new(1.0 / 0.0, 0.0) catch {
    _ => ()
  } noraise {
    _ => fail("infinite point accepted")
  }
  try @types.Covariance2::new(1.0, 1.0, 1.0) catch {
    _ => ()
  } noraise {
    _ => fail("singular covariance accepted")
  }
  try @types.Covariance2::new(1.0, 2.0, 1.0) catch {
    _ => ()
  } noraise {
    _ => fail("indefinite covariance accepted")
  }
  try @types.GroundObservation::new(0, point, covariance) catch {
    _ => ()
  } noraise {
    _ => fail("zero identity accepted")
  }
}

///|
test "covariance scaling does not overflow determinant check" {
  let large = @types.Covariance2::new(1.0e200, 1.0e199, 2.0e200)
  assert_eq(large.xx, 1.0e200)
  let small = @types.Covariance2::new(1.0e-200, 1.0e-201, 2.0e-200)
  assert_eq(small.yy, 2.0e-200)
  try @types.Covariance2::isotropic(1.0e200) catch {
    _ => ()
  } noraise {
    _ => fail("overflowed variance accepted")
  }
}
