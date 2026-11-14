///|
fn run_sample(
  timestamp : Int64,
  x~ : Double = 0.5,
) -> @motion.FrameResult raise @types.GroundError {
  let frame = ready_frame()
  {
    ..frame,
    timestamp_us: timestamp,
    tracks: [
      {
        ..frame.tracks[0],
        position: Some({ x, y: 0.5, }),
        position_covariance: Some(@types.Covariance2::isotropic(0.1)),
        last_accepted_timestamp_us: timestamp,
      },
    ],
  }
}

///|
fn run_monitor(
  gap~ : Int64 = 100L,
  confirmation~ : Int64 = 2L,
  samples~ : Int64 = 3L,
) -> @zones.FootprintRunMonitor raise @types.GroundError {
  @zones.FootprintRunMonitor::new(
    "zones",
    [square()],
    @zones.FootprintRunConfig::new(
      max_gap_us=gap,
      confirmation_us=confirmation,
      min_samples=samples,
    ),
  )
}

///|
fn run_shapes(
  frame : @motion.FrameResult,
  radius~ : Double = 0.125,
) -> @zones.FootprintAssignments raise @types.GroundError {
  assigned_all(frame, @zones.Disk(@zones.DiskFootprint::new(radius)))
}

///|
fn run_snapshot(monitor : @zones.FootprintRunMonitor) -> String {
  let saved = monitor.checkpoint()
  @debug.to_string(
    (saved.last_timestamp_us, saved.states.map(state => state.run)),
  )
}

///|
test "run configuration validates exact positive counts and independent time thresholds" {
  let config = @zones.FootprintRunConfig::new()
  assert_eq(config.max_gap_us, 500000L)
  assert_eq(config.confirmation_us, 1000000L)
  assert_eq(config.min_samples, 2L)
  invalid(() => ignore(@zones.FootprintRunConfig::new(max_gap_us=0L)))
  invalid(() => ignore(@zones.FootprintRunConfig::new(confirmation_us=-1L)))
  invalid(() => ignore(@zones.FootprintRunConfig::new(min_samples=0L)))
  ignore(@zones.FootprintRunConfig::new(min_samples=9223372036854775807L))
}

///|
test "run confirmation requires both sample count and sampled span and emits once" {
  let monitor = run_monitor(confirmation=5L, samples=3L)
  for t in [0L, 1L, 2L] {
    let frame = run_sample(t)
    let result = monitor.update(frame, run_shapes(frame))
    assert_eq(result.confirmed.length(), 0)
    assert_eq(result.active[0].confirmed, false)
  }
  let frame = run_sample(5L)
  let result = monitor.update(frame, run_shapes(frame))
  assert_eq(result.confirmed.length(), 1)
  assert_eq(result.active[0].sample_count, 4L)
  assert_eq(result.active[0].sample_span_us, 5L)
  let frame = run_sample(6L)
  let result = monitor.update(frame, run_shapes(frame))
  assert_eq(result.confirmed.length(), 0)
  assert_eq(result.active[0].confirmed, true)
  assert_eq(result.active[0].first_timestamp_us, 0L)
}

///|
test "run first available sample can confirm at zero timestamp without a previous frame" {
  let monitor = run_monitor(confirmation=0L, samples=1L)
  let frame = run_sample(0L)
  let result = monitor.update(frame, run_shapes(frame))
  assert_eq(result.confirmed.length(), 1)
  assert_eq(result.active[0].sample_span_us, 0L)
  assert_eq(result.active[0].sample_count, 1L)
  assert_eq(result.closed.length(), 0)
}

///|
test "run indeterminate breaks evidence and a subsequent Outside begins independently" {
  let monitor = run_monitor()
  let frame = run_sample(0L)
  ignore(monitor.update(frame, run_shapes(frame)))
  let frame = run_sample(1L, x=1.0)
  let result = monitor.update(frame, run_shapes(frame))
  assert_eq(result.active.length(), 0)
  assert_eq(result.closed[0].reason, @zones.IndeterminateEvidence)
  assert_eq(result.closed[0].run.last_timestamp_us, 0L)
  assert_eq(result.closed[0].closed_at_timestamp_us, 1L)
  let frame = run_sample(2L, x=2.0)
  let result = monitor.update(frame, run_shapes(frame))
  assert_eq(result.active[0].decision, @zones.Outside)
  assert_eq(result.active[0].first_timestamp_us, 2L)
  assert_eq(result.active[0].sample_count, 1L)
}

