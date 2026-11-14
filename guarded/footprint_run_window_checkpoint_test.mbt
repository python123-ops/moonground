///|
fn footprint_window_guard_cp_old(
  samples~ : Int32 = 1,
) -> @guarded.FootprintRunGuardedSession raise @types.GroundError {
  @guarded.FootprintRunGuardedSession::new(
    @analysis.FootprintRunSession::from_pixel(
      @moonground.MeasurementSession::new(
        "guarded",
        calibration(),
        @moonground.MotionConfig::new(
          min_observations=2,
          min_span_us=0L,
          max_gap_us=100L,
          max_tracks=10,
        ),
      ),
      @zones.FootprintRunMonitor::new(
        "guarded",
        [
          @zones.ConvexZone::new("wide", [
            { x: -10.0, y: -10.0, },
            { x: 10.0, y: -10.0, },
            { x: 10.0, y: 10.0, },
            { x: -10.0, y: 10.0, },
          ]),
        ],
        @zones.FootprintRunConfig::new(
          max_gap_us=100L,
          min_samples=1L,
          confirmation_us=0L,
        ),
        max_tracks=10,
      ),
    ),
    monitor(
      config=@health.HealthConfig::new(
        min_observations=samples,
        confirmation_us=0L,
        max_gap_us=4L,
      ),
    ),
  )
}

///|
fn footprint_window_guard_cp_owner(
  times : Array[Int64],
  shape_since~ : Int64 = 0L,
  samples~ : Int32 = 1,
) -> @guarded.FootprintRunWindowGuardedSession raise @types.GroundError {
  let owner = @guarded.FootprintRunWindowGuardedSession::new(
    footprint_window_guard_cp_old(samples~),
    window_us=100L,
  )
  for time in times {
    let prepared = owner.prepare(time, landmarks(), [pixel(1, 0.5, x=0.5)])
    let frame = prepared.preview().measurement.motion
    let entries = if time < shape_since {
      []
    } else {
      frame.tracks.map(track => {
        @zones.FootprintAssignment::new(
          track.track_id,
          track.segment_id,
          @zones.Disk(@zones.DiskFootprint::new(0.125)),
        )
      })
    }
    ignore(prepared.commit(@zones.FootprintAssignments::new(time, entries)))
  }
  owner
}

///|
fn footprint_window_guard_cp_components(
  saved : @guarded.FootprintRunWindowGuardedCheckpoint,
) -> Unit raise {
  ignore(@analysis.FootprintRunWindowSession::from_checkpoint(saved.analysis))
  ignore(
    @guarded.FootprintRunGuardedSession::from_checkpoint({
      version: 1,
      analysis: {
        version: 1,
        measurement: saved.analysis.measurement,
        runs: saved.analysis.windows.runs,
      },
      health: saved.health,
    }),
  )
}

///|
fn footprint_window_guard_cp_bad(
  saved : @guarded.FootprintRunWindowGuardedCheckpoint,
) -> Unit raise {
  try @guarded.FootprintRunWindowGuardedSession::from_checkpoint(saved) catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("impossible health controlled run window CP accepted")
  }
}

///|
test "guarded run windows bind version Option clock and original calibration" {
  let saved = footprint_window_guard_cp_owner([0L, 1L, 2L]).checkpoint()
  footprint_window_guard_cp_bad({ ..saved, version: 2, })
  footprint_window_guard_cp_bad({
    ..saved,
    health: { ..saved.health, last_timestamp_us: Some(3L), },
  })
  footprint_window_guard_cp_bad({
    ..saved,
    health: {
      ..saved.health,
      camera: Some(
        @moonground.CameraModel::new(fx=100.0, fy=100.0, cx=0.0, cy=0.0),
      ),
    },
  })
}

