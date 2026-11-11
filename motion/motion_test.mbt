///|
fn sample(
  id : Int32,
  x : Double,
  y : Double,
  std~ : Double = 0.1,
) -> @types.GroundObservation raise @types.GroundError {
  @types.GroundObservation::new(
    id,
    @types.Point2::new(x, y),
    @types.Covariance2::isotropic(std),
  )
}

///|
test "warmup requires both accepted count and elapsed span" {
  let engine = @motion.MotionEstimator::new("test", @motion.MotionConfig::new())
  let first = engine.update(0L, [sample(1, 0.0, 0.0)]).tracks[0]
  assert_eq(first.status, @motion.Initializing)
  assert_eq(first.speed_mps, None)
  ignore(engine.update(100000L, [sample(1, 0.1, 0.0)]))
  let third = engine.update(200000L, [sample(1, 0.2, 0.0)]).tracks[0]
  assert_eq(third.status, @motion.Initializing)
  let fourth = engine.update(300000L, [sample(1, 0.3, 0.0)]).tracks[0]
  assert_eq(fourth.status, @motion.Ready)
  guard fourth.velocity is Some(velocity) else {
    fail("missing ready velocity")
  }
  assert_true((velocity.x - 1.0).abs() < 0.1)
  assert_true(velocity.y.abs() < 0.0000001)
  assert_eq(fourth.accepted_count, 4)
  assert_true((fourth.observed_path_length_m - 0.3).abs() < 0.01)
  assert_true(
    (fourth.net_displacement_m - fourth.observed_path_length_m).abs() <
    0.0000001,
  )
}

///|
test "empty frames never invent zero speed or prediction output" {
  let engine = @motion.MotionEstimator::new(
    "missing",
    @motion.MotionConfig::new(),
  )
  ignore(engine.update(0L, [sample(2, 0.0, 0.0)]))
  let missing = engine.update(200000L, [])
  assert_eq(missing.tracks.length(), 0)
  assert_eq(engine.active_track_count(), 1)
  let expired = engine.update(500000L, [])
  assert_eq(expired.closed_segment_ids, ["1"])
  assert_eq(engine.active_track_count(), 0)
  let next = engine.update(600000L, [sample(2, 1.0, 0.0)]).tracks[0]
  assert_eq(next.segment_id, "2")
  assert_eq(next.accepted_count, 1)
  assert_eq(next.speed_mps, None)
}

///|
test "exact gap boundary closes before a returning observation" {
  let engine = @motion.MotionEstimator::new("gap", @motion.MotionConfig::new())
  ignore(engine.update(0L, [sample(1, 0.0, 0.0)]))
  let result = engine.update(500000L, [sample(1, 1.0, 0.0)])
  assert_eq(result.closed_segment_ids, ["1"])
  assert_eq(result.tracks[0].segment_id, "2")
  assert_eq(result.tracks[0].accepted_count, 1)
}

///|
test "lost and removed close identities and release bounded capacity" {
  let engine = @motion.MotionEstimator::new(
    "lifecycle",
    @motion.MotionConfig::new(max_tracks=2),
  )
  ignore(engine.update(0L, [sample(2, 0.0, 0.0), sample(1, 1.0, 0.0)]))
  let close = engine.update(100000L, [], lost=[1], removed=[2])
  assert_eq(close.closed_segment_ids, ["1", "2"])
  assert_eq(engine.active_track_count(), 0)
  let reused = engine.update(200000L, [sample(1, 2.0, 0.0)])
  assert_eq(reused.tracks[0].segment_id, "3")
  assert_eq(reused.tracks[0].accepted_count, 1)
}

///|
test "frame conflicts and timestamps reject atomically" {
  let engine = @motion.MotionEstimator::new(
    "atomic",
    @motion.MotionConfig::new(),
  )
  ignore(engine.update(100L, [sample(1, 0.0, 0.0)]))
  try engine.update(200L, [sample(2, 0.0, 0.0), sample(2, 1.0, 0.0)]) catch {
    _ => ()
  } noraise {
    _ => fail("duplicate observations accepted")
  }
  try engine.update(200L, [sample(2, 0.0, 0.0)], lost=[2]) catch {
    _ => ()
  } noraise {
    _ => fail("observation and lost conflict accepted")
  }
  try engine.update(200L, [], lost=[2], removed=[2]) catch {
    _ => ()
  } noraise {
    _ => fail("lost and removed conflict accepted")
  }
  try engine.update(100L, []) catch {
    _ => ()
  } noraise {
    _ => fail("duplicate frame time accepted")
  }
  try engine.update(-1L, []) catch {
    _ => ()
  } noraise {
    _ => fail("negative frame time accepted")
  }
  assert_eq(engine.last_timestamp_us(), Some(100L))
  assert_eq(engine.active_track_count(), 1)
  let valid = engine.update(200L, [sample(2, 0.0, 0.0)])
  assert_eq(valid.tracks[0].segment_id, "2")
}