///|
test "run maximum gap is inclusive and a gap of one cannot connect distinct microseconds" {
  for gap in [1L, 10L] {
    let monitor = run_monitor(gap~)
    let frame = run_sample(0L)
    ignore(monitor.update(frame, run_shapes(frame)))
    let frame = run_sample(gap)
    let result = monitor.update(frame, run_shapes(frame))
    assert_eq(result.closed[0].reason, @zones.GapExceeded)
    assert_eq(result.active[0].first_timestamp_us, gap)
    assert_eq(result.active[0].sample_count, 1L)
  }
}

///|
test "run explicit closed segment precedes an accepted replacement and legal rejected row" {
  for rejected in [false, true] {
    let monitor = run_monitor()
    let frame = run_sample(0L)
    ignore(monitor.update(frame, run_shapes(frame)))
    let old_segment = frame.tracks[0].segment_id
    let next = run_sample(1L)
    let track = if rejected {
      { ..next.tracks[0], status: @motion.RejectedInnovation, }
    } else {
      { ..next.tracks[0], segment_id: "2", }
    }
    let next = { ..next, tracks: [track], closed_segment_ids: [old_segment], }
    let result = monitor.update(next, run_shapes(next))
    assert_eq(result.closed[0].reason, @zones.SegmentClosed)
    assert_eq(result.active.length(), if rejected { 0 } else { 1 })
  }
}

///|
test "run changing segment without an explicit closure never extends the previous sequence" {
  let monitor = run_monitor()
  let frame = run_sample(0L)
  ignore(monitor.update(frame, run_shapes(frame)))
  let frame = run_sample(1L)
  let frame = { ..frame, tracks: [{ ..frame.tracks[0], segment_id: "2", }], }
  let result = monitor.update(frame, run_shapes(frame))
  assert_eq(result.closed[0].reason, @zones.SegmentChanged)
  assert_eq(result.active[0].segment_id, "2")
  assert_eq(result.active[0].sample_count, 1L)
}

///|
test "run absent target ends MissingTarget and does not retain an occupancy count" {
  let monitor = run_monitor()
  let frame = run_sample(0L)
  ignore(monitor.update(frame, run_shapes(frame)))
  let absent = { ..frame, timestamp_us: 1L, tracks: [], }
  let result = monitor.update(absent, run_shapes(absent))
  assert_eq(result.closed[0].reason, @zones.MissingTarget)
  assert_eq(result.active.length(), 0)
  assert_eq(monitor.checkpoint().states.length(), 0)
  assert_eq(monitor.checkpoint().last_timestamp_us, Some(1L))
}

///|
test "run every unavailable motion status interrupts even with a matching large shape" {
  for
    status in [
      @motion.Initializing,
      @motion.Uncertain,
      @motion.RejectedInnovation,
      @motion.NumericalFailure,
    ] {
    let monitor = run_monitor()
    let frame = run_sample(0L)
    ignore(monitor.update(frame, run_shapes(frame)))
    let frame = run_sample(1L)
    let frame = { ..frame, tracks: [{ ..frame.tracks[0], status, }], }
    let result = monitor.update(frame, run_shapes(frame, radius=1.0e308))
    assert_eq(result.closed[0].reason, @zones.UnavailableEvidence)
    assert_eq(result.active.length(), 0)
    assert_eq(result.evidence.unavailable.length(), 1)
  }
}

///|
test "run missing footprint interrupts and never reuses an earlier explicit assignment" {
  let monitor = run_monitor()
  let frame = run_sample(0L)
  ignore(monitor.update(frame, run_shapes(frame)))
  let frame = run_sample(1L)
  let result = monitor.update(frame, @zones.FootprintAssignments::new(1L, []))
  assert_eq(result.closed[0].reason, @zones.UnavailableEvidence)
  assert_eq(result.evidence.unavailable[0].reason, @zones.MissingFootprint)
  let frame = run_sample(2L)
  let result = monitor.update(frame, run_shapes(frame))
  assert_eq(result.active[0].first_timestamp_us, 2L)
}

