///|
fn consumer_guarded_run_owner() -> @guarded.FootprintRunGuardedSession raise @moonground.GroundError {
  let calibration = @moonground.GroundCalibration::from_homography(
    [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    [
      { x: -10.0, y: -10.0, },
      { x: 10.0, y: -10.0, },
      { x: 10.0, y: 10.0, },
      { x: -10.0, y: 10.0, },
    ],
    max_meters_per_pixel=2.0,
  )
  let measurement = @moonground.MeasurementSession::new(
    "consumer-guarded-runs",
    calibration,
    @moonground.MotionConfig::new(
      max_tracks=8,
      min_observations=2,
      min_span_us=0L,
    ),
  )
  let runs = @zones.FootprintRunMonitor::new(
    "consumer-guarded-runs",
    [
      @zones.ConvexZone::new("wide", [
        { x: -10.0, y: -10.0, },
        { x: 10.0, y: -10.0, },
        { x: 10.0, y: 10.0, },
        { x: -10.0, y: 10.0, },
      ]),
    ],
    @zones.FootprintRunConfig::new(min_samples=2L, confirmation_us=100000L),
    max_tracks=8,
  )
  let health = @health.CalibrationMonitor::new(
    calibration,
    [
      @health.KnownLandmark::new("a", { x: 0.0, y: 0.0, }),
      @health.KnownLandmark::new("b", { x: 1.0, y: 0.0, }),
      @health.KnownLandmark::new("c", { x: 0.0, y: 1.0, }),
    ],
    @health.HealthConfig::new(min_observations=2, confirmation_us=100000L),
  )
  @guarded.FootprintRunGuardedSession::new(
    @analysis.FootprintRunSession::from_pixel(measurement, runs),
    health,
  )
}

///|
fn consumer_guarded_run_landmarks() -> Array[@health.LandmarkObservation] raise @moonground.GroundError {
  let covariance = @moonground.Covariance2::isotropic(0.01)
  [
    @health.LandmarkObservation::new("a", { x: 0.0, y: 0.0, }, covariance),
    @health.LandmarkObservation::new("b", { x: 1.0, y: 0.0, }, covariance),
    @health.LandmarkObservation::new("c", { x: 0.0, y: 1.0, }, covariance),
  ]
}

///|
fn consumer_guarded_run_objects() -> Array[@moonground.PixelObservation] raise @moonground.GroundError {
  [
    @moonground.PixelObservation::new(
      1,
      { x: 0.5, y: 0.5, },
      @moonground.Covariance2::isotropic(0.1),
    ),
  ]
}

///|
test "packaged guarded run previews detach and blocked assignments remain explicitly empty" {
  let owner = consumer_guarded_run_owner()
  let prepared = owner.prepare(
    0L,
    consumer_guarded_run_landmarks(),
    consumer_guarded_run_objects(),
  )
  let preview = prepared.preview()
  assert_eq(preview.decision, @guarded.Blocked)
  assert_eq(preview.measurement.motion.tracks.length(), 0)
  assert_eq(preview.suppressed_track_ids, [1])
  preview.health.landmarks.clear()
  preview.suppressed_track_ids.clear()
  assert_eq(prepared.preview().health.landmarks.length(), 3)
  assert_eq(prepared.preview().suppressed_track_ids, [1])
  let shape : @zones.FootprintShape = @zones.Disk(
    @zones.DiskFootprint::new(0.125),
  )
  try
    prepared.commit(
      @zones.FootprintAssignments::new(0L, [
        @zones.FootprintAssignment::new(1, "1", shape),
      ]),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("blocked nonempty assignments silently discarded")
  }
  assert_eq(owner.checkpoint().health.last_timestamp_us, None)
  ignore(prepared.commit(@zones.FootprintAssignments::new(0L, [])))
  assert_eq(owner.checkpoint().health.last_timestamp_us, Some(0L))
  let confirming = owner.prepare(
    100000L,
    consumer_guarded_run_landmarks(),
    consumer_guarded_run_objects(),
  )
  assert_eq(confirming.preview().decision, @guarded.Allowed)
  assert_eq(confirming.preview().measurement.motion.tracks[0].segment_id, "1")
  try
    confirming.commit(
      @zones.FootprintAssignments::new(100000L, [
        @zones.FootprintAssignment::new(1, "9", shape),
      ]),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("incorrect first actual identity accepted")
  }
  assert_eq(owner.checkpoint().health.last_timestamp_us, Some(0L))
  ignore(
    confirming.commit(
      consumer_assigned_bundle(confirming.preview().measurement.motion, shape),
    ),
  )
  assert_eq(owner.checkpoint().health.last_timestamp_us, Some(100000L))
}

///|
test "packaged guarded run late numeric retry jointly preserves health motion and sample histories" {
  let owner = consumer_guarded_run_owner()
  let shape : @zones.FootprintShape = @zones.Disk(
    @zones.DiskFootprint::new(0.125),
  )
  for time in [0L, 100000L] {
    let prepared = owner.prepare(
      time,
      consumer_guarded_run_landmarks(),
      consumer_guarded_run_objects(),
    )
    ignore(
      prepared.commit(
        consumer_assigned_bundle(prepared.preview().measurement.motion, shape),
      ),
    )
  }
  let prepared = owner.prepare(
    200000L,
    consumer_guarded_run_landmarks(),
    consumer_guarded_run_objects(),
  )
  let competing = owner.prepare(
    300000L,
    consumer_guarded_run_landmarks(),
    consumer_guarded_run_objects(),
  )
  let tiny : @zones.FootprintShape = @zones.Disk(
    @zones.DiskFootprint::new(1.0e-30),
  )
  try
    prepared.commit(
      consumer_assigned_bundle(prepared.preview().measurement.motion, tiny),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("unrepresentable physical contribution accepted")
  }
  assert_eq(owner.checkpoint().health.last_timestamp_us, Some(100000L))
  assert_eq(owner.checkpoint().analysis.runs.last_timestamp_us, Some(100000L))
  assert_eq(owner.checkpoint().analysis.runs.states.length(), 0)
  let result = prepared.commit(
    consumer_assigned_bundle(prepared.preview().measurement.motion, shape),
  )
  assert_eq(result.analysis.runs.active[0].sample_count, 1L)
  try
    competing.commit(
      consumer_assigned_bundle(competing.preview().measurement.motion, shape),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("stale guarded candidate committed")
  }
  let branch = owner.fork()
  let blocked = branch.prepare(300000L, [], consumer_guarded_run_objects())
  let output = blocked.commit(@zones.FootprintAssignments::new(300000L, []))
  assert_eq(output.analysis.runs.active.length(), 0)
  assert_eq(output.analysis.runs.closed.length(), 1)
  assert_eq(owner.checkpoint().analysis.runs.states.length(), 1)
  ignore(
    @guarded.FootprintRunGuardedSession::from_checkpoint(owner.checkpoint()),
  )
}

///|
test "packaged guarded projection barrier invalidates candidates and starts health cold without reusing segment ids" {
  let owner = consumer_guarded_run_owner()
  let shape : @zones.FootprintShape = @zones.Convex(consumer_convex_footprint())
  for time in [0L, 100000L, 200000L] {
    let prepared = owner.prepare(
      time,
      consumer_guarded_run_landmarks(),
      consumer_guarded_run_objects(),
    )
    ignore(
      prepared.commit(
        consumer_assigned_bundle(prepared.preview().measurement.motion, shape),
      ),
    )
  }
  let stale = owner.prepare(
    300000L,
    consumer_guarded_run_landmarks(),
    consumer_guarded_run_objects(),
  )
  let previous = owner.checkpoint()
  let barrier = owner.replace_projection(
    250000L,
    previous.health.calibration,
    camera=None,
  )
  assert_eq(barrier.decision, @guarded.Blocked)
  assert_eq(barrier.health.status, @health.Insufficient)
  assert_eq(barrier.analysis.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(owner.checkpoint().analysis.runs.states.length(), 0)
  try
    stale.commit(
      consumer_assigned_bundle(stale.preview().measurement.motion, shape),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("pre-replacement candidate committed")
  }
  let pending = owner.prepare(
    300000L,
    consumer_guarded_run_landmarks(),
    consumer_guarded_run_objects(),
  )
  assert_eq(pending.preview().decision, @guarded.Blocked)
  ignore(pending.commit(@zones.FootprintAssignments::new(300000L, [])))
  let accepted = owner.prepare(
    400000L,
    consumer_guarded_run_landmarks(),
    consumer_guarded_run_objects(),
  )
  assert_eq(accepted.preview().measurement.motion.tracks[0].segment_id, "2")
  ignore(
    accepted.commit(
      consumer_assigned_bundle(accepted.preview().measurement.motion, shape),
    ),
  )
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=1.25,
    offset_x=-15.0,
    offset_y=8.0,
  )
  let branch = owner.reframed(transform)
  assert_eq(branch.checkpoint().health.last_timestamp_us, Some(400000L))
  assert_eq(
    branch.checkpoint().analysis.runs.states.length(),
    owner.checkpoint().analysis.runs.states.length(),
  )
}
