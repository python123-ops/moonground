///|
fn run_checkpoint_frame(
  time : Int64,
  x~ : Double = 0.5,
) -> @motion.FrameResult raise @types.GroundError {
  let original = ready_frame()
  {
    ..original,
    timestamp_us: time,
    tracks: [
      {
        ..original.tracks[0],
        position: Some({ x, y: 0.5, }),
        position_covariance: Some(@types.Covariance2::isotropic(0.1)),
        last_accepted_timestamp_us: time,
      },
    ],
  }
}

///|
fn run_checkpoint_bundle(
  frame : @motion.FrameResult,
) -> @zones.FootprintAssignments raise @types.GroundError {
  @zones.FootprintAssignments::new(frame.timestamp_us, [
    @zones.FootprintAssignment::new(
      1,
      frame.tracks[0].segment_id,
      @zones.Disk(@zones.DiskFootprint::new(0.125)),
    ),
  ])
}

///|
fn run_checkpoint_seed(
  two~ : Bool = false,
) -> @zones.FootprintRunCheckpoint raise @types.GroundError {
  let zones = if two {
    [square(id="one"), square(id="two")]
  } else {
    [square()]
  }
  let monitor = @zones.FootprintRunMonitor::new(
    "zones",
    zones,
    @zones.FootprintRunConfig::new(
      max_gap_us=10L,
      confirmation_us=1L,
      min_samples=2L,
    ),
  )
  for t in [0L, 1L] {
    let frame = run_checkpoint_frame(t)
    ignore(monitor.update(frame, run_checkpoint_bundle(frame)))
  }
  monitor.checkpoint()
}

///|
fn run_checkpoint_invalid(saved : @zones.FootprintRunCheckpoint) -> Unit raise {
  try @zones.FootprintRunMonitor::from_checkpoint(saved) catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("inconsistent footprint run checkpoint accepted")
  }
}

///|
test "run checkpoint rejects unsupported version and state without a current watermark" {
  let good = run_checkpoint_seed()
  run_checkpoint_invalid({ ..good, version: 2, })
  run_checkpoint_invalid({ ..good, last_timestamp_us: None, })
  run_checkpoint_invalid({ ..good, session_id: "", })
  run_checkpoint_invalid({ ..good, max_tracks: 0, })
}

///|
test "run checkpoint requires current anchor timestamp exact span and ordered positive samples" {
  for change in 0..<5 {
    let saved = run_checkpoint_seed()
    let state = saved.states[0]
    let run = match change {
      0 => { ..state.run, last_timestamp_us: 0L, }
      1 => { ..state.run, sample_span_us: 2L, }
      2 => { ..state.run, first_timestamp_us: 2L, }
      3 => { ..state.run, sample_count: 0L, }
      _ => { ..state.run, sample_count: 3L, }
    }
    saved.states[0] = { ..state, run, }
    run_checkpoint_invalid(saved)
  }
}

///|
test "run checkpoint validates maximum gap feasibility with exact unsaturated sample count" {
  let saved = run_checkpoint_seed()
  let state = saved.states[0]
  saved.states[0] = {
    ..state,
    run: {
      ..state.run,
      first_timestamp_us: 0L,
      last_timestamp_us: 10L,
      sample_span_us: 10L,
    },
  }
  run_checkpoint_invalid({ ..saved, last_timestamp_us: Some(10L), })
}

///|
test "run checkpoint recomputes qualification and rejects indeterminate stored decisions" {
  let saved = run_checkpoint_seed()
  let state = saved.states[0]
  saved.states[0] = { ..state, run: { ..state.run, confirmed: false, }, }
  run_checkpoint_invalid(saved)
  let saved = run_checkpoint_seed()
  let state = saved.states[0]
  saved.states[0] = {
    ..state,
    run: { ..state.run, decision: @zones.Indeterminate, },
  }
  run_checkpoint_invalid(saved)
}

///|
test "run checkpoint rescoring rejects incompatible point covariance or physical shape" {
  for change in 0..<3 {
    let saved = run_checkpoint_seed()
    let state = saved.states[0]
    saved.states[0] = match change {
      0 => { ..state, last_position_m: { x: 2.0, y: 0.5, }, }
      1 =>
        { ..state, last_position_covariance: { xx: 1.0, xy: 2.0, yy: 1.0, }, }
      _ => { ..state, shape: @zones.Disk(@zones.DiskFootprint::new(1.0)), }
    }
    run_checkpoint_invalid(saved)
  }
}

