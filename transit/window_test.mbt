///|
fn windows(
  source~ : @transit.EvidenceTransitCheckpoint = evidence_counter().checkpoint(),
  width~ : Int64 = 1000L,
  origin~ : Int64 = 0L,
  limits~ : Array[Int64] = [0L, 100L, 200L, 9223372036854775807L],
) -> @transit.EvidenceTransitWindowCounter raise @types.GroundError {
  @transit.EvidenceTransitWindowCounter::new(
    source,
    window_us=width,
    origin_us=origin,
    duration_limits_us=limits,
  )
}

///|
fn window_stream() -> (
  @transit.EvidenceTransitCheckpoint,
  Array[@transit.EvidenceTransitFrame],
) raise @types.GroundError {
  let engine = evidence_counter()
  let initial = engine.checkpoint()
  let results : Array[@transit.EvidenceTransitFrame] = []
  for index, y in [-1.0, 1.0, 3.0, -1.0, 1.0] {
    let time = index.to_int64() * 100L
    results.push(engine.update(frame(time, [evidence_track(1, y, time)])))
  }
  results.push(engine.update(frame(500L, [])))
  for index, y in [-1.0, 1.0, -1.0, 1.0, 3.0] {
    let time = (index + 6).to_int64() * 100L
    results.push(engine.update(frame(time, [evidence_track(1, y, time)])))
  }
  (initial, results)
}

///|
test "window configuration validates the complete upstream state and bounds without observing its checkpoint" {
  let source = evidence_counter().checkpoint()
  let counter = windows(source~)
  assert_true(counter.checkpoint().current_window is None)
  assert_true(counter.checkpoint().last_timestamp_us is None)
  for bad in [0L, -1L] {
    invalid(() => ignore(windows(source~, width=bad)))
  }
  invalid(() => ignore(windows(source~, origin=-1L)))
  for
    limits in [
      [],
      [-1L],
      [1L, 1L],
      [2L, 1L],
      Array::makei(17, index => index.to_int64()),
    ] {
    invalid(() => ignore(windows(source~, limits~)))
  }
  invalid(() => ignore(windows(source={ ..source, version: 2, })))
  let started = evidence_pending_counter().checkpoint()
  invalid(() => ignore(windows(source=started, origin=101L)))
  ignore(
    windows(source=started, origin=100L, limits=[0L, 9223372036854775807L]),
  )
}

///|
test "started upstream totals and pending entries establish only a baseline and later completions enter the first observed bucket" {
  let engine = evidence_pending_counter()
  let counter = windows(source=engine.checkpoint(), width=100L)
  let initial = counter.checkpoint()
  assert_eq(initial.baseline_timestamp_us, Some(100L))
  assert_eq(initial.last_timestamp_us, Some(100L))
  assert_true(initial.current_window is None)
  let complete = engine.update(frame(200L, [evidence_track(1, 3.0, 200L)]))
  let result = counter.update(complete)
  assert_true(result.closed_window is None)
  assert_eq(result.unobserved_windows, 0L)
  assert_eq(result.current_window.start_us, 200L)
  assert_eq(result.current_window.input_frames, 1L)
  assert_eq(result.current_window.sections[0].completed, 1L)
  let after = windows(source=engine.checkpoint())
  assert_eq(after.checkpoint().baseline_counts[0].completed, 1L)
  assert_true(after.checkpoint().current_window is None)
  let empty = after.update(engine.update(frame(300L, [])))
  assert_eq(empty.current_window.sections[0].completed, 0L)
}

///|
test "duration limits classify interval equality and uncertainty without treating cancellations as zero durations" {
  let engine = evidence_counter()
  let counter = windows(source=engine.checkpoint(), limits=[
    0L, 99L, 100L, 199L, 200L, 299L, 300L, 9223372036854775807L,
  ])
  for index, y in [-1.0, 1.0, 1.5, 3.0, -1.0, 1.0, 3.0] {
    let time = index.to_int64() * 100L
    ignore(
      counter.update(engine.update(frame(time, [evidence_track(1, y, time)]))),
    )
  }
  let aggregate = counter.checkpoint().current_window.unwrap().sections[0]
  assert_eq(aggregate.completed, 2L)
  assert_eq(aggregate.duration_limits[0].exceeded, 1L)
  assert_eq(aggregate.duration_limits[0].indeterminate, 1L)
  assert_eq(aggregate.duration_limits[1].exceeded, 1L)
  assert_eq(aggregate.duration_limits[2].indeterminate, 2L)
  assert_eq(aggregate.duration_limits[4].within, 1L)
  assert_eq(aggregate.duration_limits[6].within, 2L)
  assert_eq(aggregate.duration_limits[7].within, 2L)
  for row in aggregate.duration_limits {
    assert_eq(
      row.within + row.exceeded + row.indeterminate,
      aggregate.completed,
    )
  }
}

