///|
test "typed measurement checkpoint preserves fitted calibration camera and exact continuation" {
  let controls : Array[@moonground.Point2] = [
    { x: -8.0, y: -8.0, },
    { x: 8.0, y: -8.0, },
    { x: 8.0, y: 8.0, },
    { x: -8.0, y: 8.0, },
    { x: 0.0, y: -4.0, },
    { x: 3.0, y: 2.0, },
  ]
  let checks : Array[@moonground.Point2] = [
    { x: -3.0, y: 3.0, },
    { x: 4.0, y: -3.0, },
  ]
  let world = controls.map(p => @moonground.Point2::{
    x: p.x * 0.1,
    y: p.y * 0.1,
  })
  let check_world = checks.map(p => @moonground.Point2::{
    x: p.x * 0.1,
    y: p.y * 0.1,
  })
  let calibration = @moonground.GroundCalibration::fit(
    controls,
    world,
    checks,
    check_world,
    [
      { x: -10.0, y: -10.0, },
      { x: 10.0, y: -10.0, },
      { x: 10.0, y: 10.0, },
      { x: -10.0, y: 10.0, },
    ],
    ground_noise_floor_m=0.17,
  )
  let camera = @moonground.CameraModel::new(
    fx=20.0,
    fy=30.0,
    cx=0.0,
    cy=0.0,
    k1=0.05,
    p1=0.001,
  )
  let session = @moonground.MeasurementSession::new(
    "checkpoint-fit",
    calibration,
    @moonground.MotionConfig::new(
      min_observations=2,
      min_span_us=0L,
      q=0.3,
      gate=100.0,
      max_velocity_std_mps=0.000001,
    ),
    camera~,
  )
  ignore(session.update(0L, [pixel(1, 0.0, 0.0)]))
  ignore(session.update(150000L, [pixel(1, 0.2, 0.1)]))
  let checkpoint = session.checkpoint()
  assert_eq(checkpoint.calibration.report().fit_count(), 6)
  assert_eq(checkpoint.calibration.report().check_count(), 2)
  assert_eq(
    checkpoint.calibration.report().fit_rms_m(),
    calibration.report().fit_rms_m(),
  )
  assert_eq(
    checkpoint.calibration.report().check_max_error_m(),
    calibration.report().check_max_error_m(),
  )
  guard checkpoint.camera is Some(saved_camera) else { fail("camera was lost") }
  assert_eq(saved_camera.parameters(), camera.parameters())
  let restored = @moonground.MeasurementSession::from_checkpoint(checkpoint)
  // Neither side aliases the exported mutable filter arrays.
  checkpoint.motion.tracks[0].state[0] = 999.0
  checkpoint.motion.tracks[0].covariance[0] = 999.0
  let expected = session.update(300000L, [pixel(1, 0.4, 0.2)]).motion.tracks[0]
  let actual = restored.update(300000L, [pixel(1, 0.4, 0.2)]).motion.tracks[0]
  assert_eq(actual.status, expected.status)
  assert_eq(actual.filtered_state, expected.filtered_state)
  assert_eq(actual.filtered_covariance, expected.filtered_covariance)
  assert_eq(actual.observed_path_length_m, expected.observed_path_length_m)
  assert_eq(actual.net_displacement_m, expected.net_displacement_m)
  assert_eq(actual.speed_mps, expected.speed_mps)
}

///|
test "typed checkpoint preserves empty global history and absent camera" {
  let session = make_test_session()
  ignore(session.update(0L, [pixel(1, 0.0, 0.0)]))
  ignore(session.update(100000L, [], removed=[1]))
  ignore(session.update(200000L, [pixel(2, 100.0, 0.0)]))
  let checkpoint = session.checkpoint()
  assert_true(checkpoint.camera is None)
  assert_eq(checkpoint.motion.last_timestamp_us, Some(200000L))
  assert_eq(checkpoint.motion.next_segment_id, 2L)
  let restored = @moonground.MeasurementSession::from_checkpoint(checkpoint)
  try restored.update(200000L, []) catch {
    _ => ()
  } noraise {
    _ => fail("restored empty session forgot frame clock")
  }
  let result = restored.update(300000L, [pixel(1, 0.0, 0.0)])
  assert_eq(result.motion.tracks[0].segment_id, "2")
}

///|
test "invalid typed checkpoint cannot alter original measurement session" {
  let session = make_test_session()
  ignore(session.update(0L, [pixel(1, 0.0, 0.0)]))
  let checkpoint = session.checkpoint()
  let invalid : @moonground.MeasurementCheckpoint = {
    ..checkpoint,
    motion: { ..checkpoint.motion, next_segment_id: 1L, },
  }
  try @moonground.MeasurementSession::from_checkpoint(invalid) catch {
    _ => ()
  } noraise {
    _ => fail("invalid checkpoint accepted")
  }
  let result = session.update(100000L, [pixel(1, 0.1, 0.0)])
  assert_eq(result.motion.tracks[0].accepted_count, 2)
  assert_eq(result.motion.tracks[0].segment_id, "1")
}
