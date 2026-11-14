///|
fn footprint_guard_cp_owner(
  dense~ : Bool = false,
) -> @guarded.FootprintRunGuardedSession raise @types.GroundError {
  let old = @analysis.FootprintRunSession::from_pixel(
    @moonground.MeasurementSession::new(
      "guarded",
      calibration(),
      @moonground.MotionConfig::new(
        max_tracks=10,
        min_observations=2,
        min_span_us=0L,
        max_gap_us=1000000L,
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
        max_gap_us=1000000L,
        min_samples=1L,
        confirmation_us=0L,
      ),
      max_tracks=10,
    ),
  )
  let owner = @guarded.FootprintRunGuardedSession::new(
    old,
    monitor(
      config=@health.HealthConfig::new(
        min_observations=1,
        confirmation_us=0L,
        max_gap_us=500000L,
      ),
    ),
  )
  let times = if dense { [0L, 2L, 5L] } else { [0L, 100000L, 200000L] }
  for time in times {
    let prepared = owner.prepare(time, landmarks(), [pixel(1, 0.5, x=0.5)])
    let frame = prepared.preview().measurement.motion
    ignore(
      prepared.commit(
        @zones.FootprintAssignments::new(
          time,
          frame.tracks.map(track => {
            @zones.FootprintAssignment::new(
              track.track_id,
              track.segment_id,
              @zones.Disk(@zones.DiskFootprint::new(0.125)),
            )
          }),
        ),
      ),
    )
  }
  owner
}

///|
fn footprint_guard_cp_bad(
  saved : @guarded.FootprintRunGuardedCheckpoint,
) -> Unit raise {
  try @guarded.FootprintRunGuardedSession::from_checkpoint(saved) catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("impossible footprint guard checkpoint accepted")
  }
}

///|
test "footprint guard binds exact Option watermark and checkpoint version" {
  let saved = footprint_guard_cp_owner().checkpoint()
  footprint_guard_cp_bad({ ..saved, version: 2, })
  footprint_guard_cp_bad({
    ..saved,
    health: { ..saved.health, last_timestamp_us: Some(200001L), },
  })
}

///|
test "footprint guard rejects an otherwise valid ground joint owner" {
  let saved = footprint_guard_cp_owner().checkpoint()
  guard saved.analysis.measurement is @analysis.Pixel(pixel) else {
    fail("pixel fixture missing")
  }
  footprint_guard_cp_bad({
    ..saved,
    analysis: { ..saved.analysis, measurement: @analysis.Ground(pixel.motion), },
  })
}

