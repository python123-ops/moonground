///|
fn footprint_run_checkpoint_observations() -> Array[@types.GroundObservation] raise @types.GroundError {
  [
    @types.GroundObservation::new(
      1,
      { x: 0.5, y: 0.5, },
      @types.Covariance2::isotropic(0.1),
    ),
  ]
}

///|
fn footprint_run_checkpoint_session(
  two~ : Bool = false,
) -> @analysis.FootprintRunSession raise @types.GroundError {
  let vertices : Array[@types.Point2] = [
    { x: -10.0, y: -10.0, },
    { x: 10.0, y: -10.0, },
    { x: 10.0, y: 10.0, },
    { x: -10.0, y: 10.0, },
  ]
  let zones = if two {
    [
      @zones.ConvexZone::new("one", vertices),
      @zones.ConvexZone::new("two", vertices),
    ]
  } else {
    [@zones.ConvexZone::new("one", vertices)]
  }
  let session = @analysis.FootprintRunSession::from_ground(
    @motion.MotionEstimator::new(
      "joint-run-cp",
      @motion.MotionConfig::new(min_observations=2, min_span_us=0L),
    ),
    @zones.FootprintRunMonitor::new(
      "joint-run-cp",
      zones,
      @zones.FootprintRunConfig::new(min_samples=1L, confirmation_us=0L),
    ),
  )
  for t in [0L, 100000L, 200000L] {
    let candidate = session.prepare_ground(
      t,
      footprint_run_checkpoint_observations(),
    )
    let frame = candidate.measurement().motion
    let bundle = @zones.FootprintAssignments::new(t, [
      @zones.FootprintAssignment::new(
        1,
        frame.tracks[0].segment_id,
        @zones.Disk(@zones.DiskFootprint::new(0.125)),
      ),
    ])
    ignore(candidate.commit(bundle))
  }
  session
}

///|
fn footprint_run_checkpoint_bad(
  saved : @analysis.FootprintRunSessionCheckpoint,
) -> Unit raise {
  try @analysis.FootprintRunSession::from_checkpoint(saved) catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("impossible joint run checkpoint accepted")
  }
}

///|
test "joint footprint runs bind exact component session and Option watermark" {
  let saved = footprint_run_checkpoint_session().checkpoint()
  footprint_run_checkpoint_bad({ ..saved, version: 2, })
  footprint_run_checkpoint_bad({
    ..saved,
    runs: { ..saved.runs, session_id: "other", },
  })
  footprint_run_checkpoint_bad({
    ..saved,
    runs: { ..saved.runs, last_timestamp_us: Some(200001L), },
  })
}

///|
test "joint footprint run current position must equal actual motion last filtered point" {
  let saved = footprint_run_checkpoint_session().checkpoint()
  let state = saved.runs.states[0]
  saved.runs.states[0] = { ..state, last_position_m: { x: 0.6, y: 0.5, }, }
  ignore(@zones.FootprintRunMonitor::from_checkpoint(saved.runs))
  footprint_run_checkpoint_bad(saved)
}

///|
test "joint footprint runs bind upper P block exactly instead of tolerated scalar change" {
  let saved = footprint_run_checkpoint_session().checkpoint()
  let state = saved.runs.states[0]
  saved.runs.states[0] = {
    ..state,
    last_position_covariance: {
      ..state.last_position_covariance,
      xx: state.last_position_covariance.xx + 1.0e-6,
    },
  }
  ignore(@zones.FootprintRunMonitor::from_checkpoint(saved.runs))
  footprint_run_checkpoint_bad(saved)
}

///|
test "joint footprint run cannot attach an accepted historical hidden motion track" {
  let saved = footprint_run_checkpoint_session().checkpoint()
  guard saved.measurement is @analysis.Ground(motion) else {
    fail("ground fixture missing")
  }
  motion.tracks[0] = { ..motion.tracks[0], last_timestamp_us: 100000L, }
  ignore(@motion.MotionEstimator::from_checkpoint(motion))
  footprint_run_checkpoint_bad({
    ..saved,
    measurement: @analysis.Ground(motion),
  })
}

