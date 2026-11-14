///|
test "packaged raw run windows retry a real candidate after a late shape failure without allocating its new ID" {
  let owner = @analysis.FootprintRunWindowSession::new(
    consumer_joint_run_owner(),
    window_us=100000L,
  )
  let shape : @zones.FootprintShape = @zones.Disk(
    @zones.DiskFootprint::new(0.125),
  )
  let initial = owner.prepare_ground(0L, consumer_joint_run_observation())
  ignore(
    initial.commit(
      consumer_assigned_bundle(initial.measurement().motion, shape),
    ),
  )
  let observations = consumer_joint_run_observation()
  observations.push(
    @moonground.GroundObservation::new(
      2,
      { x: 1.0, y: 0.5, },
      @moonground.Covariance2::isotropic(0.1),
    ),
  )
  let candidate = owner.prepare_ground(100000L, observations)
  let inspected = candidate.measurement()
  assert_eq(inspected.motion.tracks[0].status, @motion.Ready)
  assert_eq(inspected.motion.tracks[1].segment_id, "2")
  let before = owner.checkpoint()
  let tiny : @zones.FootprintShape = @zones.Disk(
    @zones.DiskFootprint::new(1.0e-30),
  )
  try candidate.commit(consumer_assigned_bundle(inspected.motion, tiny)) catch {
    _ => ()
  } noraise {
    _ => fail("unrepresentable footprint support accepted")
  }
  assert_eq(owner.checkpoint().windows.runs.last_timestamp_us, Some(0L))
  assert_eq(
    @debug.to_string(owner.checkpoint().measurement),
    @debug.to_string(before.measurement),
  )
  assert_eq(
    @debug.to_string(owner.checkpoint().windows.current_window),
    @debug.to_string(before.windows.current_window),
  )
  let actual = candidate.commit(
    consumer_assigned_bundle(inspected.motion, shape),
  )
  assert_eq(actual.windows.statistics.closed_window.unwrap().input_frames, 1L)
  assert_eq(actual.windows.statistics.current_window.input_frames, 1L)
  assert_eq(
    actual.windows.statistics.current_window.zones[0].confirmed_inside,
    1L,
  )
  guard owner.checkpoint().measurement is Ground(motion) else {
    fail("metric owner missing")
  }
  assert_eq(motion.next_segment_id, 3L)
  assert_eq(motion.tracks.map(track => track.segment_id), [1L, 2L])
  ignore(
    @analysis.FootprintRunWindowSession::from_checkpoint(owner.checkpoint()),
  )
}

///|
test "packaged complete run window checkpoint crosses a bucket without repeating confirmation and forks close independently" {
  let owner = @analysis.FootprintRunWindowSession::new(
    consumer_joint_run_owner(),
    window_us=200000L,
  )
  let shape : @zones.FootprintShape = @zones.Convex(consumer_convex_footprint())
  for time in [0L, 100000L] {
    let candidate = owner.prepare_ground(time, consumer_joint_run_observation())
    ignore(
      candidate.commit(
        consumer_assigned_bundle(candidate.measurement().motion, shape),
      ),
    )
  }
  assert_eq(
    owner.checkpoint().windows.current_window.unwrap().zones[0].confirmed_inside,
    1L,
  )
  let resumed = @analysis.FootprintRunWindowSession::from_checkpoint(
    owner.checkpoint(),
  )
  let candidate = resumed.prepare_ground(
    200000L,
    consumer_joint_run_observation(),
  )
  let output = candidate.commit(
    consumer_assigned_bundle(candidate.measurement().motion, shape),
  )
  assert_eq(
    output.windows.statistics.closed_window.unwrap().zones[0].confirmed_inside,
    1L,
  )
  assert_eq(
    output.windows.statistics.current_window.zones[0].opening_confirmed,
    1L,
  )
  assert_eq(
    output.windows.statistics.current_window.zones[0].confirmed_inside,
    0L,
  )
  let branch = resumed.fork()
  let closed = branch.interrupt(300000L)
  assert_eq(closed.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(closed.windows.statistics.current_window.input_frames, 2L)
  assert_eq(
    closed.windows.statistics.current_window.zones[0].endings[1].confirmed,
    1L,
  )
  assert_eq(branch.checkpoint().windows.runs.states.length(), 0)
  assert_eq(resumed.checkpoint().windows.runs.states.length(), 1)
  assert_eq(owner.checkpoint().windows.runs.last_timestamp_us, Some(100000L))
  ignore(
    @analysis.FootprintRunWindowSession::from_checkpoint(branch.checkpoint()),
  )
}

///|
test "packaged Brown raw run windows preserve metric state and window chronology through complete restore and warm pixel reframe" {
  let (guarded, _, _, left, middle, right) = consumer_brown_guarded()
  guard guarded.checkpoint().analysis.measurement is Pixel(pixel) else {
    fail("Brown pixel fixture missing")
  }
  let original = @analysis.FootprintRunSession::from_pixel(
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
  let owner = @analysis.FootprintRunWindowSession::new(
    original,
    window_us=300000L,
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
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=1.25,
    offset_x=-15.0,
    offset_y=8.0,
  )
  let resumed = @analysis.FootprintRunWindowSession::from_checkpoint(
    owner.checkpoint(),
  )
  let adapted = resumed.reframed(transform)
  guard adapted.checkpoint().measurement is Pixel(changed) else {
    fail("reframed pixel owner missing")
  }
  guard owner.checkpoint().measurement is Pixel(unchanged) else {
    fail("original pixel owner missing")
  }
  assert_eq(
    @debug.to_string(changed.motion),
    @debug.to_string(unchanged.motion),
  )
  assert_eq(
    @debug.to_string(adapted.checkpoint().windows.current_window),
    @debug.to_string(owner.checkpoint().windows.current_window),
  )
  let a = owner.prepare_pixel(400000L, [right])
  let b = adapted.prepare_pixel(400000L, [right.reframed(transform)])
  let expected = a.commit(
    consumer_assigned_bundle(a.measurement().motion, shape),
  )
  let actual = b.commit(consumer_assigned_bundle(b.measurement().motion, shape))
  assert_eq(
    @debug.to_string(actual.windows.statistics),
    @debug.to_string(expected.windows.statistics),
  )
  assert_eq(
    @debug.to_string(actual.windows.runs.active),
    @debug.to_string(expected.windows.runs.active),
  )
  assert_true(actual.windows.runs.active.length() > 0)
  ignore(
    @analysis.FootprintRunWindowSession::from_checkpoint(adapted.checkpoint()),
  )
}
