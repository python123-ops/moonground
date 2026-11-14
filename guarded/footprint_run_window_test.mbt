///|
fn footprint_window_guard_fresh(
  instant~ : Bool = false,
  width~ : Int64 = 1000000L,
  origin~ : Int64 = 0L,
) -> @guarded.FootprintRunWindowGuardedSession raise @types.GroundError {
  @guarded.FootprintRunWindowGuardedSession::new(
    footprint_guard_fresh(instant~),
    window_us=width,
    origin_us=origin,
  )
}

///|
fn footprint_window_guard_step(
  owner : @guarded.FootprintRunWindowGuardedSession,
  timestamp : Int64,
  refs : Array[@health.LandmarkObservation],
  objects : Array[@moonground.PixelObservation],
) -> @guarded.FootprintRunWindowGuardedFrame raise @types.GroundError {
  let candidate = owner.prepare(timestamp, refs, objects)
  candidate.commit(footprint_guard_bundle(candidate.preview()))
}

///|
fn footprint_window_guard_pixel(
  saved : @guarded.FootprintRunWindowGuardedCheckpoint,
) -> @moonground.MeasurementCheckpoint raise {
  guard saved.analysis.measurement is @analysis.Pixel(pixel) else {
    fail("pixel footprint window checkpoint missing")
  }
  pixel
}

///|
fn footprint_window_guard_snapshot(
  owner : @guarded.FootprintRunWindowGuardedSession,
) -> String {
  let saved = owner.checkpoint()
  @debug.to_string(
    (
      saved.analysis.measurement,
      saved.health,
      saved.analysis.windows.window_us,
      saved.analysis.windows.origin_us,
      saved.analysis.windows.baseline_timestamp_us,
      saved.analysis.windows.current_window,
      saved.analysis.windows.runs.states.map(state => {
        (
          state.run,
          state.last_position_m,
          state.last_position_covariance,
          match state.shape {
            @zones.Disk(shape) => shape.radius_m.to_string()
            @zones.Convex(shape) => @debug.to_string(shape.vertices_offset_m())
          },
        )
      }),
    ),
  )
}

///|
test "guarded window preview stages health and one true blocked input without committing any stage" {
  let owner = footprint_window_guard_fresh()
  let before = footprint_window_guard_snapshot(owner)
  let prepared = owner.prepare(0L, landmarks(), [pixel(3, 0.5), pixel(1, 0.5)])
  let preview : @guarded.FootprintRunGuardedPreview = prepared.preview()
  assert_eq(preview.decision, @guarded.Blocked)
  assert_eq(preview.suppressed_track_ids, [1, 3])
  assert_eq(preview.measurement.motion.tracks.length(), 0)
  assert_eq(footprint_window_guard_snapshot(owner), before)
  let frame = prepared.commit(footprint_guard_bundle(preview))
  assert_eq(frame.analysis.windows.statistics.current_window.input_frames, 1L)
  assert_eq(
    frame.analysis.windows.statistics.current_window.zones[0].started,
    0L,
  )
  assert_eq(
    footprint_window_guard_pixel(owner.checkpoint()).motion.next_segment_id,
    1L,
  )
  let candidate = owner.prepare(100000L, landmarks(), [
    pixel(3, 0.5),
    pixel(1, 0.5),
  ])
  assert_eq(
    candidate.preview().measurement.motion.tracks.map(track => track.segment_id),
    ["1", "2"],
  )
  let frame = candidate.commit(footprint_guard_bundle(candidate.preview()))
  assert_eq(frame.decision, @guarded.Allowed)
  assert_eq(frame.analysis.windows.statistics.current_window.input_frames, 2L)
}

