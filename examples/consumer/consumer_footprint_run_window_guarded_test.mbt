///|
fn consumer_guarded_window_step(
  owner : @guarded.FootprintRunWindowGuardedSession,
  timestamp : Int64,
  landmarks : Array[@health.LandmarkObservation],
  objects : Array[@moonground.PixelObservation],
) -> @guarded.FootprintRunWindowGuardedFrame raise @moonground.GroundError {
  let candidate = owner.prepare(timestamp, landmarks, objects)
  candidate.commit(
    consumer_assigned_bundle(
      candidate.preview().measurement.motion,
      @zones.Disk(@zones.DiskFootprint::new(0.125)),
    ),
  )
}

///|
test "packaged guarded windows retry first Healthy identities and first Ready numeric errors without partial health or window commits" {
  let owner = @guarded.FootprintRunWindowGuardedSession::new(
    consumer_guarded_run_owner(),
    window_us=100000L,
  )
  ignore(
    consumer_guarded_window_step(
      owner,
      0L,
      consumer_guarded_run_landmarks(),
      consumer_guarded_run_objects(),
    ),
  )
  let candidate = owner.prepare(
    100000L,
    consumer_guarded_run_landmarks(),
    consumer_guarded_run_objects(),
  )
  assert_eq(candidate.preview().health.status, @health.Healthy)
  try
    candidate.commit(
      @zones.FootprintAssignments::new(100000L, [
        @zones.FootprintAssignment::new(
          1,
          "9",
          @zones.Disk(@zones.DiskFootprint::new(0.125)),
        ),
      ]),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("wrong actual segment accepted")
  }
  assert_eq(owner.checkpoint().health.streak.unwrap().observations, 1)
  assert_eq(
    owner.checkpoint().analysis.windows.current_window.unwrap().last_timestamp_us,
    0L,
  )
  ignore(
    candidate.commit(
      consumer_assigned_bundle(
        candidate.preview().measurement.motion,
        @zones.Disk(@zones.DiskFootprint::new(0.125)),
      ),
    ),
  )
  let ready = owner.prepare(
    200000L,
    consumer_guarded_run_landmarks(),
    consumer_guarded_run_objects(),
  )
  assert_eq(ready.preview().measurement.motion.tracks[0].status, @motion.Ready)
  let before = owner.checkpoint()
  try
    ready.commit(
      consumer_assigned_bundle(
        ready.preview().measurement.motion,
        @zones.Disk(@zones.DiskFootprint::new(1.0e-30)),
      ),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("unrepresentable physical expansion accepted")
  }
  assert_eq(
    @debug.to_string(owner.checkpoint().health),
    @debug.to_string(before.health),
  )
  assert_eq(
    @debug.to_string(owner.checkpoint().analysis.measurement),
    @debug.to_string(before.analysis.measurement),
  )
  assert_eq(
    @debug.to_string(owner.checkpoint().analysis.windows.current_window),
    @debug.to_string(before.analysis.windows.current_window),
  )
  let actual = ready.commit(
    consumer_assigned_bundle(
      ready.preview().measurement.motion,
      @zones.Disk(@zones.DiskFootprint::new(0.125)),
    ),
  )
  assert_eq(actual.analysis.windows.statistics.current_window.input_frames, 1L)
  assert_eq(actual.analysis.windows.runs.active[0].sample_count, 1L)
  ignore(
    @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
      owner.checkpoint(),
    ),
  )
}

