///|
fn stationary_result(
  config : @motion.MotionConfig,
) -> @motion.TrackEstimate raise @types.GroundError {
  let engine = @motion.MotionEstimator::new("stationary-uncertainty", config)
  ignore(engine.update(0L, [sample(1, 0.0, 0.0)]))
  ignore(engine.update(200000L, [sample(1, 0.0, 0.0)]))
  engine.update(400000L, [sample(1, 0.0, 0.0)]).tracks[0]
}

///|
test "uncertainty defaults are disabled and initialization keeps velocity unavailable" {
  let config = @motion.MotionConfig::new()
  assert_eq(config.max_position_std_m(), None)
  assert_eq(config.max_velocity_std_mps(), None)
  let engine = @motion.MotionEstimator::new(
    "initializing-priority",
    @motion.MotionConfig::new(
      max_position_std_m=1.0e-8,
      max_velocity_std_mps=1.0e-8,
    ),
  )
  let first = engine.update(0L, [sample(1, 0.0, 0.0)]).tracks[0]
  assert_eq(first.status, @motion.Initializing)
  assert_true(first.position_std_m is Some(_))
  assert_eq(first.velocity_std_mps, None)
  assert_true(first.velocity is None)
  assert_eq(first.speed_mps, None)
  let default_result = stationary_result(config)
  let loose = stationary_result(
    @motion.MotionConfig::new(
      max_position_std_m=1.0e308,
      max_velocity_std_mps=1.0e308,
    ),
  )
  assert_eq(default_result.status, @motion.Ready)
  assert_eq(loose.status, @motion.Ready)
  assert_eq(default_result.filtered_state, loose.filtered_state)
  assert_eq(default_result.filtered_covariance, loose.filtered_covariance)
  assert_eq(default_result.speed_mps, loose.speed_mps)
  assert_eq(default_result.observed_path_length_m, loose.observed_path_length_m)
}

///|
test "position uncertainty independently masks speed without rejecting observations" {
  let result = stationary_result(
    @motion.MotionConfig::new(max_position_std_m=0.001),
  )
  assert_eq(result.status, @motion.Uncertain)
  assert_eq(result.accepted_count, 3)
  assert_eq(result.last_accepted_timestamp_us, 400000L)
  assert_true(result.position is Some(_))
  assert_true(result.position_covariance is Some(_))
  assert_true(result.velocity is Some(_))
  assert_true(result.velocity_covariance is Some(_))
  assert_true(result.filtered_state is Some(_))
  assert_true(result.filtered_covariance is Some(_))
  assert_eq(result.speed_mps, None)
  guard result.position_std_m is Some(deviation) else {
    fail("missing position uncertainty")
  }
  assert_true(deviation > 0.001)
}

///|
test "velocity uncertainty is independent and stays positive at zero speed" {
  let baseline = stationary_result(@motion.MotionConfig::new())
  assert_eq(baseline.speed_mps, Some(0.0))
  guard baseline.velocity_std_mps is Some(deviation) else {
    fail("missing velocity uncertainty")
  }
  assert_true(deviation > 0.0)
  let result = stationary_result(
    @motion.MotionConfig::new(max_velocity_std_mps=deviation / 2.0),
  )
  assert_eq(result.status, @motion.Uncertain)
  assert_eq(result.speed_mps, None)
  assert_eq(result.velocity_std_mps, Some(deviation))
  assert_eq(result.filtered_state, baseline.filtered_state)
  assert_eq(result.filtered_covariance, baseline.filtered_covariance)
  assert_eq(result.position_std_m, baseline.position_std_m)
}

///|
test "uncertainty limits accept equality and reject only strictly greater values" {
  let baseline = stationary_result(@motion.MotionConfig::new())
  guard baseline.position_std_m is Some(position) else {
    fail("missing position sigma")
  }
  guard baseline.velocity_std_mps is Some(velocity) else {
    fail("missing velocity sigma")
  }
  let equal = stationary_result(
    @motion.MotionConfig::new(
      max_position_std_m=position,
      max_velocity_std_mps=velocity,
    ),
  )
  assert_eq(equal.status, @motion.Ready)
  let lower_position = stationary_result(
    @motion.MotionConfig::new(max_position_std_m=position * 0.999999),
  )
  let lower_velocity = stationary_result(
    @motion.MotionConfig::new(max_velocity_std_mps=velocity * 0.999999),
  )
  assert_eq(lower_position.status, @motion.Uncertain)
  assert_eq(lower_velocity.status, @motion.Uncertain)
}

///|
test "accepted uncertainty can recover within the same segment" {
  let engine = @motion.MotionEstimator::new(
    "uncertainty-recovery",
    @motion.MotionConfig::new(
      min_observations=2,
      min_span_us=0L,
      q=0.0,
      max_position_std_m=0.2,
      max_velocity_std_mps=0.7,
    ),
  )
  ignore(engine.update(0L, [sample(1, 0.0, 0.0, std=1.0)]))
  let uncertain = engine.update(200000L, [sample(1, 0.0, 0.0, std=1.0)]).tracks[0]
  assert_eq(uncertain.status, @motion.Uncertain)
  assert_eq(uncertain.accepted_count, 2)
  let mut recovered = uncertain
  for i in 2..<10 {
    recovered = engine.update(Int64::from_int(i) * 200000L, [
        sample(1, 0.0, 0.0, std=0.01),
      ]).tracks[0]
  }
  assert_eq(recovered.status, @motion.Ready)
  assert_eq(recovered.segment_id, uncertain.segment_id)
  assert_eq(recovered.accepted_count, 10)
  assert_eq(recovered.speed_mps, Some(0.0))
}

