///|
fn consumer_run_windows() -> @zones.FootprintRunWindowMonitor raise @moonground.GroundError {
  @zones.FootprintRunWindowMonitor::new(consumer_run_monitor(), window_us=3L)
}

///|
test "packaged footprint windows count first confirmations and endings at report time" {
  let owner = consumer_run_windows()
  let shape : @zones.FootprintShape = @zones.Disk(
    @zones.DiskFootprint::new(0.125),
  )
  for time in [0L, 1L, 2L] {
    let frame = consumer_run_frame(time)
    let output = owner.update(frame, consumer_assigned_bundle(frame, shape))
    assert_eq(
      output.statistics.current_window.zones[0].confirmed_inside,
      if time == 2L {
        1L
      } else {
        0L
      },
    )
    assert_eq(output.statistics.current_window.zones[0].started, 1L)
  }
  let outside = consumer_run_frame(3L, x=2.0)
  let output = owner.update(outside, consumer_assigned_bundle(outside, shape))
  guard output.statistics.closed_window is Some(previous) else {
    fail("observed prior bucket missing")
  }
  assert_eq(previous.start_us, 0L)
  assert_eq(previous.end_exclusive_us, Some(3L))
  assert_eq(previous.zones[0].confirmed_inside, 1L)
  let row = output.statistics.current_window.zones[0]
  assert_eq(row.opening_active, 1L)
  assert_eq(row.opening_confirmed, 1L)
  assert_eq(row.started, 1L)
  assert_eq(row.confirmed_outside, 0L)
  assert_eq(row.endings[7].confirmed, 1L)
  assert_eq(row.endings[7].unconfirmed, 0L)
  ignore(@zones.FootprintRunWindowMonitor::from_checkpoint(owner.checkpoint()))
}

///|
test "packaged started run baseline excludes past confirmations and aggregate exports detach" {
  let monitor = consumer_run_monitor()
  let shape : @zones.FootprintShape = @zones.Disk(
    @zones.DiskFootprint::new(0.125),
  )
  for time in [0L, 1L, 2L] {
    let frame = consumer_run_frame(time)
    ignore(monitor.update(frame, consumer_assigned_bundle(frame, shape)))
  }
  let owner = @zones.FootprintRunWindowMonitor::new(monitor, window_us=10L)
  assert_true(owner.checkpoint().current_window is None)
  let frame = consumer_run_frame(3L)
  let output = owner.update(frame, consumer_assigned_bundle(frame, shape))
  assert_eq(output.runs.confirmed.length(), 0)
  assert_eq(output.statistics.current_window.zones[0].opening_confirmed, 1L)
  assert_eq(output.statistics.current_window.zones[0].confirmed_inside, 0L)
  let saved = owner.checkpoint()
  let resumed = @zones.FootprintRunWindowMonitor::from_checkpoint(saved)
  let branch = owner.fork()
  guard saved.current_window is Some(window) else {
    fail("current window missing")
  }
  window.zones.clear()
  guard owner.checkpoint().current_window is Some(original) else {
    fail("owned window missing")
  }
  assert_eq(original.zones.length(), 1)
  let next = consumer_run_frame(4L, x=2.0)
  let expected = resumed.update(next, consumer_assigned_bundle(next, shape))
  let actual = branch.update(next, consumer_assigned_bundle(next, shape))
  assert_eq(
    @debug.to_string(actual.statistics),
    @debug.to_string(expected.statistics),
  )
  assert_eq(owner.checkpoint().runs.last_timestamp_us, Some(3L))
}

///|
test "packaged run window numeric failure rolls back and exact Int64 terminal buckets remain half open" {
  let owner = consumer_run_windows()
  let shape : @zones.FootprintShape = @zones.Disk(
    @zones.DiskFootprint::new(0.125),
  )
  let first = consumer_run_frame(0L)
  ignore(owner.update(first, consumer_assigned_bundle(first, shape)))
  let next = consumer_run_frame(1L)
  let tiny : @zones.FootprintShape = @zones.Disk(
    @zones.DiskFootprint::new(1.0e-30),
  )
  try owner.update(next, consumer_assigned_bundle(next, tiny)) catch {
    _ => ()
  } noraise {
    _ => fail("unrepresentable physical support accepted")
  }
  assert_eq(owner.checkpoint().runs.last_timestamp_us, Some(0L))
  guard owner.checkpoint().current_window is Some(before) else {
    fail("window missing")
  }
  assert_eq(before.input_frames, 1L)
  let corrected = owner.update(next, consumer_assigned_bundle(next, shape))
  assert_eq(corrected.runs.active[0].sample_count, 2L)
  let terminal = @zones.FootprintRunWindowMonitor::new(
    @zones.FootprintRunMonitor::new(
      "consumer-runs",
      [consumer_disk_square(multiplier=0.0)],
      @zones.FootprintRunConfig::new(
        max_gap_us=9223372036854775807L,
        min_samples=1L,
        confirmation_us=0L,
      ),
    ),
    window_us=9223372036854775807L,
  )
  for time in [0L, 9223372036854775806L] {
    let frame = consumer_run_frame(time)
    let result = terminal.update(frame, consumer_assigned_bundle(frame, shape))
    assert_eq(
      result.statistics.current_window.end_exclusive_us,
      Some(9223372036854775807L),
    )
  }
  let frame = consumer_run_frame(9223372036854775807L)
  let result = terminal.update(frame, consumer_assigned_bundle(frame, shape))
  assert_eq(result.statistics.current_window.start_us, 9223372036854775807L)
  assert_eq(result.statistics.current_window.end_exclusive_us, None)
  assert_eq(result.statistics.current_window.zones[0].confirmed_inside, 0L)
  ignore(
    @zones.FootprintRunWindowMonitor::from_checkpoint(terminal.checkpoint()),
  )
}