///|
test "run checkpoint rejects duplicate unknown zones and incomplete definite zone sets" {
  let saved = run_checkpoint_seed(two=true)
  saved.states.push(saved.states[0])
  run_checkpoint_invalid(saved)
  let saved = run_checkpoint_seed()
  let state = saved.states[0]
  saved.states[0] = { ..state, run: { ..state.run, zone_id: "unknown", }, }
  run_checkpoint_invalid(saved)
  let saved = run_checkpoint_seed(two=true)
  ignore(saved.states.pop())
  run_checkpoint_invalid(saved)
}

///|
test "run checkpoint requires one segment point covariance and shape per target across zones" {
  for change in 0..<4 {
    let saved = run_checkpoint_seed(two=true)
    let state = saved.states[1]
    saved.states[1] = match change {
      0 => { ..state, run: { ..state.run, segment_id: "2", }, }
      1 => { ..state, last_position_m: { x: 0.6, y: 0.5, }, }
      2 =>
        {
          ..state,
          last_position_covariance: @types.Covariance2::isotropic(0.2),
        }
      _ => { ..state, shape: @zones.Disk(@zones.DiskFootprint::new(0.25)), }
    }
    run_checkpoint_invalid(saved)
  }
}

///|
test "run checkpoint arrays fork and returned results are detached" {
  let saved = run_checkpoint_seed(two=true)
  let monitor = @zones.FootprintRunMonitor::from_checkpoint(saved)
  let branch = monitor.fork()
  saved.states.clear()
  let exported = monitor.checkpoint()
  exported.states.clear()
  assert_eq(monitor.checkpoint().states.length(), 2)
  assert_eq(branch.checkpoint().states.length(), 2)
  let frame = run_checkpoint_frame(2L)
  let output = branch.update(frame, run_checkpoint_bundle(frame))
  output.active.clear()
  assert_eq(branch.checkpoint().states.length(), 2)
  assert_eq(monitor.checkpoint().last_timestamp_us, Some(1L))
}

///|
test "run sample Int64 overflow rolls back and a same time decision change succeeds" {
  let saved = run_checkpoint_seed()
  let state = saved.states[0]
  saved.states[0] = {
    ..state,
    run: {
      ..state.run,
      first_timestamp_us: 0L,
      last_timestamp_us: 9223372036854775806L,
      sample_span_us: 9223372036854775806L,
      sample_count: 9223372036854775807L,
      confirmed: true,
    },
  }
  let monitor = @zones.FootprintRunMonitor::from_checkpoint({
    ..saved,
    config: @zones.FootprintRunConfig::new(
      max_gap_us=2L,
      confirmation_us=0L,
      min_samples=1L,
    ),
    last_timestamp_us: Some(9223372036854775806L),
  })
  let frame = run_checkpoint_frame(9223372036854775807L)
  try monitor.update(frame, run_checkpoint_bundle(frame)) catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("sample counter wrapped")
  }
  assert_eq(monitor.checkpoint().last_timestamp_us, Some(9223372036854775806L))
  assert_eq(
    monitor.checkpoint().states[0].run.sample_count,
    9223372036854775807L,
  )
  let corrected = run_checkpoint_frame(9223372036854775807L, x=2.0)
  let output = monitor.update(corrected, run_checkpoint_bundle(corrected))
  assert_eq(output.closed[0].reason, @zones.DecisionChanged)
  assert_eq(output.active[0].sample_count, 1L)
}

///|
test "single sample run has zero span and maximum gap one cannot connect two samples" {
  let saved = run_checkpoint_seed()
  let state = saved.states[0]
  saved.states[0] = {
    ..state,
    run: { ..state.run, first_timestamp_us: 0L, sample_count: 1L, },
  }
  run_checkpoint_invalid(saved)
  let saved = run_checkpoint_seed()
  run_checkpoint_invalid({
    ..saved,
    config: @zones.FootprintRunConfig::new(
      max_gap_us=1L,
      confirmation_us=1L,
      min_samples=2L,
    ),
  })
}