///|
test "guarded run windows require pixel and enough downstream closure capacity" {
  let saved = footprint_window_guard_cp_owner([0L, 1L, 2L]).checkpoint()
  guard saved.analysis.measurement is @analysis.Pixel(pixel) else {
    fail("pixel missing")
  }
  footprint_window_guard_cp_bad({
    ..saved,
    analysis: { ..saved.analysis, measurement: @analysis.Ground(pixel.motion), },
  })
  footprint_window_guard_cp_bad({
    ..saved,
    analysis: {
      ..saved.analysis,
      windows: {
        ..saved.analysis.windows,
        runs: { ..saved.analysis.windows.runs, max_tracks: 1, },
      },
    },
  })
}

///|
test "guarded run windows reject active state under independently valid insufficient health" {
  let saved = footprint_window_guard_cp_owner([0L, 1L, 2L]).checkpoint()
  let health = { ..saved.health, streak: None, }
  ignore(@health.CalibrationMonitor::from_checkpoint(health))
  footprint_window_guard_cp_bad({ ..saved, health, })
}

///|
test "guarded local health continuity consumes its own exact suffix interval budget" {
  let saved = footprint_window_guard_cp_owner([0L, 1L, 8L, 20L], shape_since=8L).checkpoint()
  guard saved.analysis.measurement is @analysis.Pixel(pixel) else {
    fail("pixel missing")
  }
  guard saved.analysis.windows.current_window is Some(window) else {
    fail("window missing")
  }
  guard saved.health.streak is Some(streak) else { fail("streak missing") }
  pixel.motion.tracks[0] = { ..pixel.motion.tracks[0], accepted_count: 10, }
  let state = saved.analysis.windows.runs.states[0]
  saved.analysis.windows.runs.states[0] = {
    ..state,
    run: { ..state.run, sample_count: 9L, },
  }
  let changed = {
    ..saved,
    analysis: {
      ..saved.analysis,
      measurement: @analysis.Pixel(pixel),
      windows: {
        ..saved.analysis.windows,
        current_window: Some({ ..window, input_frames: 10L, }),
      },
    },
    health: { ..saved.health, streak: Some({ ..streak, since_us: 0L, }), },
  }
  footprint_window_guard_cp_components(changed)
  footprint_window_guard_cp_bad(changed)
  let health = {
    ..changed.health,
    config: @health.HealthConfig::new(
      min_observations=1,
      confirmation_us=0L,
      max_gap_us=9L,
    ),
  }
  ignore(
    @guarded.FootprintRunWindowGuardedSession::from_checkpoint({
      ..changed,
      health,
    }),
  )
}

///|
test "guarded instant restart removes forbidden paired input slots with boundary positive control" {
  let saved = footprint_window_guard_cp_owner(
    [0L, 1L, 10L, 11L],
    shape_since=11L,
  ).checkpoint()
  guard saved.analysis.measurement is @analysis.Pixel(pixel) else {
    fail("pixel missing")
  }
  guard saved.analysis.windows.current_window is Some(window) else {
    fail("window missing")
  }
  pixel.motion.tracks[0] = { ..pixel.motion.tracks[0], accepted_count: 2, }
  let changed = {
    ..saved,
    analysis: {
      ..saved.analysis,
      measurement: @analysis.Pixel(pixel),
      windows: {
        ..saved.analysis.windows,
        current_window: Some({ ..window, input_frames: 10L, }),
      },
    },
  }
  footprint_window_guard_cp_components(changed)
  footprint_window_guard_cp_bad(changed)
  let feasible = {
    ..changed,
    analysis: {
      ..changed.analysis,
      windows: {
        ..changed.analysis.windows,
        current_window: Some({ ..window, input_frames: 9L, }),
      },
    },
  }
  ignore(@guarded.FootprintRunWindowGuardedSession::from_checkpoint(feasible))
}

