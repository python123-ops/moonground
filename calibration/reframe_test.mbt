///|
test "reframed projective calibration preserves ground points covariance and transformed ROI boundaries" {
  let calibration = @calibration.GroundCalibration::from_homography(
    [0.1, 0.015, 1.0, -0.005, 0.08, 2.0, 0.001, -0.0003, 1.0],
    rectangle(),
    ground_noise_floor_m=0.17,
  )
  let transform = @types.PixelTransform::new(
    scale_x=0.5,
    scale_y=3.0,
    offset_x=-40.0,
    offset_y=17.0,
  )
  let reframed = calibration.reframed(transform)
  let covariance = @types.Covariance2::new(4.0, 1.2, 9.0)
  for point in rectangle() + [{ x: 20.0, y: 70.0, }, { x: 0.0, y: 50.0, }] {
    let original = calibration.project(point, covariance)
    let transformed = transform.point(point)
    let actual = reframed.project(transformed, transform.covariance(covariance))
    close(actual.position().x, original.position().x)
    close(actual.position().y, original.position().y)
    close(actual.covariance().xx, original.covariance().xx)
    close(actual.covariance().xy, original.covariance().xy)
    close(actual.covariance().yy, original.covariance().yy)
    let before = calibration.jacobian(point)
    let after = reframed.jacobian(transformed)
    close(after[0], before[0] / transform.scale_x)
    close(after[1], before[1] / transform.scale_y)
    close(after[2], before[2] / transform.scale_x)
    close(after[3], before[3] / transform.scale_y)
  }
  expect_invalid(() => {
    ignore(reframed.map_point(transform.point({ x: -0.01, y: 50.0, })))
  })
  expect_invalid(() => {
    ignore(reframed.map_point(transform.point({ x: 50.0, y: 100.01, })))
  })
  for i in 0..<rectangle().length() {
    let expected = transform.point(rectangle()[i])
    assert_eq(reframed.roi()[i].x, expected.x)
    assert_eq(reframed.roi()[i].y, expected.y)
  }
  let exported = reframed.matrix()
  exported[0] = 999.0
  let roi_copy = reframed.roi()
  roi_copy[0] = { x: 999.0, y: 999.0, }
  close(
    reframed.map_point(transform.point({ x: 20.0, y: 70.0, })).x,
    calibration.map_point({ x: 20.0, y: 70.0, }).x,
  )
}

///|
test "reframed fitted calibration retains SI fit and independent check statistics" {
  let controls = control_pixels()
  let checks = check_pixels()
  let calibration = @calibration.GroundCalibration::fit(
    controls,
    exact_world(controls),
    checks,
    exact_world(checks),
    rectangle(),
  )
  let transform = @types.PixelTransform::new(
    scale_x=0.25,
    scale_y=0.5,
    offset_x=100.0,
    offset_y=-9.0,
  )
  let reframed = calibration.reframed(transform)
  let before = calibration.report()
  let after = reframed.report()
  assert_eq(after.fit_count(), before.fit_count())
  assert_eq(after.check_count(), before.check_count())
  assert_eq(after.fit_rms_m(), before.fit_rms_m())
  assert_eq(after.fit_max_error_m(), before.fit_max_error_m())
  assert_eq(after.check_rms_m(), before.check_rms_m())
  assert_eq(after.check_max_error_m(), before.check_max_error_m())
  assert_true(
    after.roi_scale_bound_m_per_pixel() > before.roi_scale_bound_m_per_pixel(),
  )
  let identity = calibration.reframed(@types.PixelTransform::new())
  assert_eq(identity.matrix(), calibration.matrix())
  for i in 0..<identity.roi().length() {
    assert_eq(identity.roi()[i].x, calibration.roi()[i].x)
    assert_eq(identity.roi()[i].y, calibration.roi()[i].y)
  }
  assert_eq(
    identity.report().roi_scale_bound_m_per_pixel(),
    before.roi_scale_bound_m_per_pixel(),
  )
}

///|
test "unrepresentable calibration reframing rejects without changing the original domain" {
  let calibration = @calibration.GroundCalibration::from_homography(
    affine_matrix(),
    rectangle(),
  )
  let before_matrix = calibration.matrix()
  let before_roi = calibration.roi()
  for
    transform in [
      @types.PixelTransform::new(scale_x=1.0e-308),
      @types.PixelTransform::new(offset_x=1.0e300),
      @types.PixelTransform::new(scale_x=1.0e-20),
    ] {
    expect_invalid(() => ignore(calibration.reframed(transform)))
  }
  assert_eq(calibration.matrix(), before_matrix)
  for i in 0..<before_roi.length() {
    assert_eq(calibration.roi()[i].x, before_roi[i].x)
    assert_eq(calibration.roi()[i].y, before_roi[i].y)
  }
  close(calibration.map_point({ x: 20.0, y: 30.0, }).x, 3.6)
}