///|
test "first Healthy assignment failure preserves exact health count and candidate can commit at the same timestamp" {
  let owner = footprint_window_guard_fresh(width=100000L)
  ignore(footprint_window_guard_step(owner, 0L, landmarks(), [pixel(1, 0.5)]))
  let before = footprint_window_guard_snapshot(owner)
  let candidate = owner.prepare(100000L, landmarks(), [pixel(1, 0.5)])
  assert_eq(candidate.preview().health.status, @health.Healthy)
  let bad = @zones.FootprintAssignments::new(100000L, [
    @zones.FootprintAssignment::new(
      1,
      "9",
      @zones.Disk(@zones.DiskFootprint::new(0.125)),
    ),
  ])
  invalid(() => ignore(candidate.commit(bad)))
  assert_eq(footprint_window_guard_snapshot(owner), before)
  assert_eq(owner.checkpoint().health.streak.unwrap().observations, 1)
  let frame = candidate.commit(footprint_guard_bundle(candidate.preview()))
  assert_eq(frame.health.status, @health.Healthy)
  assert_eq(
    frame.analysis.windows.statistics.closed_window.unwrap().input_frames,
    1L,
  )
  assert_eq(frame.analysis.windows.statistics.current_window.input_frames, 1L)
}

///|
test "late footprint numeric error rolls back restarted health IDs and window rollover with retryable preparation" {
  let original = @guarded.FootprintRunGuardedSession::new(
    footprint_guard_analysis(),
    monitor(
      config=@health.HealthConfig::new(
        min_observations=1,
        confirmation_us=0L,
        max_gap_us=150000L,
      ),
    ),
  )
  let owner = @guarded.FootprintRunWindowGuardedSession::new(
    original,
    window_us=200000L,
  )
  for time in [0L, 100000L] {
    ignore(
      footprint_window_guard_step(owner, time, landmarks(), [pixel(1, 0.5)]),
    )
  }
  let before = footprint_window_guard_snapshot(owner)
  let prepared = owner.prepare(300000L, landmarks(), [
    pixel(1, 0.5),
    pixel(2, 0.5),
  ])
  assert_eq(prepared.preview().health.streak_since_us, Some(300000L))
  invalid(() => {
    ignore(
      prepared.commit(
        footprint_guard_bundle(prepared.preview(), radius=1.0e-300),
      ),
    )
  })
  assert_eq(footprint_window_guard_snapshot(owner), before)
  assert_eq(owner.checkpoint().health.streak.unwrap().since_us, 0L)
  let frame = prepared.commit(footprint_guard_bundle(prepared.preview()))
  assert_eq(frame.analysis.measurement.motion.tracks[1].segment_id, "2")
  assert_eq(frame.analysis.windows.statistics.current_window.input_frames, 1L)
  ignore(
    @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
      owner.checkpoint(),
    ),
  )
}

///|
test "blocked commit requires exact empty assignments and never projects suppressed raw pixels" {
  let owner = footprint_window_guard_fresh()
  let prepared = owner.prepare(0L, landmarks(), [pixel(1, 100.0, x=100.0)])
  let before = footprint_window_guard_snapshot(owner)
  invalid(() => {
    ignore(prepared.commit(@zones.FootprintAssignments::new(1L, [])))
  })
  invalid(() => {
    ignore(
      prepared.commit(
        @zones.FootprintAssignments::new(0L, [
          @zones.FootprintAssignment::new(
            1,
            "1",
            @zones.Disk(@zones.DiskFootprint::new(1.0e308)),
          ),
        ]),
      ),
    )
  })
  assert_eq(footprint_window_guard_snapshot(owner), before)
  let frame = prepared.commit(@zones.FootprintAssignments::new(0L, []))
  assert_eq(frame.analysis.measurement.projection_failures.length(), 0)
  assert_eq(frame.analysis.windows.runs.evidence.evidence.length(), 0)
  assert_eq(frame.analysis.windows.statistics.current_window.input_frames, 1L)
}

