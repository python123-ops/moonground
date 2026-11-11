///|
test "enabled uncertainty limits fail closed when a covariance block is unavailable" {
  let point : @types.Point2 = { x: 0.0, y: 0.0, }
  let track : TrackState = {
    track_id: 1,
    segment_id: 1L,
    first_timestamp_us: 0L,
    last_timestamp_us: 400000L,
    accepted_count: 3,
    state: [0.0, 0.0, 0.0, 0.0],
    covariance: @kalman.Matrix::from_rows([
      [1.0, 0.0, 0.0, 0.0],
      [0.0, 0.0, 0.0, 0.0],
      [0.0, 0.0, 1.0, 0.0],
      [0.0, 0.0, 0.0, 0.0],
    ]),
    first_filtered: point,
    last_filtered: point,
    observed_path_length_m: 0.0,
  }
  assert_true(healthy_state(track.state, track.covariance))
  assert_eq(covariance_std(track.covariance, 0), None)
  assert_eq(covariance_std(track.covariance, 2), None)
  assert_eq(
    readiness(track, MotionConfig::new(max_position_std_m=10.0)),
    Uncertain,
  )
  assert_eq(
    readiness(track, MotionConfig::new(max_velocity_std_mps=10.0)),
    Uncertain,
  )
}
