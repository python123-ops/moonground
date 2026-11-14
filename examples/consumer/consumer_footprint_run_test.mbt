///|
fn consumer_run_frame(time : Int64, x~ : Double = 0.5) -> @motion.FrameResult raise @moonground.GroundError {
  let estimator = @motion.MotionEstimator::new("consumer-runs", @moonground.MotionConfig::new(min_observations=2, min_span_us=0L))
  let observation = @moonground.GroundObservation::new(1, { x, y: 0.5 }, @moonground.Covariance2::isotropic(0.1))
  ignore(estimator.update(0L, [observation]))
  let frame = estimator.update(1L, [observation])
  { ..frame, timestamp_us: time, tracks: [{ ..frame.tracks[0], last_accepted_timestamp_us: time }] }
}

///|
fn consumer_run_monitor() -> @zones.FootprintRunMonitor raise @moonground.GroundError {
  @zones.FootprintRunMonitor::new("consumer-runs", [consumer_disk_square(multiplier=0.0)], @zones.FootprintRunConfig::new(max_gap_us=10L, min_samples=2L, confirmation_us=2L))
}

///|
test "packaged footprint runs confirm count and sample span once without continuous presence claims" {
  let monitor = consumer_run_monitor()
  let shape : @zones.FootprintShape = @zones.Disk(@zones.DiskFootprint::new(0.125))
  for time in [0L, 1L, 2L, 3L] {
    let frame = consumer_run_frame(time)
    let output = monitor.update(frame, consumer_assigned_bundle(frame, shape))
    assert_eq(output.active[0].sample_count, time + 1L)
    assert_eq(output.active[0].sample_span_us, time)
    assert_eq(output.confirmed.length(), if time == 2L { 1 } else { 0 })
    let original = @zones.ZoneProjector::new("consumer-runs", [consumer_disk_square(multiplier=0.0)]).evaluate_assigned(frame, consumer_assigned_bundle(frame, shape))
    assert_eq(@debug.to_string(output.evidence), @debug.to_string(original))
  }
  let outside = consumer_run_frame(4L, x=2.0)
  let output = monitor.update(outside, consumer_assigned_bundle(outside, shape))
  assert_eq(output.closed[0].reason, @zones.DecisionChanged)
  assert_eq(output.closed[0].run.sample_span_us, 3L)
  assert_eq(output.active[0].decision, @zones.Outside)
  assert_eq(output.active[0].sample_count, 1L)
}

///|
test "packaged run checkpoints fork arrays and exact timestamp retry remain independent" {
  let monitor = consumer_run_monitor()
  let shape : @zones.FootprintShape = @zones.Disk(@zones.DiskFootprint::new(0.125))
  for time in [0L, 1L, 2L] { let frame = consumer_run_frame(time); ignore(monitor.update(frame, consumer_assigned_bundle(frame, shape))) }
  let saved = monitor.checkpoint()
  let restored = @zones.FootprintRunMonitor::from_checkpoint(saved)
  let branch = monitor.fork()
  saved.states.clear()
  assert_eq(monitor.checkpoint().states.length(), 1)
  let frame = consumer_run_frame(3L)
  let ended = branch.update(frame, @zones.FootprintAssignments::new(3L, []))
  assert_eq(ended.closed[0].reason, @zones.UnavailableEvidence)
  assert_eq(ended.evidence.unavailable[0].reason, @zones.MissingFootprint)
  assert_eq(monitor.checkpoint().last_timestamp_us, Some(2L))
  assert_eq(restored.checkpoint().states[0].run.sample_count, 3L)
  let tiny : @zones.FootprintShape = @zones.Disk(@zones.DiskFootprint::new(1.0e-30))
  try monitor.update(frame, consumer_assigned_bundle(frame, tiny)) catch { _ => () } noraise { _ => fail("unrepresentable endpoint expansion accepted") }
  assert_eq(monitor.checkpoint().last_timestamp_us, Some(2L))
  let retry = monitor.update(frame, consumer_assigned_bundle(frame, shape))
  assert_eq(retry.active[0].sample_count, 4L)
  assert_eq(retry.confirmed.length(), 0)
  let resumed = restored.update(frame, consumer_assigned_bundle(frame, shape))
  assert_eq(@debug.to_string(retry), @debug.to_string(resumed))
}

///|
test "packaged Brown run and upstream checkpoints continue after warm pixel reframe" {
  let (guarded, _, _, left, middle, right) = consumer_brown_guarded()
  guard guarded.checkpoint().analysis.measurement is Pixel(pixel) else { fail("pixel fixture missing") }
  let session = @moonground.MeasurementSession::from_checkpoint(pixel)
  let monitor = @zones.FootprintRunMonitor::new("guarded-transit", [@zones.ConvexZone::new("metric", [{ x: -100.0, y: -100.0 }, { x: 100.0, y: -100.0 }, { x: 100.0, y: 100.0 }, { x: -100.0, y: 100.0 }])], @zones.FootprintRunConfig::new(min_samples=2L, confirmation_us=100000L))
  let shape : @zones.FootprintShape = @zones.Convex(consumer_convex_footprint())
  let first = session.update(0L, [left]).motion
  ignore(monitor.update(first, consumer_assigned_bundle(first, shape)))
  let second = session.update(150000L, [middle]).motion
  ignore(monitor.update(second, consumer_assigned_bundle(second, shape)))
  let third = session.update(300000L, [right]).motion
  ignore(monitor.update(third, consumer_assigned_bundle(third, shape)))
  let resumed_runs = @zones.FootprintRunMonitor::from_checkpoint(monitor.checkpoint())
  let transform = @moonground.PixelTransform::new(scale_x=0.5, scale_y=1.25, offset_x=-15.0, offset_y=8.0)
  let adapted = session.reframed(transform)
  let expected_frame = session.update(400000L, [right]).motion
  let actual_frame = adapted.update(400000L, [right.reframed(transform)]).motion
  let expected = monitor.update(expected_frame, consumer_assigned_bundle(expected_frame, shape))
  let actual = resumed_runs.update(actual_frame, consumer_assigned_bundle(actual_frame, shape))
  assert_eq(@debug.to_string(actual.active), @debug.to_string(expected.active))
  assert_eq(@debug.to_string(actual.confirmed), @debug.to_string(expected.confirmed))
  assert_eq(@debug.to_string(actual.closed), @debug.to_string(expected.closed))
  assert_true(actual.active.length() > 0)
}