///|
test "empty frames roll fixed buckets forward and skipped buckets remain unobserved" {
  let engine = evidence_counter()
  let counter = windows(width=100L)
  let first = counter.update(engine.update(frame(50L, [])))
  assert_eq(first.current_window.start_us, 0L)
  assert_eq(first.current_window.first_timestamp_us, 50L)
  let inside = counter.update(engine.update(frame(99L, [])))
  assert_eq(inside.current_window.input_frames, 2L)
  assert_true(inside.closed_window is None)
  let boundary = counter.update(engine.update(frame(100L, [])))
  assert_eq(boundary.closed_window.unwrap().last_timestamp_us, 99L)
  assert_eq(boundary.current_window.start_us, 100L)
  assert_eq(boundary.unobserved_windows, 0L)
  let skipped = counter.update(engine.update(frame(500L, [])))
  assert_eq(skipped.closed_window.unwrap().start_us, 100L)
  assert_eq(skipped.current_window.start_us, 500L)
  assert_eq(skipped.unobserved_windows, 3L)
}

///|
test "all checkpoint cuts resume identical window frames classifications cancellations and current state" {
  let (source, stream) = window_stream()
  let full = windows(source~, width=250L)
  let expected = stream.map(frame => @debug.to_string(full.update(frame)))
  let state = @debug.to_string(full.checkpoint())
  for cut in 0..<=stream.length() {
    let prefix = windows(source~, width=250L)
    for index in 0..<cut {
      ignore(prefix.update(stream[index]))
    }
    let resumed = @transit.EvidenceTransitWindowCounter::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<stream.length() {
      assert_eq(
        @debug.to_string(resumed.update(stream[index])),
        expected[index],
      )
    }
    assert_eq(@debug.to_string(resumed.checkpoint()), state)
  }
}

///|
test "exact clocks past binary64 precision and origins preserve confirmation bucket boundaries" {
  let engine = evidence_counter()
  let base = 9007199254740993L
  let counter = windows(width=10L, origin=base)
  let first = counter.update(engine.update(frame(base, [])))
  assert_eq(first.current_window.start_us, base)
  assert_eq(first.current_window.end_exclusive_us, Some(base + 10L))
  let next = counter.update(engine.update(frame(base + 10L, [])))
  assert_eq(next.current_window.start_us, base + 10L)
  assert_eq(next.closed_window.unwrap().start_us, base)
  let before = @debug.to_string(counter.checkpoint())
  invalid(() => {
    ignore(
      counter.update({
        ..engine.update(frame(base + 11L, [])),
        counting: {
          counting: {
            session_id: "transit",
            timestamp_us: base - 1L,
            crossings: [],
            counts: engine.checkpoint().counting.counts,
          },
          evidence: [],
        },
      }),
    )
  })
  assert_eq(@debug.to_string(counter.checkpoint()), before)
}

///|
test "maximum clocks distinguish an exclusive MAX boundary from the terminal bucket beyond the clock domain" {
  let engine = evidence_counter()
  let maximum = 9223372036854775807L
  let counter = windows(width=maximum)
  let first = counter.update(engine.update(frame(0L, [])))
  assert_eq(first.current_window.end_exclusive_us, Some(maximum))
  let final_frame = counter.update(engine.update(frame(maximum, [])))
  assert_eq(final_frame.closed_window.unwrap().end_exclusive_us, Some(maximum))
  assert_eq(final_frame.current_window.start_us, maximum)
  assert_true(final_frame.current_window.end_exclusive_us is None)
  ignore(
    @transit.EvidenceTransitWindowCounter::from_checkpoint(counter.checkpoint()),
  )
  let one = windows(width=1L)
  let raw = evidence_counter()
  ignore(one.update(raw.update(frame(0L, []))))
  assert_eq(
    one.update(raw.update(frame(maximum, []))).unobserved_windows,
    maximum - 1L,
  )
}

