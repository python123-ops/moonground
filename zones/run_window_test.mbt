///|
fn run_window_owner(
  width~ : Int64 = 10L,
  gap~ : Int64 = 100L,
  confirmation~ : Int64 = 0L,
  samples~ : Int64 = 1L,
  origin~ : Int64 = 0L,
) -> @zones.FootprintRunWindowMonitor raise @types.GroundError {
  @zones.FootprintRunWindowMonitor::new(
    run_monitor(gap~, confirmation~, samples~),
    window_us=width,
    origin_us=origin,
  )
}

///|
fn run_window_step(
  owner : @zones.FootprintRunWindowMonitor,
  timestamp : Int64,
  x~ : Double = 0.5,
) -> @zones.FootprintRunWindowFrame raise @types.GroundError {
  let frame = run_sample(timestamp, x~)
  owner.update(frame, run_shapes(frame))
}

///|
fn run_window_snapshot(owner : @zones.FootprintRunWindowMonitor) -> String {
  let saved = owner.checkpoint()
  @debug.to_string(
    (
      saved.window_us,
      saved.origin_us,
      saved.baseline_timestamp_us,
      saved.runs.last_timestamp_us,
      saved.current_window,
      saved.runs.states.map(state => {
        (state.run, state.last_position_m, state.last_position_covariance)
      }),
    ),
  )
}

///|
test "run window configuration rejects nonpositive width negative origin and started baseline before origin" {
  invalid(() => ignore(run_window_owner(width=0L)))
  invalid(() => ignore(run_window_owner(origin=-1L)))
  let monitor = run_monitor()
  let frame = run_sample(3L)
  ignore(monitor.update(frame, run_shapes(frame)))
  invalid(() => {
    ignore(
      @zones.FootprintRunWindowMonitor::new(
        monitor,
        window_us=10L,
        origin_us=4L,
      ),
    )
  })
}

///|
test "run windows preserve every original evidence and run outcome exactly" {
  let original = run_monitor(confirmation=2L, samples=3L)
  let owner = @zones.FootprintRunWindowMonitor::new(original, window_us=10L)
  for index, x in [0.5, 0.5, 0.5, 1.0, 2.0, 2.0, 2.0] {
    let frame = run_sample(index.to_int64(), x~)
    let assignments = run_shapes(frame)
    let expected = original.update(frame, assignments)
    let result = owner.update(frame, assignments)
    assert_eq(@debug.to_string(result.runs), @debug.to_string(expected))
    ignore(
      @zones.FootprintRunWindowMonitor::from_checkpoint(owner.checkpoint()),
    )
  }
}

///|
test "run confirmation belongs to the exact report bucket after both original thresholds" {
  let owner = run_window_owner(confirmation=10L, samples=2L)
  ignore(run_window_step(owner, 0L))
  ignore(run_window_step(owner, 5L))
  let result = run_window_step(owner, 10L)
  assert_eq(result.runs.confirmed.length(), 1)
  assert_eq(
    result.statistics.closed_window.unwrap().zones[0].confirmed_inside,
    0L,
  )
  let current = result.statistics.current_window
  assert_eq(current.start_us, 10L)
  assert_eq(current.zones[0].opening_active, 1L)
  assert_eq(current.zones[0].opening_confirmed, 0L)
  assert_eq(current.zones[0].started, 0L)
  assert_eq(current.zones[0].confirmed_inside, 1L)
  assert_eq(
    run_window_step(owner, 11L).statistics.current_window.zones[0].confirmed_inside,
    1L,
  )
  ignore(@zones.FootprintRunWindowMonitor::from_checkpoint(owner.checkpoint()))
}

///|
test "already confirmed active run opens the next bucket without another confirmation" {
  let owner = run_window_owner()
  assert_eq(
    run_window_step(owner, 0L).statistics.current_window.zones[0].confirmed_inside,
    1L,
  )
  let result = run_window_step(owner, 10L)
  assert_eq(
    result.statistics.closed_window.unwrap().zones[0].confirmed_inside,
    1L,
  )
  let row = result.statistics.current_window.zones[0]
  assert_eq(row.opening_active, 1L)
  assert_eq(row.opening_confirmed, 1L)
  assert_eq(row.started, 0L)
  assert_eq(row.confirmed_inside, 0L)
  assert_eq(result.runs.active[0].confirmed, true)
  ignore(@zones.FootprintRunWindowMonitor::from_checkpoint(owner.checkpoint()))
}