///|
test "joint footprint run requires current warmup and both scalar quality criteria" {
  for change in 0..<3 {
    let saved = footprint_run_checkpoint_session().checkpoint()
    guard saved.measurement is @analysis.Ground(motion) else {
      fail("ground fixture missing")
    }
    let config = match change {
      0 => @motion.MotionConfig::new(min_observations=4, min_span_us=0L)
      1 =>
        @motion.MotionConfig::new(
          min_observations=2,
          min_span_us=0L,
          max_position_std_m=1.0e-9,
        )
      _ =>
        @motion.MotionConfig::new(
          min_observations=2,
          min_span_us=0L,
          max_velocity_std_mps=1.0e-9,
        )
    }
    footprint_run_checkpoint_bad({
      ..saved,
      measurement: @analysis.Ground({ ..motion, config, }),
    })
  }
}

///|
test "joint footprint run first sample cannot predate earliest Ready warmup" {
  let saved = footprint_run_checkpoint_session().checkpoint()
  let state = saved.runs.states[0]
  saved.runs.states[0] = {
    ..state,
    run: { ..state.run, first_timestamp_us: 0L, sample_span_us: 200000L, },
  }
  ignore(@zones.FootprintRunMonitor::from_checkpoint(saved.runs))
  footprint_run_checkpoint_bad(saved)
}

///|
test "joint footprint run samples reserve accepted observations for warmup" {
  let saved = footprint_run_checkpoint_session().checkpoint()
  let state = saved.runs.states[0]
  saved.runs.states[0] = { ..state, run: { ..state.run, sample_count: 3L, }, }
  ignore(@zones.FootprintRunMonitor::from_checkpoint(saved.runs))
  footprint_run_checkpoint_bad(saved)
}

///|
test "joint footprint runs merge distinct per zone first times in accepted witness budget" {
  let saved = footprint_run_checkpoint_session(two=true).checkpoint()
  let state = saved.runs.states[1]
  saved.runs.states[1] = {
    ..state,
    run: { ..state.run, first_timestamp_us: 150000L, sample_span_us: 50000L, },
  }
  ignore(@zones.FootprintRunMonitor::from_checkpoint(saved.runs))
  footprint_run_checkpoint_bad(saved)
  guard saved.measurement is @analysis.Ground(motion) else {
    fail("ground fixture missing")
  }
  motion.tracks[0] = { ..motion.tracks[0], accepted_count: 4, }
  footprint_run_checkpoint_bad({
    ..saved,
    measurement: @analysis.Ground(motion),
  })
  let first = saved.runs.states[0]
  saved.runs.states[0] = { ..first, run: { ..first.run, sample_count: 3L, }, }
  ignore(
    @analysis.FootprintRunSession::from_checkpoint({
      ..saved,
      measurement: @analysis.Ground(motion),
    }),
  )
}

///|
test "joint current Ready may have no run when the explicit footprint is absent" {
  let session = footprint_run_checkpoint_session()
  let candidate = session.prepare_ground(
    300000L,
    footprint_run_checkpoint_observations(),
  )
  let output = candidate.commit(@zones.FootprintAssignments::new(300000L, []))
  assert_eq(output.runs.active.length(), 0)
  assert_eq(output.runs.evidence.unavailable[0].reason, @zones.MissingFootprint)
  ignore(@analysis.FootprintRunSession::from_checkpoint(session.checkpoint()))
}

///|
test "joint checkpoint exports and forked run states detach from source arrays" {
  let session = footprint_run_checkpoint_session(two=true)
  let saved = session.checkpoint()
  let restored = @analysis.FootprintRunSession::from_checkpoint(saved)
  let branch = session.fork()
  saved.runs.states.clear()
  assert_eq(session.checkpoint().runs.states.length(), 2)
  assert_eq(restored.checkpoint().runs.states.length(), 2)
  let candidate = branch.prepare_ground(
    300000L,
    footprint_run_checkpoint_observations(),
  )
  ignore(candidate.commit(@zones.FootprintAssignments::new(300000L, [])))
  assert_eq(branch.checkpoint().runs.states.length(), 0)
  assert_eq(session.checkpoint().runs.states.length(), 2)
}