///|
test "five cancellation reasons remain separate observed outcomes and repeated causal cancellation is retained" {
  for
    reason in [
      @transit.Discontinuity,
      @transit.Expired,
      @transit.Reentered,
      @transit.Reversed,
      @transit.AmbiguousOrder,
    ] {
    let engine = evidence_pending_counter()
    let counter = windows(source=engine.checkpoint())
    let source = engine.update(frame(200L, []))
    let cancel = { ..source.cancellations[0], reason, }
    let result = counter.update({ ..source, cancellations: [cancel, cancel], })
    let rows = result.current_window.sections[0].cancellations
    for row in rows {
      assert_eq(row.count, if row.reason == reason { 2L } else { 0L })
    }
    assert_eq(result.current_window.sections[0].completed, 0L)
  }
}

///|
test "real reentry cancellation and same-frame completion can both contribute to one section" {
  let engine = evidence_pending_counter()
  let counter = windows(source=engine.checkpoint())
  for
    (time, x, y) in [
      (200L, 20.0, 1.0),
      (300L, 20.0, -1.0),
      (400L, 5.0, -1.0),
      (500L, 5.0, 3.0),
    ] {
    ignore(
      counter.update(
        engine.update(frame(time, [evidence_track(1, y, time, x~)])),
      ),
    )
  }
  let aggregate = counter.checkpoint().current_window.unwrap().sections[0]
  assert_eq(aggregate.completed, 1L)
  assert_eq(aggregate.cancellations[2].count, 1L)
}

///|
test "long uncertain observations may expire a gate anchor while a pending entry waits for a later short exit chord" {
  for cancel in [false, true] {
    let engine = evidence_counter(gap=300L, ttl=1000L)
    let counter = windows(source=engine.checkpoint(), limits=[300L, 600L])
    for
      (time, y) in [
        (0L, -1.0),
        (100L, 1.0),
        (200L, 2.0),
        (300L, 2.0),
        (400L, 2.0),
      ] {
      ignore(
        counter.update(engine.update(frame(time, [evidence_track(1, y, time)]))),
      )
    }
    assert_eq(engine.checkpoint().pending.length(), 1)
    assert_true(engine.checkpoint().counting.tracks[0].anchors[1] is None)
    if cancel {
      let result = counter.update(engine.update(frame(500L, [])))
      assert_eq(result.current_window.sections[0].cancellations[0].count, 1L)
      assert_eq(result.current_window.sections[0].completed, 0L)
    } else {
      ignore(
        counter.update(
          engine.update(frame(500L, [evidence_track(1, 1.0, 500L)])),
        ),
      )
      let complete = engine.update(frame(600L, [evidence_track(1, 3.0, 600L)]))
      assert_eq(complete.passages[0].exit.from_timestamp_us, 500L)
      assert_eq(complete.passages[0].elapsed_lower_us, 400L)
      let result = counter.update(complete)
      assert_eq(result.current_window.sections[0].completed, 1L)
      assert_eq(
        result.current_window.sections[0].duration_limits[0].exceeded,
        1L,
      )
      assert_eq(result.current_window.sections[0].duration_limits[1].within, 1L)
    }
  }
}

///|
test "same-frame reversed exit may cancel a just-created forward entry without inventing a positive duration" {
  let source = evidence_counter().checkpoint()
  let opposite = @transit.EvidenceTransitCounter::new(
    @events.EvidenceGateCounter::from_checkpoint(source.counting),
    [
      @transit.Section::new(
        "aisle",
        "entry",
        @events.NegativeToPositive,
        "exit",
        @events.PositiveToNegative,
      ),
    ],
  )
  let counter = windows(source=opposite.checkpoint())
  ignore(
    counter.update(opposite.update(frame(0L, [evidence_track(1, -1.0, 0L)]))),
  )
  let result = counter.update(
    opposite.update(frame(100L, [evidence_track(1, 3.0, 100L)])),
  )
  assert_eq(result.current_window.sections[0].completed, 0L)
  assert_eq(result.current_window.sections[0].cancellations[3].count, 1L)
}