///|
test "capacity error rolls back earlier candidate changes and segment allocation" {
  let engine = @motion.MotionEstimator::new(
    "capacity",
    @motion.MotionConfig::new(max_tracks=2),
  )
  ignore(engine.update(0L, [sample(1, 0.0, 0.0)]))
  try engine.update(100000L, [sample(2, 1.0, 0.0), sample(3, 2.0, 0.0)]) catch {
    _ => ()
  } noraise {
    _ => fail("active capacity overflow accepted")
  }
  assert_eq(engine.last_timestamp_us(), Some(0L))
  assert_eq(engine.active_track_count(), 1)
  let valid = engine.update(100000L, [sample(2, 1.0, 0.0)])
  assert_eq(valid.tracks[0].segment_id, "2")
}

///|
test "innovation rejection preserves accepted timestamps and hides stale outputs" {
  let engine = @motion.MotionEstimator::new(
    "outlier",
    @motion.MotionConfig::new(),
  )
  ignore(engine.update(0L, [sample(1, 0.0, 0.0)]))
  let rejected = engine.update(100000L, [sample(1, 10000.0, 0.0)]).tracks[0]
  assert_eq(rejected.status, @motion.RejectedInnovation)
  assert_true(rejected.position is None)
  assert_true(rejected.velocity is None)
  assert_eq(rejected.filtered_state, None)
  assert_eq(rejected.last_accepted_timestamp_us, 0L)
  assert_eq(rejected.accepted_count, 1)
  let expired = engine.update(500000L, [])
  assert_eq(expired.closed_segment_ids, ["1"])
}

///|
test "unusable numerical update rejects only that target" {
  let engine = @motion.MotionEstimator::new(
    "numerical",
    @motion.MotionConfig::new(initial_velocity_std=0.001),
  )
  ignore(
    engine.update(0L, [sample(1, 0.0, 0.0, std=1.0e-8), sample(2, 0.0, 0.0)]),
  )
  // Tiny dt makes the first innovation below the dependency's absolute pivot
  // tolerance; an independent normal-covariance target still succeeds.
  let result = engine.update(1L, [
    sample(1, 0.0, 0.0, std=1.0e-8),
    sample(2, 0.0, 0.0),
  ])
  assert_eq(result.tracks[0].status, @motion.NumericalFailure)
  assert_eq(result.tracks[0].position_std_m, None)
  assert_eq(result.tracks[0].velocity_std_mps, None)
  assert_eq(result.tracks[0].accepted_count, 1)
  assert_eq(result.tracks[1].accepted_count, 2)
}

///|
test "diagnostic arrays are copies and never alias live filter state" {
  let engine = @motion.MotionEstimator::new(
    "copies",
    @motion.MotionConfig::new(),
  )
  let result = engine.update(0L, [sample(1, 1.0, 2.0)]).tracks[0]
  guard result.filtered_state is Some(state) else {
    fail("missing diagnostic state")
  }
  guard result.filtered_covariance is Some(covariance) else {
    fail("missing covariance")
  }
  assert_eq(state.length(), 4)
  assert_eq(covariance.length(), 16)
  state[0] = 1.0e20
  covariance[0] = 1.0e20
  let next = engine.update(100000L, [sample(1, 1.0, 2.0)]).tracks[0]
  guard next.position is Some(position) else {
    fail("filter state was corrupted")
  }
  assert_true((position.x - 1.0).abs() < 0.0000001)
  assert_true((position.y - 2.0).abs() < 0.0000001)
}

