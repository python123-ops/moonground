///|
test "camera reframing preserves Brown lens inverse and covariance in destination pixels" {
  let camera = model()
  let transform = @types.PixelTransform::new(
    scale_x=0.5,
    scale_y=1.75,
    offset_x=-111.0,
    offset_y=47.0,
  )
  let reframed = camera.reframed(transform)
  assert_eq(reframed.parameters(), [
    425.0, 1067.5, 209.0, 677.0, 0.035, -0.006, 0.002, -0.0015, 0.001,
  ])
  assert_eq(reframed.max_normalized_radius(), camera.max_normalized_radius())
  let covariance = @types.Covariance2::new(4.0, 0.7, 9.0)
  let calibration = ground_calibration()
  let moved_calibration = calibration.reframed(transform)
  for raw in [raw_pixel(0.0, 0.0), raw_pixel(0.2, -0.1), raw_pixel(-0.45, 0.3)] {
    let moved_raw = transform.point(raw)
    let expected = transform.point(camera.rectify(raw))
    let actual = reframed.rectify(moved_raw)
    close(actual.x, expected.x)
    close(actual.y, expected.y)
    let expected_cov = transform.covariance(
      camera.rectify_covariance(raw, covariance),
    )
    let actual_cov = reframed.rectify_covariance(
      moved_raw,
      transform.covariance(covariance),
    )
    close(actual_cov.xx, expected_cov.xx)
    close(actual_cov.xy, expected_cov.xy)
    close(actual_cov.yy, expected_cov.yy)
    let ground = camera.project(calibration, raw, covariance)
    let moved_ground = reframed.project(
      moved_calibration,
      moved_raw,
      transform.covariance(covariance),
    )
    close(moved_ground.position().x, ground.position().x)
    close(moved_ground.position().y, ground.position().y)
    close(
      moved_ground.covariance().xx,
      ground.covariance().xx,
      tolerance=1.0e-12,
    )
    close(
      moved_ground.covariance().xy,
      ground.covariance().xy,
      tolerance=1.0e-12,
    )
    close(
      moved_ground.covariance().yy,
      ground.covariance().yy,
      tolerance=1.0e-12,
    )
  }
}

///|
test "camera reframing preserves the closed normalized lens domain" {
  let camera = @camera.CameraModel::new(fx=1.0, fy=2.0, cx=0.0, cy=0.0, k1=-0.1)
  let transform = @types.PixelTransform::new(
    scale_x=3.0,
    scale_y=0.25,
    offset_x=40.0,
    offset_y=-8.0,
  )
  let reframed = camera.reframed(transform)
  let boundary = reframed.rectify(transform.point({ x: 0.9, y: 0.0, }))
  close(boundary.x, 43.0, tolerance=1.0e-10)
  close(boundary.y, -8.0)
  invalid(() => ignore(reframed.rectify(transform.point({ x: 0.95, y: 0.0, }))))
  invalid(() => ignore(reframed.rectify(transform.point({ x: 1.31, y: 0.0, }))))
}

///|
test "camera reframing rejects focal length overflow without altering the original" {
  let camera = model()
  let before = camera.parameters()
  invalid(() => {
    ignore(camera.reframed(@types.PixelTransform::new(scale_x=1.0e308)))
  })
  assert_eq(camera.parameters(), before)
  let recovered = camera
    .reframed(@types.PixelTransform::new(scale_x=0.5, scale_y=2.0))
    .reframed(@types.PixelTransform::new(scale_x=2.0, scale_y=0.5))
  assert_eq(recovered.parameters(), before)
}