///|
test "malformed passage geometry duration duplicate identities and missing current exit preserve rollover and allow same-time retry" {
  let (source, stream) = window_stream()
  let counter = windows(source~, width=150L)
  ignore(counter.update(stream[0]))
  ignore(counter.update(stream[1]))
  let complete = stream[2]
  let value = complete.passages[0]
  let before = @debug.to_string(counter.checkpoint())
  for
    bad in [
      { ..complete, passages: [], },
      { ..complete, passages: [value, value], },
      {
        ..complete,
        passages: [{ ..value, elapsed_upper_us: value.elapsed_upper_us + 1L, }],
      },
      { ..complete, passages: [{ ..value, estimated_elapsed_us: 1.0 / 0.0, }], },
      {
        ..complete,
        passages: [
          {
            ..value,
            entry: { ..value.entry, position_m: { x: 4.0, y: 0.0, }, },
          },
        ],
      },
      {
        ..complete,
        counting: {
          ..complete.counting,
          counting: { ..complete.counting.counting, crossings: [], },
        },
      },
    ] {
    invalid(() => ignore(counter.update(bad)))
    assert_eq(@debug.to_string(counter.checkpoint()), before)
  }
  let retry = counter.update(complete)
  assert_true(retry.closed_window is Some(_))
  assert_eq(retry.current_window.sections[0].completed, 1L)
}

///|
test "invalid evidence diagnostics groups source counts session and timestamps leave the statistics watermark reusable" {
  let (source, stream) = window_stream()
  let counter = windows(source~)
  ignore(counter.update(stream[0]))
  let frame = stream[1]
  let group = frame.counting
  let row = group.evidence[0]
  let before = @debug.to_string(counter.checkpoint())
  for
    bad in [
      { ..frame, counting: { ..group, evidence: [], }, },
      {
        ..frame,
        counting: {
          ..group,
          evidence: [{ ..row, normal_std_m: 0.0, }, group.evidence[1]],
        },
      },
      {
        ..frame,
        counting: {
          ..group,
          evidence: [{ ..row, lower_m: 1.0 / 0.0, }, group.evidence[1]],
        },
      },
      {
        ..frame,
        counting: {
          ..group,
          evidence: [{ ..row, side: 0, }, group.evidence[1]],
        },
      },
      {
        ..frame,
        counting: {
          ..group,
          evidence: [{ ..row, segment_id: "01", }, group.evidence[1]],
        },
      },
      {
        ..frame,
        counting: {
          ..group,
          counting: { ..group.counting, session_id: "other", },
        },
      },
      {
        ..frame,
        counting: { ..group, counting: { ..group.counting, counts: [], }, },
      },
      { ..frame, counts: [{ section_id: "other", completed: 0L, }], },
      { ..frame, counts: [{ ..frame.counts[0], completed: 1L, }], },
      { ..frame, pending_count: -1, },
    ] {
    invalid(() => ignore(counter.update(bad)))
    assert_eq(@debug.to_string(counter.checkpoint()), before)
  }
  invalid(() => ignore(counter.update(stream[0])))
  ignore(counter.update(frame))
}

///|
test "invalid cancellation geometry section identity and future confirmation do not create false reason counts" {
  let engine = evidence_pending_counter()
  let counter = windows(source=engine.checkpoint())
  let valid = engine.update(frame(200L, []))
  let cancellation = valid.cancellations[0]
  let before = @debug.to_string(counter.checkpoint())
  for
    bad in [
      { ..cancellation, section_id: "other", },
      { ..cancellation, track_id: 2, },
      {
        ..cancellation,
        entry: { ..cancellation.entry, to_timestamp_us: 201L, },
      },
      {
        ..cancellation,
        entry: { ..cancellation.entry, crossing_fraction: 0.4, },
      },
    ] {
    invalid(() => ignore(counter.update({ ..valid, cancellations: [bad], })))
    assert_eq(@debug.to_string(counter.checkpoint()), before)
  }
  ignore(counter.update(valid))
}