///|
test "one input may close a qualified old run and confirm a different new run" {
  let owner = run_window_owner()
  ignore(run_window_step(owner, 0L))
  let result = run_window_step(owner, 1L, x=2.0)
  let row = result.statistics.current_window.zones[0]
  assert_eq(row.started, 2L)
  assert_eq(row.confirmed_inside, 1L)
  assert_eq(row.confirmed_outside, 1L)
  assert_eq(row.endings[7].reason, @zones.DecisionChanged)
  assert_eq(row.endings[7].confirmed, 1L)
  assert_eq(row.endings[7].unconfirmed, 0L)
  ignore(@zones.FootprintRunWindowMonitor::from_checkpoint(owner.checkpoint()))
}

///|
test "all eight genuine run ending reasons partition qualified and unqualified closures" {
  for qualified in [false, true] {
    for reason in 0..<8 {
      let owner = run_window_owner(
        gap=if reason == 0 { 2L } else { 100L },
        confirmation=if qualified { 0L } else { 2L },
        samples=if qualified { 1L } else { 3L },
      )
      ignore(run_window_step(owner, 0L))
      let time = if reason == 0 { 2L } else { 1L }
      let next = run_sample(
        time,
        x=if reason == 6 { 1.0 } else if reason == 7 { 2.0 } else { 0.5 },
      )
      let next = match reason {
        1 =>
          {
            ..next,
            tracks: [{ ..next.tracks[0], segment_id: "2", }],
            closed_segment_ids: [next.tracks[0].segment_id],
          }
        2 => { ..next, tracks: [{ ..next.tracks[0], segment_id: "2", }], }
        3 => { ..next, tracks: [], }
        4 =>
          {
            ..next,
            tracks: [{ ..next.tracks[0], status: @motion.Uncertain, }],
          }
        _ => next
      }
      let result = owner.update(
        next,
        run_shapes(next, radius=if reason == 5 { 0.25 } else { 0.125 }),
      )
      assert_eq(result.runs.closed.length(), 1)
      let endings = result.statistics.current_window.zones[0].endings
      for index, count in endings {
        assert_eq(
          count.confirmed,
          if index == reason && qualified {
            1L
          } else {
            0L
          },
        )
        assert_eq(
          count.unconfirmed,
          if index == reason && !qualified {
            1L
          } else {
            0L
          },
        )
      }
      ignore(
        @zones.FootprintRunWindowMonitor::from_checkpoint(owner.checkpoint()),
      )
    }
  }
}

///|
test "started qualified baseline is not observed or backfilled and its future ending is still counted" {
  let monitor = run_monitor(confirmation=0L, samples=1L)
  let initial = run_sample(3L)
  ignore(monitor.update(initial, run_shapes(initial)))
  let owner = @zones.FootprintRunWindowMonitor::new(monitor, window_us=10L)
  assert_true(owner.checkpoint().current_window is None)
  assert_eq(owner.checkpoint().baseline_timestamp_us, Some(3L))
  let first = run_window_step(owner, 4L)
  assert_eq(first.statistics.current_window.zones[0].confirmed_inside, 0L)
  assert_eq(first.statistics.current_window.zones[0].opening_confirmed, 1L)
  let absent = { ..run_sample(5L), tracks: [], }
  let result = owner.update(absent, run_shapes(absent))
  assert_eq(result.statistics.current_window.zones[0].endings[3].confirmed, 1L)
  assert_eq(result.statistics.current_window.zones[0].confirmed_inside, 0L)
  ignore(@zones.FootprintRunWindowMonitor::from_checkpoint(owner.checkpoint()))
}

///|
test "started unqualified run can first qualify on the first observed statistics input" {
  let monitor = run_monitor(confirmation=1L, samples=2L)
  let initial = run_sample(0L)
  ignore(monitor.update(initial, run_shapes(initial)))
  let owner = @zones.FootprintRunWindowMonitor::new(monitor, window_us=10L)
  let result = run_window_step(owner, 1L)
  let row = result.statistics.current_window.zones[0]
  assert_eq(row.opening_active, 1L)
  assert_eq(row.opening_confirmed, 0L)
  assert_eq(row.started, 0L)
  assert_eq(row.confirmed_inside, 1L)
  ignore(@zones.FootprintRunWindowMonitor::from_checkpoint(owner.checkpoint()))
}

