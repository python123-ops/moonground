///|
test "packaged evaluator scores accepted positions and ready speeds separately" {
  let producer = @motion.MotionEstimator::new(
    "consumer-evaluation",
    @moonground.MotionConfig::new(),
  )
  let evaluator = @evaluation.EvaluationSession::new("consumer-evaluation")
  let observation = @moonground.GroundObservation::new(
    1,
    { x: 0.0, y: 0.0, },
    @moonground.Covariance2::isotropic(0.1),
  )
  let reference = @evaluation.ReferenceSample::new(
    1,
    { x: 0.0, y: 0.0, },
    speed_mps=0.0,
  )
  for time in [0L, 200000L, 400000L] {
    ignore(
      evaluator.update(producer.update(time, [observation]), time, [reference]),
    )
  }
  assert_eq(evaluator.report().position_error_m.samples, 3)
  assert_eq(evaluator.report().speed_error_mps.samples, 1)
  assert_eq(evaluator.report().speed_coverage, Some(1.0 / 3.0))
  let branch = evaluator.fork()
  ignore(
    branch.update(producer.update(600000L, [], removed=[1]), 600000L, [
      reference,
    ]),
  )
  assert_eq(branch.report().counts.missing, 1)
  assert_eq(evaluator.report().counts.missing, 0)
}

///|
test "packaged evaluator retains projection failure IDs from the measurement API" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 100.0, y: 0.0, },
      { x: 100.0, y: 100.0, },
      { x: 0.0, y: 100.0, },
    ],
    max_meters_per_pixel=2.0,
  )
  let producer = @moonground.MeasurementSession::new(
    "projection-evaluation",
    calibration,
    @moonground.MotionConfig::new(),
  )
  let frame = producer.update(0L, [
    @moonground.PixelObservation::new(
      2,
      { x: 200.0, y: 200.0, },
      @moonground.Covariance2::isotropic(0.1),
    ),
  ])
  let evaluator = @evaluation.EvaluationSession::new("projection-evaluation")
  let report = evaluator.update(
    frame.motion,
    0L,
    [@evaluation.ReferenceSample::new(2, { x: 0.0, y: 0.0, }, speed_mps=0.0)],
    projection_failures=frame.projection_failures.map(failure => {
      failure.track_id
    }),
  )
  assert_eq(report.counts.rejected_projection, 1)
  assert_eq(report.counts.missing, 0)
  assert_eq(report.position_error_m.mean_absolute_error, None)
  assert_eq(report.position_coverage, Some(0.0))
}