///|
test "footprint guard binds calibration and Brown option exactly" {
  let saved = footprint_guard_cp_owner().checkpoint()
  let other = @moonground.GroundCalibration::from_homography(
    [2.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    [
      { x: -10.0, y: -10.0, },
      { x: 10.0, y: -10.0, },
      { x: 10.0, y: 10.0, },
      { x: -10.0, y: 10.0, },
    ],
    max_meters_per_pixel=3.0,
  )
  footprint_guard_cp_bad({
    ..saved,
    health: { ..saved.health, calibration: other, },
  })
  let camera = @moonground.CameraModel::new(fx=100.0, fy=100.0, cx=0.0, cy=0.0)
  footprint_guard_cp_bad({
    ..saved,
    health: { ..saved.health, camera: Some(camera), },
  })
}

///|
test "footprint guard capacity must support all motion hidden closures" {
  let saved = footprint_guard_cp_owner().checkpoint()
  let changed = {
    ..saved.analysis,
    runs: { ..saved.analysis.runs, max_tracks: 1, },
  }
  ignore(@analysis.FootprintRunSession::from_checkpoint(changed))
  footprint_guard_cp_bad({ ..saved, analysis: changed, })
}

///|
test "footprint guard nonHealthy health cannot retain Ready filters or runs" {
  let saved = footprint_guard_cp_owner().checkpoint()
  let health = { ..saved.health, streak: None, }
  ignore(@health.CalibrationMonitor::from_checkpoint(health))
  footprint_guard_cp_bad({ ..saved, health, })
}

///|
test "footprint guard ordinary health confirmation cannot postdate its segment" {
  let saved = footprint_guard_cp_owner().checkpoint()
  guard saved.health.streak is Some(streak) else {
    fail("health streak missing")
  }
  let config = @health.HealthConfig::new(
    min_observations=2,
    confirmation_us=1L,
    max_gap_us=500000L,
  )
  let health = {
    ..saved.health,
    config,
    streak: Some({ ..streak, since_us: 100000L, observations: 2, }),
  }
  ignore(@health.CalibrationMonitor::from_checkpoint(health))
  footprint_guard_cp_bad({ ..saved, health, })
}

///|
test "footprint run crossing instant health restart needs a larger run gap" {
  let saved = footprint_guard_cp_owner(dense=true).checkpoint()
  guard saved.health.streak is Some(streak) else {
    fail("health streak missing")
  }
  let health = {
    ..saved.health,
    config: @health.HealthConfig::new(
      min_observations=1,
      confirmation_us=0L,
      max_gap_us=2L,
    ),
    streak: Some({ ..streak, since_us: 5L, }),
  }
  guard saved.analysis.measurement is @analysis.Pixel(pixel) else {
    fail("pixel fixture missing")
  }
  pixel.motion.tracks[0] = { ..pixel.motion.tracks[0], accepted_count: 4, }
  let analysis = { ..saved.analysis, measurement: @analysis.Pixel(pixel), }
  let run = analysis.runs.states[0]
  analysis.runs.states[0] = {
    ..run,
    run: {
      ..run.run,
      first_timestamp_us: 3L,
      sample_span_us: 2L,
      sample_count: 3L,
    },
  }
  let runs = {
    ..analysis.runs,
    config: @zones.FootprintRunConfig::new(
      max_gap_us=2L,
      min_samples=1L,
      confirmation_us=0L,
    ),
  }
  // Each historical component is self-consistent; the guard restart makes their join impossible.
  ignore(@zones.FootprintRunMonitor::from_checkpoint(runs))
  footprint_guard_cp_bad({ ..saved, analysis: { ..analysis, runs, }, health, })
}

///|
test "footprint guard forbids counting unseen samples inside instant restart gap" {
  let saved = footprint_guard_cp_owner(dense=true).checkpoint()
  guard saved.analysis.measurement is @analysis.Pixel(pixel) else {
    fail("pixel fixture missing")
  }
  pixel.motion.tracks[0] = { ..pixel.motion.tracks[0], accepted_count: 5, }
  let state = saved.analysis.runs.states[0]
  saved.analysis.runs.states[0] = {
    ..state,
    run: { ..state.run, sample_count: 4L, },
  }
  guard saved.health.streak is Some(streak) else {
    fail("health streak missing")
  }
  let health = {
    ..saved.health,
    config: @health.HealthConfig::new(
      min_observations=1,
      confirmation_us=0L,
      max_gap_us=2L,
    ),
    streak: Some({ ..streak, since_us: 5L, }),
  }
  let analysis = { ..saved.analysis, measurement: @analysis.Pixel(pixel), }
  ignore(@analysis.FootprintRunSession::from_checkpoint(analysis))
  footprint_guard_cp_bad({ ..saved, analysis, health, })
}

///|
test "footprint guard health since adds target specific accepted witness and suffix budget" {
  let saved = footprint_guard_cp_owner(dense=true).checkpoint()
  guard saved.health.streak is Some(streak) else {
    fail("health streak missing")
  }
  let health = {
    ..saved.health,
    config: @health.HealthConfig::new(
      min_observations=1,
      confirmation_us=0L,
      max_gap_us=2L,
    ),
    streak: Some({ ..streak, since_us: 4L, }),
  }
  footprint_guard_cp_bad({ ..saved, health, })
  guard saved.analysis.measurement is @analysis.Pixel(pixel) else {
    fail("pixel fixture missing")
  }
  pixel.motion.tracks[0] = { ..pixel.motion.tracks[0], accepted_count: 4, }
  footprint_guard_cp_bad({
    ..saved,
    analysis: { ..saved.analysis, measurement: @analysis.Pixel(pixel), },
    health,
  })
  let state = saved.analysis.runs.states[0]
  saved.analysis.runs.states[0] = {
    ..state,
    run: { ..state.run, sample_count: 3L, },
  }
  ignore(
    @guarded.FootprintRunGuardedSession::from_checkpoint({
      ..saved,
      analysis: { ..saved.analysis, measurement: @analysis.Pixel(pixel), },
      health,
    }),
  )
}

///|
test "footprint guarded checkpoint fork exports retain independent arrays" {
  let owner = footprint_guard_cp_owner()
  let saved = owner.checkpoint()
  let restored = @guarded.FootprintRunGuardedSession::from_checkpoint(saved)
  let forked = owner.fork()
  saved.analysis.runs.states.clear()
  assert_eq(owner.checkpoint().analysis.runs.states.length(), 1)
  assert_eq(restored.checkpoint().analysis.runs.states.length(), 1)
  ignore(forked.replace_projection(300000L, calibration(), camera=None))
  assert_eq(forked.checkpoint().analysis.runs.states.length(), 0)
  assert_eq(owner.checkpoint().analysis.runs.states.length(), 1)
}