///|
test "packaged health blocking closes a confirmed run once and complete window restore warms up a new segment" {
  let owner = @guarded.FootprintRunWindowGuardedSession::new(
    consumer_guarded_run_owner(),
    window_us=200000L,
  )
  for time in [0L, 100000L, 200000L, 300000L] {
    ignore(
      consumer_guarded_window_step(
        owner,
        time,
        consumer_guarded_run_landmarks(),
        consumer_guarded_run_objects(),
      ),
    )
  }
  let blocked = consumer_guarded_window_step(
    owner,
    350000L,
    [],
    consumer_guarded_run_objects(),
  )
  assert_eq(blocked.decision, @guarded.Blocked)
  assert_eq(blocked.analysis.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(blocked.analysis.windows.statistics.current_window.input_frames, 3L)
  assert_eq(
    blocked.analysis.windows.statistics.current_window.zones[0].confirmed_inside,
    1L,
  )
  assert_eq(
    blocked.analysis.windows.statistics.current_window.zones[0].endings[1].confirmed,
    1L,
  )
  let resumed = @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
    owner.checkpoint(),
  )
  let pending = consumer_guarded_window_step(
    resumed,
    400000L,
    consumer_guarded_run_landmarks(),
    consumer_guarded_run_objects(),
  )
  assert_eq(pending.decision, @guarded.Blocked)
  assert_eq(
    pending.analysis.windows.statistics.closed_window.unwrap().zones[0].endings[1].confirmed,
    1L,
  )
  let healthy = consumer_guarded_window_step(
    resumed,
    500000L,
    consumer_guarded_run_landmarks(),
    consumer_guarded_run_objects(),
  )
  assert_eq(healthy.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(healthy.analysis.windows.runs.active.length(), 0)
  assert_eq(
    healthy.analysis.windows.statistics.current_window.zones[0].confirmed_inside,
    0L,
  )
  let branch = resumed.fork()
  ignore(
    branch.replace_projection(
      550000L,
      branch.checkpoint().health.calibration,
      camera=None,
    ),
  )
  assert_true(branch.checkpoint().health.streak is None)
  assert_eq(
    @health.CalibrationMonitor::from_checkpoint(resumed.checkpoint().health).status(),
    @health.Healthy,
  )
}

///|
test "packaged Brown guarded window restore reframe and explicit camera removal preserve metric statistics then create one cold barrier" {
  let (legacy, _, _, left, middle, right) = consumer_brown_guarded()
  let saved = legacy.checkpoint()
  guard saved.analysis.measurement is Pixel(pixel) else {
    fail("Brown pixel fixture missing")
  }
  let guarded = @guarded.FootprintRunGuardedSession::new(
    @analysis.FootprintRunSession::from_pixel(
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
    ),
    @health.CalibrationMonitor::from_checkpoint(saved.health),
  )
  let owner = @guarded.FootprintRunWindowGuardedSession::new(
    guarded,
    window_us=200000L,
  )
  let (_, _, refs, _, _, _) = consumer_brown_guarded()
  for (time, object) in [(0L, left), (150000L, middle), (300000L, right)] {
    ignore(consumer_guarded_window_step(owner, time, refs, [object]))
  }
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=1.25,
    offset_x=-15.0,
    offset_y=8.0,
  )
  let resumed = @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
    owner.checkpoint(),
  )
  let adapted = resumed.reframed(transform)
  guard adapted.checkpoint().analysis.measurement is Pixel(changed) else {
    fail("adapted pixel missing")
  }
  guard owner.checkpoint().analysis.measurement is Pixel(original) else {
    fail("original pixel missing")
  }
  assert_eq(@debug.to_string(changed.motion), @debug.to_string(original.motion))
  let a = consumer_guarded_window_step(owner, 400000L, refs, [right])
  let b = consumer_guarded_window_step(
    adapted,
    400000L,
    refs.map(observation => observation.reframed(transform)),
    [right.reframed(transform)],
  )
  assert_eq(
    @debug.to_string(a.analysis.windows.statistics),
    @debug.to_string(b.analysis.windows.statistics),
  )
  let before = adapted.checkpoint()
  let barrier = adapted.replace_projection(
    450000L,
    before.health.calibration,
    camera=None,
  )
  assert_eq(barrier.health.status, @health.Insufficient)
  assert_eq(barrier.analysis.windows.statistics.current_window.input_frames, 2L)
  assert_eq(
    barrier.analysis.windows.statistics.current_window.zones[0].endings[1].confirmed,
    1L,
  )
  guard adapted.checkpoint().analysis.measurement is Pixel(cold) else {
    fail("cold pixel missing")
  }
  assert_true(cold.camera is None)
  assert_eq(cold.motion.next_segment_id, changed.motion.next_segment_id)
  assert_eq(cold.motion.tracks.length(), 0)
  ignore(
    @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
      adapted.checkpoint(),
    ),
  )
}
