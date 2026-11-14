///|
fn run_window_cp_owner() -> @zones.FootprintRunWindowMonitor raise @types.GroundError {
  let owner = @zones.FootprintRunWindowMonitor::new(
    run_monitor(confirmation=0L, samples=1L),
    window_us=10L,
  )
  for time in [0L, 1L, 2L] {
    let frame = run_sample(time)
    ignore(owner.update(frame, run_shapes(frame)))
  }
  owner
}

///|
fn run_window_cp_bad(saved : @zones.FootprintRunWindowCheckpoint) -> Unit raise {
  try @zones.FootprintRunWindowMonitor::from_checkpoint(saved) catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("impossible run window checkpoint accepted")
  }
}

///|
test "run windows checkpoint version width origin and baseline are checked" {
  let saved = run_window_cp_owner().checkpoint()
  run_window_cp_bad({ ..saved, version: 2, })
  run_window_cp_bad({ ..saved, window_us: 0L, })
  run_window_cp_bad({ ..saved, origin_us: 3L, })
  run_window_cp_bad({ ..saved, baseline_timestamp_us: Some(3L), })
}

///|
test "run windows current bounds and observed count share original monitor clock" {
  let saved = run_window_cp_owner().checkpoint()
  guard saved.current_window is Some(window) else { fail("window missing") }
  for
    changed in [
      { ..window, start_us: 1L, },
      { ..window, end_exclusive_us: None, },
      { ..window, last_timestamp_us: 3L, },
      { ..window, input_frames: 4L, },
    ] {
    run_window_cp_bad({ ..saved, current_window: Some(changed), })
  }
  run_window_cp_bad({ ..saved, current_window: None, })
}

///|
test "run windows canonical zone and ending reason orders cannot be permuted" {
  let saved = run_window_cp_owner().checkpoint()
  guard saved.current_window is Some(window) else { fail("window missing") }
  let row = window.zones[0]
  window.zones[0] = { ..row, zone_id: "unknown", }
  run_window_cp_bad({ ..saved, current_window: Some(window), })
  window.zones[0] = row
  let original = row.endings[0]
  row.endings[0] = row.endings[1]
  row.endings[1] = original
  run_window_cp_bad({ ..saved, current_window: Some(window), })
}

///|
test "run window opening pools and active flow reject plausible independent counters" {
  for change in 0..<3 {
    let saved = run_window_cp_owner().checkpoint()
    guard saved.current_window is Some(window) else { fail("window missing") }
    let row = window.zones[0]
    window.zones[0] = match change {
      0 => { ..row, opening_active: 1L, }
      1 => { ..row, started: 0L, }
      _ => { ..row, opening_confirmed: 1L, }
    }
    run_window_cp_bad({ ..saved, current_window: Some(window), })
  }
}

///|
test "run window confirmation flow must account for currently confirmed source states" {
  let saved = run_window_cp_owner().checkpoint()
  guard saved.current_window is Some(window) else { fail("window missing") }
  window.zones[0] = { ..window.zones[0], confirmed_inside: 0L, }
  run_window_cp_bad({ ..saved, current_window: Some(window), })
}

///|
test "run window aggregate budgets include both confirmations and every ending reason" {
  for change in 0..<2 {
    let saved = run_window_cp_owner().checkpoint()
    guard saved.current_window is Some(window) else { fail("window missing") }
    let row = window.zones[0]
    if change == 0 {
      window.zones[0] = {
        ..row,
        confirmed_inside: 3001L,
        confirmed_outside: 3001L,
      }
    } else {
      for i in 0..<row.endings.length() {
        row.endings[i] = { ..row.endings[i], confirmed: 1000L, }
      }
    }
    run_window_cp_bad({ ..saved, current_window: Some(window), })
  }
}

///|
test "instant footprint run policy cannot have an unconfirmed ending" {
  let saved = run_window_cp_owner().checkpoint()
  guard saved.current_window is Some(window) else { fail("window missing") }
  let row = window.zones[0]
  row.endings[0] = { ..row.endings[0], unconfirmed: 1L, }
  window.zones[0] = { ..row, started: 2L, }
  run_window_cp_bad({ ..saved, current_window: Some(window), })
}

///|
test "run window source sample suffix must match the count of every supplied input" {
  let saved = run_window_cp_owner().checkpoint()
  guard saved.current_window is Some(window) else { fail("window missing") }
  run_window_cp_bad({
    ..saved,
    current_window: Some({ ..window, input_frames: 2L, }),
  })
  let state = saved.runs.states[0]
  saved.runs.states[0] = { ..state, run: { ..state.run, sample_count: 2L, }, }
  ignore(@zones.FootprintRunMonitor::from_checkpoint(saved.runs))
  run_window_cp_bad(saved)
}

///|
test "started already confirmed monitor is an unobserved baseline then closes without backfill" {
  let monitor = run_monitor(confirmation=0L, samples=1L)
  let initial = run_sample(3L)
  ignore(monitor.update(initial, run_shapes(initial)))
  let owner = @zones.FootprintRunWindowMonitor::new(monitor, window_us=10L)
  assert_true(owner.checkpoint().current_window is None)
  let next = run_sample(4L, x=2.0)
  let output = owner.update(next, run_shapes(next))
  assert_eq(output.statistics.current_window.zones[0].opening_confirmed, 1L)
  assert_eq(output.statistics.current_window.zones[0].confirmed_inside, 0L)
  assert_eq(output.statistics.current_window.zones[0].confirmed_outside, 1L)
  ignore(@zones.FootprintRunWindowMonitor::from_checkpoint(owner.checkpoint()))
}

///|
test "run window exports and forked aggregate arrays detach from owned state" {
  let owner = run_window_cp_owner()
  let saved = owner.checkpoint()
  let restored = @zones.FootprintRunWindowMonitor::from_checkpoint(saved)
  let branch = owner.fork()
  guard saved.current_window is Some(window) else { fail("window missing") }
  window.zones.clear()
  assert_eq(owner.checkpoint().runs.states.length(), 1)
  guard owner.checkpoint().current_window is Some(original) else {
    fail("window missing")
  }
  assert_eq(original.zones.length(), 1)
  let next = run_sample(3L, x=2.0)
  ignore(branch.update(next, run_shapes(next)))
  assert_eq(owner.checkpoint().runs.last_timestamp_us, Some(2L))
  assert_eq(restored.checkpoint().runs.last_timestamp_us, Some(2L))
}