///|
test "window checkpoints reject forged bounds chronology missing aggregates and baseline count changes" {
  let (source, stream) = window_stream()
  let counter = windows(source~)
  for frame in stream[0:3] {
    ignore(counter.update(frame))
  }
  let saved = counter.checkpoint()
  let window = saved.current_window.unwrap()
  for
    bad in [
      { ..saved, version: 2, },
      { ..saved, window_us: 0L, },
      { ..saved, current_window: None, },
      { ..saved, last_timestamp_us: None, },
      { ..saved, baseline_timestamp_us: Some(200L), },
      { ..saved, baseline_counts: [{ ..saved.counts[0], completed: 2L, }], },
      { ..saved, current_window: Some({ ..window, start_us: 1L, }), },
      { ..saved, current_window: Some({ ..window, end_exclusive_us: None, }), },
      { ..saved, current_window: Some({ ..window, last_timestamp_us: 199L, }), },
      {
        ..saved,
        current_window: Some({ ..window, first_timestamp_us: 201L, }),
      },
      { ..saved, current_window: Some({ ..window, input_frames: 202L, }), },
    ] {
    invalid(() => {
      ignore(@transit.EvidenceTransitWindowCounter::from_checkpoint(bad))
    })
  }
}

///|
test "checkpoint classification partitions monotonicity zero maximum and reason order validate without overflow" {
  let (source, stream) = window_stream()
  let counter = windows(source~)
  for frame in stream[0:3] {
    ignore(counter.update(frame))
  }
  let saved = counter.checkpoint()
  let window = saved.current_window.unwrap()
  let section = window.sections[0]
  let row = section.duration_limits[0]
  for
    bad_rows in [
      [],
      [{ ..row, within: 1L, indeterminate: 0L, }, ..section.duration_limits[1:]],
      [
        { ..row, exceeded: 9223372036854775807L, },
        ..section.duration_limits[1:],
      ],
      [{ ..row, indeterminate: -1L, }, ..section.duration_limits[1:]],
      [
        ..section.duration_limits[0:3],
        { ..section.duration_limits[3], within: 0L, indeterminate: 1L, },
      ],
    ] {
    invalid(() => {
      ignore(
        @transit.EvidenceTransitWindowCounter::from_checkpoint({
          ..saved,
          current_window: Some({
            ..window,
            sections: [{ ..section, duration_limits: bad_rows, }],
          }),
        }),
      )
    })
  }
  invalid(() => {
    ignore(
      @transit.EvidenceTransitWindowCounter::from_checkpoint({
        ..saved,
        current_window: Some({
          ..window,
          sections: [
            {
              ..section,
              cancellations: [
                { ..section.cancellations[0], reason: @transit.Expired, },
                ..section.cancellations[1:],
              ],
            },
          ],
        }),
      }),
    )
  })
}

///|
test "started baseline enforces strict later samples and exact frame count bounds" {
  let engine = evidence_pending_counter()
  let counter = windows(source=engine.checkpoint())
  ignore(counter.update(engine.update(frame(101L, []))))
  let saved = counter.checkpoint()
  let current = saved.current_window.unwrap()
  for
    bad in [
      { ..saved, current_window: Some({ ..current, input_frames: 2L, }), },
      {
        ..saved,
        current_window: Some({ ..current, first_timestamp_us: 100L, }),
      },
      { ..saved, baseline_timestamp_us: Some(102L), },
    ] {
    invalid(() => {
      ignore(@transit.EvidenceTransitWindowCounter::from_checkpoint(bad))
    })
  }
  let initial = windows(source=engine.checkpoint()).checkpoint()
  ignore(@transit.EvidenceTransitWindowCounter::from_checkpoint(initial))
}

///|
test "saved totals and per-section cancellations cannot exceed the observed source frame capacity" {
  let (source, stream) = window_stream()
  let counter = windows(source~)
  for frame in stream[0:3] {
    ignore(counter.update(frame))
  }
  let saved = counter.checkpoint()
  let current = saved.current_window.unwrap()
  let aggregate = current.sections[0]
  let too_many = {
    ..aggregate,
    completed: 11L,
    duration_limits: aggregate.duration_limits.map(row => {
      ..row,
      within: row.within * 11L,
      exceeded: row.exceeded * 11L,
      indeterminate: row.indeterminate * 11L,
    }),
  }
  invalid(() => {
    ignore(
      @transit.EvidenceTransitWindowCounter::from_checkpoint({
        ..saved,
        counts: [{ ..saved.counts[0], completed: 11L, }],
        current_window: Some({
          ..current,
          input_frames: 1L,
          sections: [too_many],
        }),
      }),
    )
  })
  invalid(() => {
    ignore(
      @transit.EvidenceTransitWindowCounter::from_checkpoint({
        ..saved,
        current_window: Some({
          ..current,
          input_frames: 1L,
          sections: [
            {
              ..aggregate,
              cancellations: [
                { ..aggregate.cancellations[0], count: 21L, },
                ..aggregate.cancellations[1:],
              ],
            },
          ],
        }),
      }),
    )
  })
  let engine = @transit.EvidenceTransitCounter::new(
    evidence_gates(capacity=1),
    [section(id="a"), section(id="b")],
  )
  let windows = windows(source=engine.checkpoint())
  ignore(
    windows.update(engine.update(frame(0L, [evidence_track(1, -1.0, 0L)]))),
  )
  ignore(
    windows.update(engine.update(frame(100L, [evidence_track(1, 1.0, 100L)]))),
  )
  let result = engine.update(frame(200L, []))
  let cancellation = result.cancellations[0]
  invalid(() => {
    ignore(
      windows.update({
        ..result,
        cancellations: [cancellation, cancellation, cancellation],
      }),
    )
  })
  ignore(windows.update(result))
}

