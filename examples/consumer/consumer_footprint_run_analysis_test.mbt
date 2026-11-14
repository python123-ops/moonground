///|
fn consumer_joint_run_owner() -> @analysis.FootprintRunSession raise @moonground.GroundError {
  @analysis.FootprintRunSession::from_ground(
    @motion.MotionEstimator::new(
      "consumer-joint-runs",
      @moonground.MotionConfig::new(min_observations=2, min_span_us=0L),
    ),
    @zones.FootprintRunMonitor::new(
      "consumer-joint-runs",
      [
        @zones.ConvexZone::new("metric", [
          { x: -10.0, y: -10.0, },
          { x: 10.0, y: -10.0, },
          { x: 10.0, y: 10.0, },
          { x: -10.0, y: 10.0, },
        ]),
      ],
      @zones.FootprintRunConfig::new(min_samples=1L, confirmation_us=0L),
    ),
  )
}

///|
fn consumer_joint_run_observation() -> Array[@moonground.GroundObservation] raise @moonground.GroundError {
  [
    @moonground.GroundObservation::new(
      1,
      { x: 0.5, y: 0.5, },
      @moonground.Covariance2::isotropic(0.1),
    ),
  ]
}

///|
test "packaged joint preparations own detached candidate identities and reject stale commits" {
  let owner = consumer_joint_run_owner()
  let prepared = owner.prepare_ground(0L, consumer_joint_run_observation())
  let inspected = prepared.measurement()
  assert_eq(inspected.motion.tracks[0].segment_id, "1")
  inspected.motion.tracks.clear()
  assert_eq(prepared.measurement().motion.tracks.length(), 1)
  let shape : @zones.FootprintShape = @zones.Disk(
    @zones.DiskFootprint::new(0.125),
  )
  let wrong = @zones.FootprintAssignments::new(0L, [
    @zones.FootprintAssignment::new(1, "9", shape),
  ])
  try prepared.commit(wrong) catch {
    _ => ()
  } noraise {
    _ => fail("wrong candidate segment accepted")
  }
  assert_eq(owner.checkpoint().runs.last_timestamp_us, None)
  let output = prepared.commit(
    consumer_assigned_bundle(prepared.measurement().motion, shape),
  )
  assert_eq(output.measurement.motion.tracks[0].segment_id, "1")
  try
    prepared.commit(consumer_assigned_bundle(output.measurement.motion, shape))
  catch {
    _ => ()
  } noraise {
    _ => fail("used candidate accepted")
  }
  let one = owner.prepare_ground(100000L, consumer_joint_run_observation())
  let stale = owner.prepare_ground(100000L, consumer_joint_run_observation())
  ignore(one.commit(consumer_assigned_bundle(one.measurement().motion, shape)))
  try
    stale.commit(consumer_assigned_bundle(stale.measurement().motion, shape))
  catch {
    _ => ()
  } noraise {
    _ => fail("stale candidate accepted")
  }
  assert_eq(owner.checkpoint().runs.last_timestamp_us, Some(100000L))
}

///|
test "packaged late footprint failure preserves both engines and supports same prepared retry" {
  let owner = consumer_joint_run_owner()
  let shape : @zones.FootprintShape = @zones.Disk(
    @zones.DiskFootprint::new(0.125),
  )
  let first = owner.prepare_ground(0L, consumer_joint_run_observation())
  ignore(
    first.commit(consumer_assigned_bundle(first.measurement().motion, shape)),
  )
  let prepared = owner.prepare_ground(100000L, consumer_joint_run_observation())
  let tiny : @zones.FootprintShape = @zones.Disk(
    @zones.DiskFootprint::new(1.0e-30),
  )
  let before = owner.checkpoint()
  try
    prepared.commit(
      consumer_assigned_bundle(prepared.measurement().motion, tiny),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("unrepresentable footprint expansion accepted")
  }
  assert_eq(
    owner.checkpoint().runs.last_timestamp_us,
    before.runs.last_timestamp_us,
  )
  assert_eq(owner.checkpoint().runs.states.length(), 0)
  guard owner.checkpoint().measurement is Ground(now) else {
    fail("ground owner missing")
  }
  guard before.measurement is Ground(old) else {
    fail("ground checkpoint missing")
  }
  assert_eq(@debug.to_string(now), @debug.to_string(old))
  let output = prepared.commit(
    consumer_assigned_bundle(prepared.measurement().motion, shape),
  )
  assert_eq(output.runs.active[0].sample_count, 1L)
  let branch = owner.fork()
  ignore(branch.interrupt(200000L))
  assert_eq(branch.checkpoint().runs.states.length(), 0)
  assert_eq(owner.checkpoint().runs.states.length(), 1)
  ignore(@analysis.FootprintRunSession::from_checkpoint(owner.checkpoint()))
}

///|
test "packaged Brown joint run checkpoint and warm reframe preserve metric sample histories" {
  let (guarded, _, _, left, middle, right) = consumer_brown_guarded()
  guard guarded.checkpoint().analysis.measurement is Pixel(pixel) else {
    fail("pixel fixture missing")
  }
  let owner = @analysis.FootprintRunSession::from_pixel(
    @moonground.MeasurementSession::from_checkpoint(pixel),
    @zones.FootprintRunMonitor::new(
      "guarded-transit",
      [
        @zones.ConvexZone::new("metric", [
          { x: -100.0, y: -100.0, },
          { x: 100.0, y: -100.0, },
          { x: 100.0, y: 100.0, },
          { x: -100.0, y: 100.0, },
        ]),
      ],
      @zones.FootprintRunConfig::new(min_samples=2L, confirmation_us=100000L),
    ),
  )
  let shape : @zones.FootprintShape = @zones.Convex(consumer_convex_footprint())
  for (time, observation) in [(0L, left), (150000L, middle), (300000L, right)] {
    let candidate = owner.prepare_pixel(time, [observation])
    ignore(
      candidate.commit(
        consumer_assigned_bundle(candidate.measurement().motion, shape),
      ),
    )
  }
  let resumed = @analysis.FootprintRunSession::from_checkpoint(
    owner.checkpoint(),
  )
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=1.25,
    offset_x=-15.0,
    offset_y=8.0,
  )
  let adapted = resumed.reframed(transform)
  let expected = owner.prepare_pixel(400000L, [right])
  let actual = adapted.prepare_pixel(400000L, [right.reframed(transform)])
  let wanted = expected.commit(
    consumer_assigned_bundle(expected.measurement().motion, shape),
  )
  let result = actual.commit(
    consumer_assigned_bundle(actual.measurement().motion, shape),
  )
  assert_eq(
    @debug.to_string(result.runs.active),
    @debug.to_string(wanted.runs.active),
  )
  assert_eq(
    @debug.to_string(result.runs.closed),
    @debug.to_string(wanted.runs.closed),
  )
  assert_true(result.runs.active.length() > 0)
}
