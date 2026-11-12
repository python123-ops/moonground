///|
test "projection identity includes noise policy scale limit and ordered ROI" {
  let matrix = [0.1, 0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, 1.0]
  let original = @calibration.GroundCalibration::from_homography(
    matrix,
    rectangle(),
  )
  assert_true(
    original.same_projection(
      @calibration.GroundCalibration::from_homography(
        matrix.map(value => value * 2.0),
        rectangle(),
      ),
    ),
  )
  assert_false(
    original.same_projection(
      @calibration.GroundCalibration::from_homography(
        matrix.map(value => -value),
        rectangle(),
      ),
    ),
  )
  let changed = matrix.copy()
  changed[2] = 0.01
  assert_false(
    original.same_projection(
      @calibration.GroundCalibration::from_homography(changed, rectangle()),
    ),
  )
  assert_false(
    original.same_projection(
      @calibration.GroundCalibration::from_homography(
        matrix,
        rectangle(),
        max_meters_per_pixel=1.0,
      ),
    ),
  )
  assert_false(
    original.same_projection(
      @calibration.GroundCalibration::from_homography(
        matrix,
        rectangle(),
        ground_noise_floor_m=0.002,
      ),
    ),
  )
  let roi = rectangle()
  let rotated = [roi[1], roi[2], roi[3], roi[0]]
  assert_false(
    original.same_projection(
      @calibration.GroundCalibration::from_homography(matrix, rotated),
    ),
  )
  let tiny = @calibration.GroundCalibration::from_homography(
    matrix,
    rectangle(),
    ground_noise_floor_m=1.0e-160,
  )
  assert_true(tiny.same_projection(tiny.reframed(@types.PixelTransform::new())))
  assert_false(
    tiny.same_projection(
      @calibration.GroundCalibration::from_homography(
        matrix,
        rectangle(),
        ground_noise_floor_m=1.001e-160,
      ),
    ),
  )
}

///|
test "projection identity ignores the source of fit and check diagnostics" {
  let controls = control_pixels()
  let checks = check_pixels()
  let fitted = @calibration.GroundCalibration::fit(
    controls,
    exact_world(controls),
    checks,
    exact_world(checks),
    rectangle(),
  )
  let imported = @calibration.GroundCalibration::from_homography(
    fitted.matrix(),
    fitted.roi(),
  )
  assert_true(fitted.report().fit_count() > imported.report().fit_count())
  assert_true(fitted.same_projection(imported))
  assert_true(imported.same_projection(fitted))
}