///|
test "blocked raw covariance IDs conflicts and fatal landmark inputs still reject without advancing windows" {
  let owner = footprint_window_guard_fresh()
  let before = footprint_window_guard_snapshot(owner)
  let raw = pixel(1, 0.5)
  for
    objects in [
      [raw, raw],
      [{ ..raw, covariance: { xx: 1.0, xy: 2.0, yy: 1.0, }, }],
      [{ ..raw, track_id: 0, }],
    ] {
    invalid(() => ignore(owner.prepare(0L, landmarks(), objects)))
  }
  invalid(() => ignore(owner.prepare(0L, landmarks(), [raw], lost=[1])))
  invalid(() => {
    ignore(owner.prepare(0L, [landmarks()[0], landmarks()[0]], [raw]))
  })
  assert_eq(footprint_window_guard_snapshot(owner), before)
}

///|
test "blocked input closes hidden segments and counts the existing confirmed run ending exactly once" {
  let owner = footprint_window_guard_fresh(instant=true)
  for time in [0L, 100000L] {
    ignore(
      footprint_window_guard_step(owner, time, landmarks(), [
        pixel(1, 0.5),
        pixel(2, 0.5),
      ]),
    )
  }
  ignore(
    footprint_window_guard_step(owner, 200000L, landmarks(), [pixel(1, 0.5)]),
  )
  let candidate = owner.prepare(300000L, [], [pixel(7, 100.0)])
  assert_eq(candidate.preview().measurement.motion.closed_segment_ids, [
    "1", "2",
  ])
  let frame = candidate.commit(footprint_guard_bundle(candidate.preview()))
  assert_eq(frame.suppressed_track_ids, [7])
  assert_eq(frame.analysis.windows.statistics.current_window.input_frames, 4L)
  assert_eq(
    frame.analysis.windows.statistics.current_window.zones[0].endings[1].confirmed,
    1L,
  )
  assert_eq(
    footprint_window_guard_pixel(owner.checkpoint()).motion.tracks.length(),
    0,
  )
  let next = footprint_window_guard_step(owner, 400000L, landmarks(), [
    pixel(1, 0.5),
  ])
  assert_eq(next.analysis.measurement.motion.tracks[0].segment_id, "3")
  assert_eq(next.analysis.windows.runs.active.length(), 0)
}

///|
test "Pending Drift Insufficient and recovery are genuine window frames with fresh object warmup" {
  let owner = footprint_window_guard_fresh()
  for time in [0L, 100000L, 200000L] {
    ignore(
      footprint_window_guard_step(owner, time, landmarks(), [pixel(1, 0.5)]),
    )
  }
  let changed = footprint_window_guard_step(
    owner,
    250000L,
    landmarks(shift=0.5),
    [pixel(1, 0.5)],
  )
  assert_eq(changed.health.status, @health.Pending)
  assert_eq(
    changed.analysis.windows.runs.closed[0].reason,
    @zones.SegmentClosed,
  )
  assert_eq(
    footprint_window_guard_step(owner, 350000L, landmarks(shift=0.5), []).health.status,
    @health.Drift,
  )
  ignore(footprint_window_guard_step(owner, 400000L, landmarks(), []))
  let recovered = footprint_window_guard_step(owner, 500000L, landmarks(), [
    pixel(1, 0.5),
  ])
  assert_eq(recovered.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(recovered.analysis.windows.runs.active.length(), 0)
  let absent = footprint_window_guard_step(owner, 600000L, [], [pixel(1, 0.5)])
  assert_eq(absent.health.status, @health.Insufficient)
  assert_eq(absent.analysis.windows.statistics.current_window.input_frames, 8L)
  ignore(
    @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
      owner.checkpoint(),
    ),
  )
}

///|
test "origin failure rolls back health and a replacement barrier before any statistics input" {
  let owner = footprint_window_guard_fresh(origin=100L)
  let before = footprint_window_guard_snapshot(owner)
  invalid(() => ignore(owner.prepare(99L, landmarks(), [pixel(1, 0.5)])))
  invalid(() => {
    ignore(owner.replace_projection(99L, replacement(), camera=None))
  })
  assert_eq(footprint_window_guard_snapshot(owner), before)
  let frame = footprint_window_guard_step(owner, 100L, landmarks(), [
    pixel(1, 0.5),
  ])
  assert_eq(
    frame.analysis.windows.statistics.current_window.first_timestamp_us,
    100L,
  )
  assert_eq(frame.health.streak_since_us, Some(100L))
}

