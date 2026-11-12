///|
test "reframing retains exact subnormal ground floor variance without sqrt roundtrip" {
  let calibration = GroundCalibration::from_homography(
    [0.1, 0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 100.0, y: 0.0, },
      { x: 100.0, y: 100.0, },
      { x: 0.0, y: 100.0, },
    ],
    ground_noise_floor_m=2.0e-162,
  )
  let transformed = calibration.reframed(
    @types.PixelTransform::new(
      scale_x=2.0,
      scale_y=0.5,
      offset_x=-10.0,
      offset_y=20.0,
    ),
  )
  assert_true(calibration.noise_floor_variance > 0.0)
  assert_eq(transformed.noise_floor_variance, calibration.noise_floor_variance)
  assert_eq(transformed.maximum_scale, 1.0)
}