///|
test "empty supplied inputs count as samples while skipped windows are never materialized as zeros" {
  let owner = run_window_owner()
  for time in [0L, 1L] {
    let frame = { ..run_sample(time), tracks: [], }
    ignore(owner.update(frame, run_shapes(frame)))
  }
  let frame = { ..run_sample(100L), tracks: [], }
  let result = owner.update(frame, run_shapes(frame))
  assert_eq(result.statistics.closed_window.unwrap().input_frames, 2L)
  assert_eq(result.statistics.current_window.input_frames, 1L)
  assert_eq(result.statistics.unobserved_windows, 9L)
  assert_eq(result.statistics.current_window.start_us, 100L)
  assert_eq(result.statistics.current_window.zones[0].started, 0L)
  ignore(@zones.FootprintRunWindowMonitor::from_checkpoint(owner.checkpoint()))
}

///|
test "first statistics input has no closed bucket or skipped count even after a much earlier baseline" {
  let monitor = run_monitor(confirmation=0L, samples=1L)
  let initial = run_sample(1L)
  ignore(monitor.update(initial, run_shapes(initial)))
  let owner = @zones.FootprintRunWindowMonitor::new(monitor, window_us=10L)
  let result = run_window_step(owner, 100L)
  assert_true(result.statistics.closed_window is None)
  assert_eq(result.statistics.unobserved_windows, 0L)
  assert_eq(result.statistics.current_window.zones[0].opening_active, 1L)
}

///|
test "run window bucket arithmetic preserves adjacent exact clocks above two to the fifty third" {
  let origin = 9007199254740992L
  let owner = run_window_owner(width=2L, origin~)
  ignore(run_window_step(owner, origin))
  let next = run_window_step(owner, origin + 1L)
  assert_eq(next.statistics.current_window.start_us, origin)
  assert_eq(next.statistics.current_window.input_frames, 2L)
  let rolled = run_window_step(owner, origin + 2L)
  assert_eq(rolled.statistics.current_window.start_us, origin + 2L)
  assert_eq(
    rolled.statistics.closed_window.unwrap().end_exclusive_us,
    Some(origin + 2L),
  )
  ignore(@zones.FootprintRunWindowMonitor::from_checkpoint(owner.checkpoint()))
}

///|
test "representable maximum exclusive end rolls into a terminal bucket with no representable end" {
  let owner = run_window_owner(width=9223372036854775807L)
  let before = run_window_step(owner, 9223372036854775806L)
  assert_eq(
    before.statistics.current_window.end_exclusive_us,
    Some(9223372036854775807L),
  )
  let last = run_window_step(owner, 9223372036854775807L)
  assert_eq(last.statistics.current_window.start_us, 9223372036854775807L)
  assert_true(last.statistics.current_window.end_exclusive_us is None)
  assert_eq(last.statistics.current_window.zones[0].confirmed_inside, 0L)
  ignore(@zones.FootprintRunWindowMonitor::from_checkpoint(owner.checkpoint()))
}

///|
test "late window origin rejection discards a successful old monitor update" {
  let owner = run_window_owner(origin=100L)
  let before = run_window_snapshot(owner)
  invalid(() => ignore(run_window_step(owner, 99L)))
  assert_eq(run_window_snapshot(owner), before)
  assert_true(owner.checkpoint().runs.last_timestamp_us is None)
  let result = run_window_step(owner, 100L)
  assert_eq(result.runs.active[0].sample_count, 1L)
  assert_eq(result.statistics.current_window.zones[0].started, 1L)
}

///|
test "assignment numeric and repeated time failures preserve old monitor and current bucket for corrected retries" {
  let owner = run_window_owner()
  ignore(run_window_step(owner, 0L))
  let before = run_window_snapshot(owner)
  let frame = run_sample(10L)
  let bad = @zones.FootprintAssignments::new(10L, [
    @zones.FootprintAssignment::new(
      1,
      "99",
      @zones.Disk(@zones.DiskFootprint::new(0.125)),
    ),
  ])
  invalid(() => ignore(owner.update(frame, bad)))
  invalid(() => ignore(owner.update(frame, run_shapes(frame, radius=1.0e-300))))
  invalid(() => ignore(run_window_step(owner, 0L)))
  assert_eq(run_window_snapshot(owner), before)
  let result = owner.update(frame, run_shapes(frame))
  assert_eq(result.statistics.closed_window.unwrap().last_timestamp_us, 0L)
  assert_eq(result.runs.active[0].sample_count, 2L)
}