///|
test "used competing and replaced window preparations remain bound to their original owner" {
  let owner = footprint_window_guard_fresh(instant=true)
  let branch = owner.fork()
  let first = owner.prepare(0L, landmarks(), [pixel(1, 0.5)])
  let stale = owner.prepare(1L, landmarks(), [pixel(2, 0.5)])
  ignore(first.commit(footprint_guard_bundle(first.preview())))
  invalid(() => ignore(first.commit(footprint_guard_bundle(first.preview()))))
  invalid(() => ignore(stale.commit(footprint_guard_bundle(stale.preview()))))
  let independent = branch.prepare(0L, landmarks(), [pixel(3, 0.5)])
  ignore(independent.commit(footprint_guard_bundle(independent.preview())))
  let pending = owner.prepare(200000L, landmarks(), [pixel(1, 0.5)])
  ignore(owner.replace_projection(100000L, calibration(), camera=None))
  invalid(() => {
    ignore(pending.commit(footprint_guard_bundle(pending.preview())))
  })
  assert_eq(
    footprint_window_guard_pixel(branch.checkpoint()).motion.tracks[0].track_id,
    3,
  )
}

///|
test "previews returned faces pools and checkpoint arrays are deeply detached from guarded window candidates" {
  let owner = footprint_window_guard_fresh(instant=true)
  ignore(footprint_window_guard_step(owner, 0L, landmarks(), [pixel(1, 0.5)]))
  let prepared = owner.prepare(100000L, landmarks(), [pixel(1, 0.5)])
  let preview = prepared.preview()
  let expected = @debug.to_string(preview)
  preview.health.landmarks.clear()
  preview.measurement.motion.tracks[0].filtered_covariance.unwrap()[0] = 999.0
  preview.suppressed_track_ids.push(99)
  assert_eq(@debug.to_string(prepared.preview()), expected)
  let shape : @zones.FootprintShape = @zones.Convex(
    @zones.ConvexFootprint::new([
      { x: -0.125, y: -0.125, },
      { x: 0.125, y: -0.125, },
      { x: 0.125, y: 0.125, },
      { x: -0.125, y: 0.125, },
    ]),
  )
  let result = prepared.commit(
    footprint_guard_bundle(prepared.preview(), shape~),
  )
  let before = footprint_window_guard_snapshot(owner)
  guard result.analysis.windows.runs.evidence.evidence[0].evidence
    is @zones.Convex(band) else {
    fail("convex evidence missing")
  }
  band.faces.clear()
  band.vertices_offset_m.clear()
  result.analysis.windows.statistics.current_window.zones[0].endings.clear()
  result.analysis.windows.runs.active.clear()
  result.health.landmarks.clear()
  let saved = owner.checkpoint()
  saved.analysis.windows.runs.states.clear()
  saved.analysis.windows.current_window.unwrap().zones.clear()
  saved.health.landmarks.clear()
  assert_eq(footprint_window_guard_snapshot(owner), before)
  assert_eq(@debug.to_string(prepared.preview()), expected)
}