///|
test "Int64 microsecond epochs preserve small deltas" {
  let engine = @motion.MotionEstimator::new(
    "epoch",
    @motion.MotionConfig::new(),
  )
  let epoch = 9007199254740993L
  ignore(engine.update(epoch, [sample(1, 0.0, 0.0)]))
  let result = engine.update(epoch + 300000L, [sample(1, 0.3, 0.0)]).tracks[0]
  assert_eq(result.accepted_count, 2)
  assert_eq(result.last_accepted_timestamp_us, epoch + 300000L)
}

///|
test "track ordering and segment assignment are deterministic" {
  let engine = @motion.MotionEstimator::new(
    "sorted",
    @motion.MotionConfig::new(),
  )
  let results = engine.update(0L, [sample(7, 0.0, 0.0), sample(2, 0.0, 0.0)]).tracks
  assert_eq(results[0].track_id, 2)
  assert_eq(results[0].segment_id, "1")
  assert_eq(results[1].track_id, 7)
  assert_eq(results[1].segment_id, "2")
}

///|
test "motion configuration rejects nonfinite and invalid limits" {
  try @motion.MotionConfig::new(q=0.0 / 0.0) catch {
    _ => ()
  } noraise {
    _ => fail("NaN q accepted")
  }
  try @motion.MotionConfig::new(max_gap_us=0L) catch {
    _ => ()
  } noraise {
    _ => fail("zero gap accepted")
  }
  try @motion.MotionConfig::new(initial_velocity_std=1.0e200) catch {
    _ => ()
  } noraise {
    _ => fail("overflowed initial velocity variance accepted")
  }
  try @motion.MotionConfig::new(initial_velocity_std=1.0e-200) catch {
    _ => ()
  } noraise {
    _ => fail("underflowed initial velocity variance accepted")
  }
  try @motion.MotionConfig::new(gate=1.0 / 0.0) catch {
    _ => ()
  } noraise {
    _ => fail("infinite gate accepted")
  }
}

///|
test "identity churn remains bounded without retaining lost tombstones" {
  let engine = @motion.MotionEstimator::new(
    "bounded",
    @motion.MotionConfig::new(max_tracks=1),
  )
  for i in 0..<256 {
    let timestamp = Int64::from_int(i) * 2000L
    let entered = engine.update(timestamp, [sample(i + 1, 0.0, 0.0)])
    assert_eq(entered.tracks[0].segment_id, (i + 1).to_string())
    assert_eq(engine.active_track_count(), 1)
    let closed = engine.update(timestamp + 1000L, [], lost=[i + 1])
    assert_eq(closed.closed_segment_ids, [(i + 1).to_string()])
    assert_eq(engine.active_track_count(), 0)
  }
}

///|
test "path and displacement use accepted filtered positions and skip rejections" {
  let engine = @motion.MotionEstimator::new(
    "filtered-path",
    @motion.MotionConfig::new(),
  )
  let points = [
    (0.0, 0.0),
    (0.15, 0.2),
    (0.23, -0.1),
    (10000.0, 10000.0),
    (0.4, 0.25),
    (0.45, 0.0),
  ]
  let mut last_filtered : @types.Point2? = None
  let mut last_raw : @types.Point2? = None
  let mut filtered_path = 0.0
  let mut raw_path = 0.0
  for i, (x, y) in points {
    let estimate = engine.update(Int64::from_int(i) * 100000L, [sample(1, x, y)]).tracks[0]
    if i == 3 {
      assert_eq(estimate.status, @motion.RejectedInnovation)
      assert_true(estimate.position is None)
      assert_true(
        (estimate.observed_path_length_m - filtered_path).abs() < 1.0e-12,
      )
      assert_eq(estimate.accepted_count, 3)
      continue
    }
    guard estimate.position is Some(position) else {
      fail("expected accepted filtered position")
    }
    if last_filtered is Some(previous) {
      let dx = position.x - previous.x
      let dy = position.y - previous.y
      filtered_path = filtered_path + (dx * dx + dy * dy).sqrt()
    }
    if last_raw is Some(previous) {
      let dx = x - previous.x
      let dy = y - previous.y
      raw_path = raw_path + (dx * dx + dy * dy).sqrt()
    }
    assert_true(
      (estimate.observed_path_length_m - filtered_path).abs() < 1.0e-12,
    )
    let net = (position.x * position.x + position.y * position.y).sqrt()
    assert_true((estimate.net_displacement_m - net).abs() < 1.0e-12)
    last_filtered = Some(position)
    last_raw = Some({ x, y, })
  }
  assert_true((filtered_path - raw_path).abs() > 0.001)
}
