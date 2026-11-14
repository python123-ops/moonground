///|
fn footprint_window_cp_owner() -> @analysis.FootprintRunWindowSession raise @types.GroundError {
  let original = @analysis.FootprintRunSession::from_ground(
    @motion.MotionEstimator::new(
      "window-joint-cp",
      @motion.MotionConfig::new(min_observations=2, min_span_us=0L),
    ),
    @zones.FootprintRunMonitor::new(
      "window-joint-cp",
      [
        @zones.ConvexZone::new("one", [
          { x: -10.0, y: -10.0, },
          { x: 10.0, y: -10.0, },
          { x: 10.0, y: 10.0, },
          { x: -10.0, y: 10.0, },
        ]),
      ],
      @zones.FootprintRunConfig::new(min_samples=1L, confirmation_us=0L),
    ),
  )
  let owner = @analysis.FootprintRunWindowSession::new(original, window_us=100L)
  for time in [0L, 1L, 2L, 5L, 10L] {
    let candidate = owner.prepare_ground(
      time,
      footprint_run_checkpoint_observations(),
    )
    let frame = candidate.measurement().motion
    let shapes = if time < 5L {
      []
    } else {
      [
        @zones.FootprintAssignment::new(
          1,
          frame.tracks[0].segment_id,
          @zones.Disk(@zones.DiskFootprint::new(0.125)),
        ),
      ]
    }
    ignore(candidate.commit(@zones.FootprintAssignments::new(time, shapes)))
  }
  owner
}

///|
fn footprint_window_cp_bad(
  saved : @analysis.FootprintRunWindowSessionCheckpoint,
) -> Unit raise {
  try @analysis.FootprintRunWindowSession::from_checkpoint(saved) catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("impossible joint run window checkpoint accepted")
  }
}

///|
fn footprint_window_cp_components(
  saved : @analysis.FootprintRunWindowSessionCheckpoint,
) -> Unit raise {
  ignore(@zones.FootprintRunWindowMonitor::from_checkpoint(saved.windows))
  ignore(
    @analysis.FootprintRunSession::from_checkpoint({
      version: 1,
      measurement: saved.measurement,
      runs: saved.windows.runs,
    }),
  )
}

///|
test "joint run windows bind version and both original clocks" {
  let saved = footprint_window_cp_owner().checkpoint()
  footprint_window_cp_bad({ ..saved, version: 2, })
  footprint_window_cp_bad({
    ..saved,
    windows: {
      ..saved.windows,
      runs: { ..saved.windows.runs, last_timestamp_us: Some(11L), },
    },
  })
}

///|
test "joint run window current position is the original filtered mean" {
  let saved = footprint_window_cp_owner().checkpoint()
  let state = saved.windows.runs.states[0]
  saved.windows.runs.states[0] = {
    ..state,
    last_position_m: { x: 0.6, y: 0.5, },
  }
  ignore(@zones.FootprintRunWindowMonitor::from_checkpoint(saved.windows))
  footprint_window_cp_bad(saved)
}

///|
test "joint run windows bind exact upper covariance even if geometry agrees" {
  let saved = footprint_window_cp_owner().checkpoint()
  let state = saved.windows.runs.states[0]
  saved.windows.runs.states[0] = {
    ..state,
    last_position_covariance: {
      ..state.last_position_covariance,
      xx: state.last_position_covariance.xx + 1.0e-6,
    },
  }
  ignore(@zones.FootprintRunWindowMonitor::from_checkpoint(saved.windows))
  footprint_window_cp_bad(saved)
}

///|
test "joint run windows accepted samples fit the exact suffix not just global frames" {
  let saved = footprint_window_cp_owner().checkpoint()
  guard saved.measurement is @analysis.Ground(motion) else {
    fail("ground missing")
  }
  let first = motion.tracks[0]
  motion.tracks.push({
    ..first,
    track_id: 2,
    segment_id: 2L,
    first_timestamp_us: 5L,
    accepted_count: 3,
  })
  let changed = {
    ..saved,
    measurement: @analysis.Ground({ ..motion, next_segment_id: 3L, }),
  }
  footprint_window_cp_components(changed)
  footprint_window_cp_bad(changed)
  motion.tracks[1] = { ..motion.tracks[1], accepted_count: 2, }
  ignore(
    @analysis.FootprintRunWindowSession::from_checkpoint({
      ..saved,
      measurement: @analysis.Ground({ ..motion, next_segment_id: 3L, }),
    }),
  )
}

///|
test "joint run windows hidden witness must fit each anchored input interval" {
  let saved = footprint_window_cp_owner().checkpoint()
  guard saved.measurement is @analysis.Ground(motion) else {
    fail("ground missing")
  }
  guard saved.windows.current_window is Some(window) else {
    fail("window missing")
  }
  let first = motion.tracks[0]
  motion.tracks[0] = { ..first, last_timestamp_us: 20L, accepted_count: 10, }
  let single = @motion.MotionEstimator::new("window-joint-cp", motion.config)
  ignore(single.update(1L, footprint_run_checkpoint_observations()))
  motion.tracks.push({
    ..single.checkpoint().tracks[0],
    track_id: 2,
    segment_id: 2L,
    first_timestamp_us: 1L,
    last_timestamp_us: 1L,
    accepted_count: 1,
  })
  let state = saved.windows.runs.states[0]
  saved.windows.runs.states[0] = {
    ..state,
    run: {
      ..state.run,
      first_timestamp_us: 8L,
      last_timestamp_us: 20L,
      sample_span_us: 12L,
      sample_count: 9L,
    },
  }
  let changed = {
    ..saved,
    measurement: @analysis.Ground({
      ..motion,
      last_timestamp_us: Some(20L),
      next_segment_id: 3L,
    }),
    windows: {
      ..saved.windows,
      runs: { ..saved.windows.runs, last_timestamp_us: Some(20L), },
      current_window: Some({
        ..window,
        last_timestamp_us: 20L,
        input_frames: 10L,
      }),
    },
  }
  footprint_window_cp_components(changed)
  footprint_window_cp_bad(changed)
}