///|
test "run window export nested aggregate arrays and forks are independent of callers and source monitor" {
  let monitor = run_monitor(confirmation=0L, samples=1L)
  let owner = @zones.FootprintRunWindowMonitor::new(monitor, window_us=10L)
  let source_frame = run_sample(0L)
  ignore(monitor.update(source_frame, run_shapes(source_frame)))
  assert_true(owner.checkpoint().runs.last_timestamp_us is None)
  let output = run_window_step(owner, 0L)
  output.statistics.current_window.zones[0].endings.clear()
  output.statistics.current_window.zones.clear()
  let branch = owner.fork()
  ignore(run_window_step(branch, 1L, x=2.0))
  let saved = owner.checkpoint()
  saved.runs.states.clear()
  saved.current_window.unwrap().zones[0].endings.clear()
  assert_eq(owner.checkpoint().runs.states[0].run.sample_count, 1L)
  assert_eq(
    owner.checkpoint().current_window.unwrap().zones[0].endings.length(),
    8,
  )
  assert_eq(branch.checkpoint().current_window.unwrap().zones[0].started, 2L)
}

///|
test "run monitor and aggregate resume every cut across unknown input switches and rollover" {
  let values = [0.5, 0.5, 1.0, 2.0, 2.0, 0.5, 0.5]
  let times = [0L, 1L, 2L, 10L, 11L, 30L, 31L]
  let owner = run_window_owner(confirmation=1L, samples=2L)
  let expected : Array[String] = []
  for index, time in times {
    expected.push(
      @debug.to_string(run_window_step(owner, time, x=values[index])),
    )
  }
  let expected_final = run_window_snapshot(owner)
  for cut in 0..<=times.length() {
    let prefix = run_window_owner(confirmation=1L, samples=2L)
    for index in 0..<cut {
      ignore(run_window_step(prefix, times[index], x=values[index]))
    }
    let resumed = @zones.FootprintRunWindowMonitor::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<times.length() {
      assert_eq(
        @debug.to_string(
          run_window_step(resumed, times[index], x=values[index]),
        ),
        expected[index],
      )
    }
    assert_eq(run_window_snapshot(resumed), expected_final)
  }
}

///|
test "feasible Int64 maximum aggregate fails late on a new start then permits same time no event correction" {
  let monitor = @zones.FootprintRunMonitor::new(
    "zones",
    [square()],
    @zones.FootprintRunConfig::new(
      max_gap_us=9223372036854775807L,
      min_samples=1L,
      confirmation_us=0L,
    ),
    max_tracks=2,
  )
  let owner = @zones.FootprintRunWindowMonitor::new(
    monitor,
    window_us=9223372036854775807L,
  )
  let first = run_sample(9223372036854775805L)
  let first = {
    ..first,
    tracks: [
      first.tracks[0],
      { ..first.tracks[0], track_id: 2, segment_id: "2", },
    ],
  }
  ignore(owner.update(first, run_shapes(first)))
  let saved = owner.checkpoint()
  let window = saved.current_window.unwrap()
  let row = window.zones[0]
  row.endings[5] = { ..row.endings[5], confirmed: 9223372036854775805L, }
  window.zones[0] = {
    ..row,
    started: 9223372036854775807L,
    confirmed_inside: 9223372036854775807L,
  }
  let saved = {
    ..saved,
    current_window: Some({
      ..window,
      first_timestamp_us: 0L,
      input_frames: 4611686018427387904L,
    }),
  }
  let restored = @zones.FootprintRunWindowMonitor::from_checkpoint(saved)
  let before = run_window_snapshot(restored)
  let changed = run_sample(9223372036854775806L, x=2.0)
  let changed = {
    ..changed,
    tracks: [
      changed.tracks[0],
      { ..changed.tracks[0], track_id: 2, segment_id: "2", },
    ],
  }
  invalid(() => ignore(restored.update(changed, run_shapes(changed))))
  assert_eq(run_window_snapshot(restored), before)
  let corrected = run_sample(9223372036854775806L)
  let corrected = {
    ..corrected,
    tracks: [
      corrected.tracks[0],
      { ..corrected.tracks[0], track_id: 2, segment_id: "2", },
    ],
  }
  let result = restored.update(corrected, run_shapes(corrected))
  assert_eq(
    result.statistics.current_window.zones[0].started,
    9223372036854775807L,
  )
  assert_eq(result.runs.active[0].sample_count, 2L)
  ignore(
    @zones.FootprintRunWindowMonitor::from_checkpoint(restored.checkpoint()),
  )
}