///|
test "run changed shape kind radius or ordered convex vertices interrupts before classification" {
  let small = footprint_box(0.125)
  let vertices = small.vertices_offset_m()
  let rotated = @zones.ConvexFootprint::new([
    vertices[1],
    vertices[2],
    vertices[3],
    vertices[0],
  ])
  let shapes : Array[(@zones.FootprintShape, @zones.FootprintShape)] = [
    (
      @zones.Disk(@zones.DiskFootprint::new(0.125)),
      @zones.Disk(@zones.DiskFootprint::new(0.25)),
    ),
    (@zones.Disk(@zones.DiskFootprint::new(0.125)), @zones.Convex(small)),
    (@zones.Convex(small), @zones.Convex(rotated)),
  ]
  for (first, second) in shapes {
    let monitor = run_monitor()
    let frame = run_sample(0L)
    ignore(monitor.update(frame, assigned_all(frame, first)))
    let frame = run_sample(1L)
    let result = monitor.update(frame, assigned_all(frame, second))
    assert_eq(result.closed[0].reason, @zones.ShapeChanged)
    assert_eq(result.active[0].sample_count, 1L)
  }
}

///|
test "run equal freshly constructed shapes and signed zero radius preserve the sequence" {
  for convex in [false, true] {
    let monitor = run_monitor()
    for t in [0L, 1L] {
      let frame = run_sample(t)
      let shape : @zones.FootprintShape = if convex {
        @zones.Convex(footprint_box(0.125))
      } else {
        @zones.Disk(@zones.DiskFootprint::new(if t == 0L { 0.0 } else { -0.0 }))
      }
      let result = monitor.update(frame, assigned_all(frame, shape))
      assert_eq(result.closed.length(), 0)
      assert_eq(result.active[0].sample_count, t + 1L)
    }
  }
}

///|
test "run closure priorities choose gap then explicit segment closure over target absence" {
  for gap in [false, true] {
    let monitor = run_monitor(gap=2L)
    let frame = run_sample(0L)
    ignore(monitor.update(frame, run_shapes(frame)))
    let frame = {
      ..frame,
      timestamp_us: if gap {
        2L
      } else {
        1L
      },
      tracks: [],
      closed_segment_ids: [frame.tracks[0].segment_id],
    }
    let result = monitor.update(frame, run_shapes(frame))
    assert_eq(
      result.closed[0].reason,
      if gap {
        @zones.GapExceeded
      } else {
        @zones.SegmentClosed
      },
    )
  }
}

///|
test "run output orders numeric tracks then configured zones for active confirmed and closed" {
  let monitor = @zones.FootprintRunMonitor::new(
    "zones",
    [square(id="z"), square(id="a")],
    @zones.FootprintRunConfig::new(min_samples=1L, confirmation_us=0L),
  )
  let source = run_sample(0L)
  let track = source.tracks[0]
  let frame = {
    ..source,
    tracks: [
      { ..track, track_id: 9, segment_id: "9", },
      { ..track, track_id: 2, segment_id: "2", },
    ],
  }
  let result = monitor.update(frame, run_shapes(frame))
  assert_eq(result.active.map(run => run.track_id), [2, 2, 9, 9])
  assert_eq(result.confirmed.map(run => run.zone_id), ["z", "a", "z", "a"])
  let absent = { ..frame, timestamp_us: 1L, tracks: [], }
  let result = monitor.update(absent, run_shapes(absent))
  assert_eq(result.closed.map(row => row.run.track_id), [2, 2, 9, 9])
  assert_eq(result.closed.map(row => row.run.zone_id), ["z", "a", "z", "a"])
}

///|
test "run evidence equals the original assigned projector without a second interpretation" {
  let monitor = run_monitor()
  let frame = run_sample(0L)
  let shapes = run_shapes(frame)
  let expected = projector().evaluate_assigned(frame, shapes)
  assert_eq(
    @debug.to_string(monitor.update(frame, shapes).evidence),
    @debug.to_string(expected),
  )
}

///|
test "run invalid timestamp or bundle preserves state and permits corrected same time retry" {
  let monitor = run_monitor()
  let frame = run_sample(0L)
  ignore(monitor.update(frame, run_shapes(frame)))
  let before = run_snapshot(monitor)
  invalid(() => ignore(monitor.update(frame, run_shapes(frame))))
  assert_eq(run_snapshot(monitor), before)
  let frame = run_sample(1L)
  invalid(() => {
    ignore(monitor.update(frame, @zones.FootprintAssignments::new(2L, [])))
  })
  assert_eq(run_snapshot(monitor), before)
  assert_eq(monitor.update(frame, run_shapes(frame)).active[0].sample_count, 2L)
}