///|
test "joint run windows cannot omit a saved accepted first input" {
  let saved = footprint_window_cp_owner().checkpoint()
  guard saved.windows.current_window is Some(window) else {
    fail("window missing")
  }
  let changed = {
    ..saved,
    windows: {
      ..saved.windows,
      current_window: Some({ ..window, first_timestamp_us: 1L, }),
    },
  }
  footprint_window_cp_components(changed)
  footprint_window_cp_bad(changed)
}

///|
test "started window baseline permits genuine accepted history before its origin" {
  let existing = footprint_run_checkpoint_session()
  let owner = @analysis.FootprintRunWindowSession::new(
    existing,
    window_us=1000000L,
    origin_us=200000L,
  )
  assert_true(owner.checkpoint().windows.current_window is None)
  assert_eq(owner.checkpoint().windows.baseline_timestamp_us, Some(200000L))
  ignore(
    @analysis.FootprintRunWindowSession::from_checkpoint(owner.checkpoint()),
  )
  let candidate = owner.prepare_ground(
    300000L,
    footprint_run_checkpoint_observations(),
  )
  let frame = candidate.measurement().motion
  let output = candidate.commit(
    @zones.FootprintAssignments::new(300000L, [
      @zones.FootprintAssignment::new(
        1,
        frame.tracks[0].segment_id,
        @zones.Disk(@zones.DiskFootprint::new(0.125)),
      ),
    ]),
  )
  assert_eq(output.windows.statistics.current_window.input_frames, 1L)
  assert_eq(
    output.windows.statistics.current_window.zones[0].opening_confirmed,
    1L,
  )
  ignore(
    @analysis.FootprintRunWindowSession::from_checkpoint(owner.checkpoint()),
  )
}

///|
test "joint window source and fork export detached run and statistic arrays" {
  let owner = footprint_window_cp_owner()
  let saved = owner.checkpoint()
  let restored = @analysis.FootprintRunWindowSession::from_checkpoint(saved)
  let branch = owner.fork()
  saved.windows.runs.states.clear()
  guard saved.windows.current_window is Some(window) else {
    fail("window missing")
  }
  window.zones.clear()
  assert_eq(owner.checkpoint().windows.runs.states.length(), 1)
  assert_eq(restored.checkpoint().windows.runs.states.length(), 1)
  let output = branch.interrupt(11L)
  assert_eq(output.windows.runs.active.length(), 0)
  assert_eq(output.windows.statistics.current_window.input_frames, 6L)
  assert_eq(owner.checkpoint().windows.runs.last_timestamp_us, Some(10L))
}

///|
test "joint window preparations retry assignments and reject committed reuse" {
  let owner = footprint_window_cp_owner()
  let candidate = owner.prepare_ground(
    11L,
    footprint_run_checkpoint_observations(),
  )
  try
    candidate.commit(
      @zones.FootprintAssignments::new(11L, [
        @zones.FootprintAssignment::new(
          1,
          "99",
          @zones.Disk(@zones.DiskFootprint::new(0.125)),
        ),
      ]),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("stale segment accepted")
  }
  assert_eq(owner.checkpoint().windows.runs.last_timestamp_us, Some(10L))
  ignore(candidate.commit(@zones.FootprintAssignments::new(11L, [])))
  try candidate.commit(@zones.FootprintAssignments::new(11L, [])) catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("committed preparation reused")
  }
}

///|
test "joint window origin failure discards motion candidate including segment allocation" {
  let existing = @analysis.FootprintRunSession::from_ground(
    @motion.MotionEstimator::new(
      "origin-window",
      @motion.MotionConfig::new(min_observations=2, min_span_us=0L),
    ),
    @zones.FootprintRunMonitor::new(
      "origin-window",
      [
        @zones.ConvexZone::new("one", [
          { x: -10.0, y: -10.0, },
          { x: 10.0, y: -10.0, },
          { x: 10.0, y: 10.0, },
          { x: -10.0, y: 10.0, },
        ]),
      ],
      @zones.FootprintRunConfig::new(),
    ),
  )
  let owner = @analysis.FootprintRunWindowSession::new(
    existing,
    window_us=10L,
    origin_us=100L,
  )
  let bad = owner.prepare_ground(99L, footprint_run_checkpoint_observations())
  try bad.commit(@zones.FootprintAssignments::new(99L, [])) catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("pre-origin input accepted")
  }
  guard owner.checkpoint().measurement is @analysis.Ground(before) else {
    fail("ground missing")
  }
  assert_eq(before.next_segment_id, 1L)
  let corrected = owner.prepare_ground(
    100L,
    footprint_run_checkpoint_observations(),
  )
  assert_eq(corrected.measurement().motion.tracks[0].segment_id, "1")
  ignore(corrected.commit(@zones.FootprintAssignments::new(100L, [])))
}