///|
test "innovation rejection exposes no stale uncertainty and retains accepted state" {
  let engine = @motion.MotionEstimator::new(
    "uncertain-outlier",
    @motion.MotionConfig::new(max_position_std_m=0.001),
  )
  ignore(engine.update(0L, [sample(1, 0.0, 0.0)]))
  ignore(engine.update(200000L, [sample(1, 0.0, 0.0)]))
  let accepted = engine.update(400000L, [sample(1, 0.0, 0.0)]).tracks[0]
  assert_eq(accepted.status, @motion.Uncertain)
  let rejected = engine.update(500000L, [sample(1, 10000.0, 0.0)]).tracks[0]
  assert_eq(rejected.status, @motion.RejectedInnovation)
  assert_eq(rejected.position_std_m, None)
  assert_eq(rejected.velocity_std_mps, None)
  assert_eq(rejected.accepted_count, 3)
  assert_eq(rejected.last_accepted_timestamp_us, 400000L)
  assert_eq(rejected.observed_path_length_m, accepted.observed_path_length_m)
}

///|
test "worst direction sigma is stable for overflowing eigenvalues and tiny scales" {
  for
    (variance, correlation, expected) in [
      (1.0e308, 9.0e307, 1.0e154 * 1.9.sqrt()),
      (1.0e-300, -9.0e-301, 1.0e-150 * 1.9.sqrt()),
    ] {
    let engine = @motion.MotionEstimator::new(
      "extreme-sigma",
      @motion.MotionConfig::new(),
    )
    let observation = @types.GroundObservation::new(
      1,
      @types.Point2::new(0.0, 0.0),
      @types.Covariance2::new(variance, correlation, variance),
    )
    let result = engine.update(0L, [observation]).tracks[0]
    guard result.position_std_m is Some(deviation) else {
      fail("missing finite scaled uncertainty")
    }
    assert_true(@types.is_finite(deviation))
    assert_true((deviation / expected - 1.0).abs() < 1.0e-14)
  }
  let engine = @motion.MotionEstimator::new(
    "subnormal-sigma",
    @motion.MotionConfig::new(),
  )
  let observation = @types.GroundObservation::new(
    1,
    @types.Point2::new(0.0, 0.0),
    @types.Covariance2::new(5.0e-324, 0.0, 5.0e-324),
  )
  let result = engine.update(0L, [observation]).tracks[0]
  guard result.position_std_m is Some(deviation) else {
    fail("missing subnormal uncertainty")
  }
  assert_true(@types.is_finite(deviation) && deviation > 0.0)
}

///|
test "uncertainty limits validate raw finite positive values without squaring" {
  let config = @motion.MotionConfig::new(
    max_position_std_m=1.0e308,
    max_velocity_std_mps=5.0e-324,
  )
  assert_eq(config.max_position_std_m(), Some(1.0e308))
  assert_eq(config.max_velocity_std_mps(), Some(5.0e-324))
  for invalid in [0.0, -1.0, 1.0 / 0.0, 0.0 / 0.0] {
    try @motion.MotionConfig::new(max_position_std_m=invalid) catch {
      _ => ()
    } noraise {
      _ => fail("invalid position limit accepted")
    }
    try @motion.MotionConfig::new(max_velocity_std_mps=invalid) catch {
      _ => ()
    } noraise {
      _ => fail("invalid velocity limit accepted")
    }
  }
}

///|
test "uncertainty masks do not change moving paths Kalman state or segment lifetime" {
  let baseline = @motion.MotionEstimator::new(
    "moving-default",
    @motion.MotionConfig::new(),
  )
  let limited = @motion.MotionEstimator::new(
    "moving-limited",
    @motion.MotionConfig::new(
      max_position_std_m=1.0e-8,
      max_velocity_std_mps=1.0e-8,
    ),
  )
  for i in 0..<5 {
    let timestamp = Int64::from_int(i) * 100000L
    let observations = [
      sample(1, i.to_double() * 0.1, (i % 2).to_double() * 0.01),
    ]
    let a = baseline.update(timestamp, observations).tracks[0]
    let b = limited.update(timestamp, observations).tracks[0]
    assert_eq(a.filtered_state, b.filtered_state)
    assert_eq(a.filtered_covariance, b.filtered_covariance)
    assert_eq(a.observed_path_length_m, b.observed_path_length_m)
    assert_eq(a.net_displacement_m, b.net_displacement_m)
    assert_eq(a.accepted_count, b.accepted_count)
    assert_eq(a.last_accepted_timestamp_us, b.last_accepted_timestamp_us)
    assert_eq(a.segment_id, b.segment_id)
    if i >= 3 {
      assert_eq(a.status, @motion.Ready)
      assert_eq(b.status, @motion.Uncertain)
      assert_eq(b.speed_mps, None)
      assert_true(b.velocity is Some(_))
    }
  }
  let a = baseline.update(900000L, [])
  let b = limited.update(900000L, [])
  assert_eq(a.closed_segment_ids, b.closed_segment_ids)
  assert_eq(b.closed_segment_ids, ["1"])
  assert_eq(limited.active_track_count(), 0)
}