///|
test "late cancellation exhaustion rolls back the candidate aggregate and permits corrected same-time retry" {
  let engine = evidence_pending_counter()
  let cancel = engine.update(frame(200L, []))
  let counter = windows(width=9223372036854775807L)
  let raw = evidence_counter()
  ignore(counter.update(raw.update(frame(0L, []))))
  let saved = counter.checkpoint()
  let original = saved.current_window.unwrap()
  let section = original.sections[0]
  let near_end = 9223372036854775805L
  let seeded = @transit.EvidenceTransitWindowCounter::from_checkpoint({
    ..saved,
    last_timestamp_us: Some(near_end),
    current_window: Some({
      ..original,
      last_timestamp_us: near_end,
      input_frames: near_end + 1L,
      sections: [
        {
          ..section,
          cancellations: [
            { ..section.cancellations[0], count: 9223372036854775807L, },
            ..section.cancellations[1:],
          ],
        },
      ],
    }),
  })
  let current = {
    ..cancel,
    counting: {
      counting: { ..cancel.counting.counting, timestamp_us: near_end + 1L, },
      evidence: [],
    },
  }
  let before = @debug.to_string(seeded.checkpoint())
  invalid(() => ignore(seeded.update(current)))
  assert_eq(@debug.to_string(seeded.checkpoint()), before)
  let retried = seeded.update({ ..current, cancellations: [], })
  assert_eq(retried.current_window.input_frames, near_end + 2L)
}

///|
test "returned windows nested arrays constructor sources checkpoints and forks have independent ownership" {
  let (source, stream) = window_stream()
  let limits = [0L, 200L]
  let counter = windows(source~, limits~)
  ignore(counter.update(stream[0]))
  let branch = counter.fork()
  let saved = counter.checkpoint()
  let restored = @transit.EvidenceTransitWindowCounter::from_checkpoint(saved)
  let before = @debug.to_string(counter.checkpoint())
  limits.clear()
  source.sections.clear()
  source.counting.gates.clear()
  saved.gates.clear()
  saved.baseline_counts.clear()
  saved.current_window.unwrap().sections[0].duration_limits.clear()
  assert_eq(@debug.to_string(counter.checkpoint()), before)
  let output = branch.update(stream[1])
  assert_eq(
    @debug.to_string(output),
    @debug.to_string(restored.update(stream[1])),
  )
  output.current_window.sections[0].cancellations.clear()
  assert_eq(
    @debug.to_string(branch.checkpoint()),
    @debug.to_string(restored.checkpoint()),
  )
}

///|
test "state size is independent of the number of supplied frames and completed passage histories" {
  let engine = evidence_counter()
  let counter = windows(width=1000000L)
  for index in 0..<300 {
    let time = index.to_int64() * 100L
    let y = match index % 4 {
      0 => -1.0
      1 => 1.0
      2 => 3.0
      _ => 1.0
    }
    ignore(
      counter.update(engine.update(frame(time, [evidence_track(1, y, time)]))),
    )
  }
  let saved = counter.checkpoint()
  assert_eq(saved.sections.length(), 1)
  assert_eq(saved.current_window.unwrap().sections.length(), 1)
  assert_eq(
    saved.current_window.unwrap().sections[0].duration_limits.length(),
    4,
  )
  assert_eq(saved.current_window.unwrap().sections[0].cancellations.length(), 5)
  assert_eq(saved.current_window.unwrap().input_frames, 300L)
  ignore(@transit.EvidenceTransitWindowCounter::from_checkpoint(saved))
}