///|
test "guarded raw window outputs match the original guarded chain and independently updated v29 monitor" {
  let old = footprint_guard_fresh()
  let downstream = @zones.FootprintRunWindowMonitor::new(
    @zones.FootprintRunMonitor::from_checkpoint(old.checkpoint().analysis.runs),
    window_us=200000L,
  )
  let owner = @guarded.FootprintRunWindowGuardedSession::new(
    old,
    window_us=200000L,
  )
  for index in 0..<8 {
    let time = index.to_int64() * 100000L
    let refs = if index == 4 || index == 5 {
      landmarks(shift=0.5)
    } else {
      landmarks()
    }
    let objects = [pixel(1, 0.5)]
    let previous = old.prepare(time, refs, objects)
    let assignments = footprint_guard_bundle(previous.preview())
    let legacy = previous.commit(assignments)
    let expected = downstream.update(
      legacy.analysis.measurement.motion,
      assignments,
    )
    let actual = owner.update(time, refs, objects, assignments)
    assert_eq(@debug.to_string(actual.health), @debug.to_string(legacy.health))
    assert_eq(
      @debug.to_string(actual.analysis.measurement),
      @debug.to_string(legacy.analysis.measurement),
    )
    assert_eq(
      @debug.to_string(actual.analysis.windows),
      @debug.to_string(expected),
    )
    ignore(
      @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
        owner.checkpoint(),
      ),
    )
  }
}

///|
test "complete guarded window checkpoints resume every blocking and reconfirmation cut" {
  let times = [0L, 100000L, 200000L, 300000L, 400000L, 500000L, 600000L]
  let refs = [
    landmarks(),
    landmarks(),
    landmarks(),
    [],
    landmarks(),
    landmarks(),
    landmarks(),
  ]
  let full = footprint_window_guard_fresh(width=200000L)
  let expected : Array[String] = []
  for index, time in times {
    expected.push(
      @debug.to_string(
        footprint_window_guard_step(full, time, refs[index], [pixel(1, 0.5)]),
      ),
    )
  }
  for cut in 0..<=times.length() {
    let prefix = footprint_window_guard_fresh(width=200000L)
    for index in 0..<cut {
      ignore(
        footprint_window_guard_step(prefix, times[index], refs[index], [
          pixel(1, 0.5),
        ]),
      )
    }
    let restored = @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<times.length() {
      assert_eq(
        @debug.to_string(
          footprint_window_guard_step(restored, times[index], refs[index], [
            pixel(1, 0.5),
          ]),
        ),
        expected[index],
      )
    }
    assert_eq(
      footprint_window_guard_snapshot(restored),
      footprint_window_guard_snapshot(full),
    )
  }
}

///|
test "warm Brown guarded window reframe preserves metric state health streak and aggregate continuation" {
  let owner = @guarded.FootprintRunWindowGuardedSession::new(
    footprint_guard_fresh(
      instant=true,
      camera=brown_model(),
      projection=brown_calibration(),
    ),
    window_us=200000L,
  )
  for time in [0L, 100000L, 200000L] {
    ignore(
      footprint_window_guard_step(owner, time, brown_landmarks(), [
        pixel(1, 200.0, x=300.0),
      ]),
    )
  }
  let transform = @types.PixelTransform::new(
    scale_x=0.5,
    scale_y=0.75,
    offset_x=-4.0,
    offset_y=2.0,
  )
  let adapted = owner.reframed(transform)
  assert_eq(
    @debug.to_string(footprint_window_guard_pixel(adapted.checkpoint()).motion),
    @debug.to_string(footprint_window_guard_pixel(owner.checkpoint()).motion),
  )
  assert_eq(
    @debug.to_string(adapted.checkpoint().analysis.windows.current_window),
    @debug.to_string(owner.checkpoint().analysis.windows.current_window),
  )
  let restored = @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
    adapted.checkpoint(),
  )
  let refs = brown_landmarks().map(observation => {
    observation.reframed(transform)
  })
  let object = pixel(1, 200.0, x=300.0).reframed(transform)
  let actual = footprint_window_guard_step(restored, 300000L, refs, [object])
  let expected = footprint_window_guard_step(
    owner,
    300000L,
    brown_landmarks(),
    [pixel(1, 200.0, x=300.0)],
  )
  assert_eq(
    @debug.to_string(actual.analysis.windows.statistics),
    @debug.to_string(expected.analysis.windows.statistics),
  )
  assert_eq(actual.analysis.windows.runs.active[0].sample_count, 3L)
}