///|
test "guarded Pending exact health samples form an exact suffix anchor" {
  let saved = footprint_window_guard_cp_owner([0L, 1L, 2L], samples=5).checkpoint()
  guard saved.health.streak is Some(streak) else { fail("streak missing") }
  let changed = {
    ..saved,
    health: { ..saved.health, streak: Some({ ..streak, observations: 2, }), },
  }
  footprint_window_guard_cp_components(changed)
  footprint_window_guard_cp_bad(changed)
  ignore(@guarded.FootprintRunWindowGuardedSession::from_checkpoint(saved))
}

///|
test "saturated health observations are a lower bound and not exact window frame count" {
  let saved = footprint_window_guard_cp_owner([0L, 1L, 2L]).checkpoint()
  guard saved.health.streak is Some(streak) else { fail("streak missing") }
  assert_eq(streak.observations, 1)
  guard saved.analysis.windows.current_window is Some(window) else {
    fail("window missing")
  }
  assert_eq(window.input_frames, 3L)
  ignore(@guarded.FootprintRunWindowGuardedSession::from_checkpoint(saved))
}

///|
test "health streak first input cannot disappear before current window first" {
  let saved = footprint_window_guard_cp_owner([0L, 1L, 2L], samples=5).checkpoint()
  guard saved.analysis.windows.current_window is Some(window) else {
    fail("window missing")
  }
  let changed = {
    ..saved,
    analysis: {
      ..saved.analysis,
      windows: {
        ..saved.analysis.windows,
        current_window: Some({
          ..window,
          first_timestamp_us: 1L,
          input_frames: 2L,
        }),
      },
    },
  }
  footprint_window_guard_cp_components(changed)
  footprint_window_guard_cp_bad(changed)
}

///|
test "started guarded baseline excludes old health streak and confirmed run history" {
  let old = footprint_guard_cp_owner()
  let owner = @guarded.FootprintRunWindowGuardedSession::new(
    old,
    window_us=1000000L,
    origin_us=200000L,
  )
  assert_true(owner.checkpoint().analysis.windows.current_window is None)
  ignore(
    @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
      owner.checkpoint(),
    ),
  )
  let candidate = owner.prepare(300000L, landmarks(), [pixel(1, 0.5, x=0.5)])
  let frame = candidate.preview().measurement.motion
  let output = candidate.commit(
    @zones.FootprintAssignments::new(
      300000L,
      frame.tracks.map(track => {
        @zones.FootprintAssignment::new(
          track.track_id,
          track.segment_id,
          @zones.Disk(@zones.DiskFootprint::new(0.125)),
        )
      }),
    ),
  )
  assert_eq(output.analysis.windows.statistics.current_window.input_frames, 1L)
  assert_eq(
    output.analysis.windows.statistics.current_window.zones[0].opening_confirmed,
    1L,
  )
  assert_eq(
    output.analysis.windows.statistics.current_window.zones[0].confirmed_inside,
    0L,
  )
  ignore(
    @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
      owner.checkpoint(),
    ),
  )
}

///|
test "guarded run window fork checkpoint and preview arrays detach" {
  let owner = footprint_window_guard_cp_owner([0L, 1L, 2L])
  let saved = owner.checkpoint()
  let branch = owner.fork()
  let resumed = @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
    saved,
  )
  saved.analysis.windows.runs.states.clear()
  guard saved.analysis.windows.current_window is Some(window) else {
    fail("window missing")
  }
  window.zones.clear()
  assert_eq(owner.checkpoint().analysis.windows.runs.states.length(), 1)
  assert_eq(resumed.checkpoint().analysis.windows.runs.states.length(), 1)
  let candidate = branch.prepare(3L, landmarks(), [pixel(1, 0.5, x=0.5)])
  let inspected = candidate.preview()
  inspected.measurement.motion.tracks.clear()
  assert_eq(candidate.preview().measurement.motion.tracks.length(), 1)
  ignore(candidate.commit(@zones.FootprintAssignments::new(3L, [])))
  assert_eq(branch.checkpoint().analysis.windows.runs.states.length(), 0)
  assert_eq(
    owner.checkpoint().analysis.windows.runs.last_timestamp_us,
    Some(2L),
  )
}