///|
test "run all Ready numerical validation occurs before any candidate state is committed" {
  let monitor = run_monitor()
  let frame = run_sample(0L)
  ignore(monitor.update(frame, run_shapes(frame)))
  let before = run_snapshot(monitor)
  let frame = run_sample(1L)
  let bad = {
    ..frame,
    tracks: [
      frame.tracks[0],
      {
        ..frame.tracks[0],
        track_id: 2,
        segment_id: "2",
        position_covariance: Some({ xx: 1.0, xy: 2.0, yy: 1.0, }),
      },
    ],
  }
  invalid(() => ignore(monitor.update(bad, run_shapes(bad))))
  assert_eq(run_snapshot(monitor), before)
  let result = monitor.update(frame, run_shapes(frame))
  assert_eq(result.active[0].sample_count, 2L)
}

///|
test "run exact clocks retain adjacent microseconds above two to the fifty third and at Int64 maximum" {
  for first in [9007199254740992L, 9223372036854775805L] {
    let monitor = run_monitor()
    for dt in [0L, 1L, 2L] {
      let frame = run_sample(first + dt)
      let result = monitor.update(frame, run_shapes(frame))
      assert_eq(result.active[0].sample_span_us, dt)
      assert_eq(result.active[0].sample_count, dt + 1L)
      assert_eq(result.active[0].confirmed, dt == 2L)
    }
    ignore(@zones.FootprintRunMonitor::from_checkpoint(monitor.checkpoint()))
  }
}

///|
test "run restore enforces target capacity even when each target has an indeterminate second zone" {
  let second = @zones.ConvexZone::new(
    "second",
    [
      { x: 0.5, y: 0.0, },
      { x: 1.5, y: 0.0, },
      { x: 1.5, y: 1.0, },
      { x: 0.5, y: 1.0, },
    ],
    sigma_multiplier=0.0,
  )
  let monitor = @zones.FootprintRunMonitor::new(
    "zones",
    [square(), second],
    @zones.FootprintRunConfig::new(),
    max_tracks=2,
  )
  let frame = run_sample(0L)
  let frame = {
    ..frame,
    tracks: [
      frame.tracks[0],
      { ..frame.tracks[0], track_id: 2, segment_id: "2", },
    ],
  }
  ignore(monitor.update(frame, run_shapes(frame)))
  let saved = monitor.checkpoint()
  assert_eq(saved.states.length(), 2)
  invalid(() => {
    ignore(
      @zones.FootprintRunMonitor::from_checkpoint({ ..saved, max_tracks: 1, }),
    )
  })
  let duplicate_segment = {
    ..saved.states[1],
    run: { ..saved.states[1].run, segment_id: saved.states[0].run.segment_id, },
  }
  saved.states[1] = duplicate_segment
  invalid(() => ignore(@zones.FootprintRunMonitor::from_checkpoint(saved)))
}

///|
test "run bounded three state sequences match independent consecutive sample counting" {
  for pattern in 0..<81 {
    let monitor = run_monitor(confirmation=1L, samples=2L)
    let mut digits = pattern
    let mut previous = -1
    let mut count = 0L
    for time in 0..<4 {
      let decision = digits % 3
      digits /= 3
      let x = match decision {
        0 => 0.5
        1 => 2.0
        _ => 1.0
      }
      let frame = run_sample(time.to_int64(), x~)
      let result = monitor.update(frame, run_shapes(frame))
      let expected_closed = previous >= 0 &&
        (decision == 2 || decision != previous)
      assert_eq(result.closed.length(), if expected_closed { 1 } else { 0 })
      if decision == 2 {
        assert_eq(result.active.length(), 0)
        previous = -1
        count = 0L
      } else {
        count = if decision == previous { count + 1L } else { 1L }
        assert_eq(result.active[0].sample_count, count)
        assert_eq(result.active[0].sample_span_us, count - 1L)
        assert_eq(result.active[0].confirmed, count >= 2L)
        assert_eq(result.confirmed.length(), if count == 2L { 1 } else { 0 })
        previous = decision
      }
    }
  }
}