///|
test "replacement is one cold window barrier preserves counters and next IDs and retries health confirmation" {
  let owner = footprint_window_guard_fresh(width=200000L)
  for time in [0L, 100000L, 200000L, 300000L] {
    ignore(
      footprint_window_guard_step(owner, time, landmarks(), [pixel(1, 0.5)]),
    )
  }
  let before = footprint_window_guard_snapshot(owner)
  invalid(() => {
    ignore(owner.replace_projection(300000L, replacement(), camera=None))
  })
  assert_eq(footprint_window_guard_snapshot(owner), before)
  let barrier = owner.replace_projection(350000L, replacement(), camera=None)
  assert_eq(barrier.decision, @guarded.Blocked)
  assert_eq(barrier.health.status, @health.Insufficient)
  assert_eq(barrier.analysis.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(barrier.analysis.windows.statistics.current_window.input_frames, 3L)
  assert_eq(
    barrier.analysis.windows.statistics.current_window.zones[0].endings[1].confirmed,
    1L,
  )
  assert_eq(
    footprint_window_guard_pixel(owner.checkpoint()).motion.next_segment_id,
    2L,
  )
  let restored = @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
    owner.checkpoint(),
  )
  let pending = footprint_window_guard_step(
    restored,
    400000L,
    scaled_landmarks(2.0),
    [pixel(1, 0.25)],
  )
  assert_eq(pending.decision, @guarded.Blocked)
  let next = footprint_window_guard_step(
    restored,
    500000L,
    scaled_landmarks(2.0),
    [pixel(1, 0.25)],
  )
  assert_eq(next.decision, @guarded.Allowed)
  assert_eq(next.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(next.analysis.windows.runs.active.length(), 0)
}

///|
test "started guarded initialization excludes historical confirmations and keeps the original session detached" {
  let old = footprint_guard_fresh(instant=true)
  for time in [0L, 100000L, 200000L] {
    ignore(footprint_guard_step(old, time, landmarks(), [pixel(1, 0.5)]))
  }
  let owner = @guarded.FootprintRunWindowGuardedSession::new(
    old,
    window_us=1000000L,
  )
  assert_eq(
    owner.checkpoint().analysis.windows.baseline_timestamp_us,
    Some(200000L),
  )
  assert_true(owner.checkpoint().analysis.windows.current_window is None)
  ignore(footprint_guard_step(old, 300000L, [], []))
  let frame = footprint_window_guard_step(owner, 300000L, landmarks(), [
    pixel(1, 0.5),
  ])
  assert_eq(
    frame.analysis.windows.statistics.current_window.zones[0].opening_confirmed,
    1L,
  )
  assert_eq(
    frame.analysis.windows.statistics.current_window.zones[0].confirmed_inside,
    0L,
  )
  ignore(
    @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
      owner.checkpoint(),
    ),
  )
}

///|
test "adjacent large clocks and terminal barriers retain exact window timestamps without future frames" {
  for first in [9007199254740992L, 9223372036854775805L] {
    let owner = footprint_window_guard_fresh(instant=true, width=1L)
    for delta in [0L, 1L] {
      let result = footprint_window_guard_step(
        owner,
        first + delta,
        landmarks(),
        [pixel(1, 0.5)],
      )
      assert_eq(
        result.analysis.windows.statistics.current_window.start_us,
        first + delta,
      )
      ignore(
        @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
          owner.checkpoint(),
        ),
      )
    }
    let barrier = owner.replace_projection(
      first + 2L,
      calibration(),
      camera=None,
    )
    assert_eq(
      barrier.analysis.windows.statistics.current_window.start_us,
      first + 2L,
    )
    assert_eq(
      barrier.analysis.windows.statistics.current_window.input_frames,
      1L,
    )
    if first == 9223372036854775805L {
      assert_eq(
        barrier.analysis.windows.statistics.current_window.end_exclusive_us,
        None,
      )
    }
    ignore(
      @guarded.FootprintRunWindowGuardedSession::from_checkpoint(
        owner.checkpoint(),
      ),
    )
  }
}
