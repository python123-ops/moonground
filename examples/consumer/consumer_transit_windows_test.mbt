///|
test "packaged transit windows start after an existing pending checkpoint without backfilling history" {
  let (session, landmarks, left, middle, right) = consumer_guarded_transit(
    @health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  ignore(session.update(0L, landmarks, [left]))
  assert_eq(
    session.update(100000L, landmarks, [middle]).analysis.transit.pending_count,
    1,
  )
  let upstream = session.checkpoint().analysis.transit
  let windows = @transit.EvidenceTransitWindowCounter::new(
    upstream,
    window_us=100000L,
    duration_limits_us=[0L, 200000L, 9223372036854775807L],
  )
  assert_true(windows.checkpoint().current_window is None)
  assert_eq(windows.checkpoint().last_timestamp_us, Some(100000L))
  let exit = session.update(200000L, landmarks, [right]).analysis.transit
  assert_eq(exit.passages.length(), 1)
  let result = windows.update(exit)
  assert_true(result.closed_window is None)
  assert_eq(result.unobserved_windows, 0L)
  assert_eq(result.current_window.start_us, 200000L)
  assert_eq(result.current_window.input_frames, 1L)
  assert_eq(result.current_window.sections[0].completed, 1L)
  assert_eq(result.current_window.sections[0].duration_limits[0].within, 0L)
  assert_eq(result.current_window.sections[0].duration_limits[1].within, 1L)
  let restored = @transit.EvidenceTransitWindowCounter::from_checkpoint(
    windows.checkpoint(),
  )
  assert_eq(
    @debug.to_string(restored.checkpoint()),
    @debug.to_string(windows.checkpoint()),
  )
  assert_eq(upstream.pending.length(), 1)
}

///|
test "packaged transit windows count health cancellation separately and reject a late malformed rollover atomically" {
  let (session, landmarks, left, middle, right) = consumer_guarded_transit(
    @health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  let windows = @transit.EvidenceTransitWindowCounter::new(
    session.checkpoint().analysis.transit,
    window_us=100000L,
    duration_limits_us=[0L, 9223372036854775807L],
  )
  ignore(windows.update(session.update(0L, landmarks, [left]).analysis.transit))
  ignore(
    windows.update(
      session.update(100000L, landmarks, [middle]).analysis.transit,
    ),
  )
  let overflow_session = session.fork()
  let same_bucket = overflow_session.update(150000L, [], [right]).analysis.transit
  let saved = windows.checkpoint()
  let current = saved.current_window.unwrap()
  let saturated_sections = current.sections.copy()
  let saturated_reasons = current.sections[0].cancellations.copy()
  saturated_reasons[0] = {
    ..saturated_reasons[0],
    count: 9223372036854775807L,
  }
  saturated_sections[0] = {
    ..saturated_sections[0],
    cancellations: saturated_reasons,
  }
  let exhausted = @transit.EvidenceTransitWindowCounter::from_checkpoint({
    ..saved,
    window_us: 9223372036854775807L,
    last_timestamp_us: Some(9223372036854775805L),
    current_window: Some({
      start_us: 0L,
      end_exclusive_us: Some(9223372036854775807L),
      first_timestamp_us: 0L,
      last_timestamp_us: 9223372036854775805L,
      input_frames: 9223372036854775806L,
      sections: saturated_sections,
    }),
  })
  let late = {
    ..same_bucket,
    counting: {
      ..same_bucket.counting,
      counting: {
        ..same_bucket.counting.counting,
        timestamp_us: 9223372036854775806L,
      },
    },
  }
  let before_overflow = @debug.to_string(exhausted.checkpoint())
  try exhausted.update(late) catch {
    _ => ()
  } noraise {
    _ => fail("exhausted cancellation count must preserve the full window")
  }
  assert_eq(@debug.to_string(exhausted.checkpoint()), before_overflow)
  let corrected = exhausted.update({ ..late, cancellations: [], })
  assert_eq(corrected.timestamp_us, 9223372036854775806L)
  assert_eq(
    corrected.current_window.sections[0].cancellations[0].count,
    9223372036854775807L,
  )
  let blocked = session.update(300000L, [], [right]).analysis.transit
  assert_eq(blocked.cancellations[0].reason, @transit.Discontinuity)
  let before = @debug.to_string(windows.checkpoint())
  let invalid = {
    ..blocked,
    counts: blocked.counts.map(value => { ..value, completed: 1L, }),
  }
  try windows.update(invalid) catch {
    _ => ()
  } noraise {
    _ => fail("omitted passage must discard the entire rollover")
  }
  assert_eq(@debug.to_string(windows.checkpoint()), before)
  let forked = windows.fork()
  let actual = windows.update(blocked)
  assert_eq(@debug.to_string(actual), @debug.to_string(forked.update(blocked)))
  assert_eq(actual.unobserved_windows, 1L)
  assert_eq(actual.closed_window.unwrap().start_us, 100000L)
  assert_eq(actual.current_window.sections[0].completed, 0L)
  assert_eq(actual.current_window.sections[0].cancellations[0].count, 1L)
  for limit in actual.current_window.sections[0].duration_limits {
    assert_eq(limit.within, 0L)
    assert_eq(limit.exceeded, 0L)
    assert_eq(limit.indeterminate, 0L)
  }
}

///|
test "packaged transit windows distinguish an exclusive Int64 maximum boundary from the terminal bucket" {
  let (session, landmarks, left, _, right) = consumer_guarded_transit(
    @health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  let windows = @transit.EvidenceTransitWindowCounter::new(
    session.checkpoint().analysis.transit,
    window_us=9223372036854775807L,
    duration_limits_us=[0L, 1L, 9223372036854775807L],
  )
  let first = windows.update(
    session.update(9223372036854775806L, landmarks, [left]).analysis.transit,
  )
  assert_eq(first.current_window.end_exclusive_us, Some(9223372036854775807L))
  let last_window_result = windows.update(
    session.update(9223372036854775807L, landmarks, [right]).analysis.transit,
  )
  assert_eq(
    last_window_result.closed_window.unwrap().end_exclusive_us,
    Some(9223372036854775807L),
  )
  assert_eq(last_window_result.current_window.start_us, 9223372036854775807L)
  assert_true(last_window_result.current_window.end_exclusive_us is None)
  assert_eq(last_window_result.current_window.input_frames, 1L)
  assert_eq(
    @debug.to_string(
      @transit.EvidenceTransitWindowCounter::from_checkpoint(
        windows.checkpoint(),
      ).checkpoint(),
    ),
    @debug.to_string(windows.checkpoint()),
  )
}
