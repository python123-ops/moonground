///|
fn invalid(action : () -> Unit raise @types.GroundError) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid transit state was accepted")
  }
}

///|
fn gate(
  id : String,
  y : Double,
  band~ : Double = 0.05,
) -> @events.LineGate raise @types.GroundError {
  @events.LineGate::new(id, { x: 0.0, y, }, { x: 10.0, y, }, deadband_m=band)
}

///|
fn section(
  id~ : String = "aisle",
  reversed~ : Bool = false,
) -> @transit.Section raise @types.GroundError {
  @transit.Section::new(
    id,
    if reversed {
      "exit"
    } else {
      "entry"
    },
    @events.NegativeToPositive,
    if reversed {
      "entry"
    } else {
      "exit"
    },
    @events.NegativeToPositive,
  )
}

///|
fn gates(
  gap~ : Int64 = 500000L,
  capacity~ : Int32 = 10,
  limit~ : Double? = None,
  reversed~ : Bool = false,
  entry_band~ : Double = 0.05,
) -> @events.GateCounter raise @types.GroundError {
  let lines = [gate("entry", 0.0, band=entry_band), gate("exit", 2.0)]
  if reversed {
    let first = lines[0]
    lines[0] = lines[1]
    lines[1] = first
  }
  @events.GateCounter::new(
    "transit",
    lines,
    @events.GateConfig::new(
      max_gap_us=gap,
      max_tracks=capacity,
      max_position_std_m?=limit,
    ),
  )
}

///|
fn counter(
  gap~ : Int64 = 500000L,
  ttl~ : Int64 = 300000000L,
  limit~ : Double? = None,
  reverse_gates~ : Bool = false,
) -> @transit.TransitCounter raise @types.GroundError {
  @transit.TransitCounter::new(
    gates(gap~, limit~, reversed=reverse_gates),
    [section()],
    max_duration_us=ttl,
  )
}

///|
fn track(
  id : Int32,
  y : Double,
  time : Int64,
  x~ : Double = 5.0,
  segment~ : String = "1",
  status~ : @motion.MotionStatus = @motion.Ready,
  deviation~ : Double? = Some(0.1),
) -> @motion.TrackEstimate {
  {
    track_id: id,
    segment_id: segment,
    status,
    position: Some({ x, y, }),
    position_covariance: None,
    velocity: None,
    velocity_covariance: None,
    position_std_m: deviation,
    velocity_std_mps: None,
    speed_mps: None,
    observed_path_length_m: 0.0,
    net_displacement_m: 0.0,
    accepted_count: 1,
    last_accepted_timestamp_us: time,
    filtered_state: None,
    filtered_covariance: None,
  }
}

///|
fn frame(
  time : Int64,
  tracks : Array[@motion.TrackEstimate],
  closed~ : Array[String] = [],
) -> @motion.FrameResult {
  {
    session_id: "transit",
    timestamp_us: time,
    tracks,
    closed_segment_ids: closed,
  }
}

///|
fn started(engine : @transit.TransitCounter) -> Unit raise @types.GroundError {
  ignore(engine.update(frame(0L, [track(1, -1.0, 0L)])))
  ignore(engine.update(frame(100L, [track(1, 1.0, 100L)])))
}

///|
test "sections bind distinct known gates and enforce the total pending budget" {
  for bad in ["", String::make(129, 'x')] {
    invalid(() => {
      ignore(
        @transit.Section::new(
          bad,
          "entry",
          @events.NegativeToPositive,
          "exit",
          @events.NegativeToPositive,
        ),
      )
    })
  }
  invalid(() => {
    ignore(
      @transit.Section::new(
        "same",
        "entry",
        @events.NegativeToPositive,
        "entry",
        @events.PositiveToNegative,
      ),
    )
  })
  invalid(() => ignore(@transit.TransitCounter::new(gates(), [])))
  invalid(() => {
    ignore(@transit.TransitCounter::new(gates(), [section(), section()]))
  })
  let unknown = @transit.Section::new(
    "unknown",
    "absent",
    @events.NegativeToPositive,
    "exit",
    @events.NegativeToPositive,
  )
  invalid(() => ignore(@transit.TransitCounter::new(gates(), [unknown])))
  invalid(() => ignore(counter(ttl=0L)))
  let sections = Array::makei(16, index => section(id=index.to_string()))
  ignore(@transit.TransitCounter::new(gates(capacity=4096), sections))
  invalid(() => {
    ignore(@transit.TransitCounter::new(gates(capacity=4097), sections))
  })
  invalid(() => {
    ignore(
      @transit.TransitCounter::new(
        gates(),
        Array::makei(17, index => section(id=index.to_string())),
      ),
    )
  })
}

///|
test "disjoint brackets retain exact bounds and a positive relative time estimate" {
  let engine = counter()
  started(engine)
  let result = engine.update(frame(200L, [track(1, 3.0, 200L)]))
  assert_eq(result.pending_count, 0)
  assert_eq(result.cancellations.length(), 0)
  assert_eq(result.counts[0].completed, 1L)
  let transit = result.passages[0]
  assert_eq(transit.entry.from_timestamp_us, 0L)
  assert_eq(transit.exit.to_timestamp_us, 200L)
  assert_eq(transit.elapsed_lower_us, 0L)
  assert_eq(transit.elapsed_upper_us, 200L)
  assert_eq(transit.estimated_elapsed_us, 100.0)
}

///|
test "same-frame common-chord crossings follow geometry rather than gate configuration order" {
  for reverse_gates in [false, true] {
    let engine = counter(reverse_gates~)
    ignore(engine.update(frame(0L, [track(1, -1.0, 0L)])))
    let result = engine.update(frame(100L, [track(1, 3.0, 100L)]))
    assert_eq(result.passages.length(), 1)
    assert_eq(result.passages[0].estimated_elapsed_us, 50.0)
    assert_eq(result.passages[0].elapsed_lower_us, 0L)
    assert_eq(result.passages[0].elapsed_upper_us, 100L)
    assert_eq(result.pending_count, 0)
  }
}

///|
test "exit before entry is ignored before starting the later same-frame entry" {
  let engine = @transit.TransitCounter::new(gates(), [section(reversed=true)])
  ignore(engine.update(frame(0L, [track(1, -1.0, 0L)])))
  let result = engine.update(frame(100L, [track(1, 3.0, 100L)]))
  assert_eq(result.passages.length(), 0)
  assert_eq(result.cancellations.length(), 0)
  assert_eq(result.pending_count, 1)
  assert_eq(engine.checkpoint().pending[0].entry.gate_id, "exit")
}

///|
test "overlapping different chords cancel a fresh entry instead of inventing ordering" {
  let engine = counter()
  ignore(engine.update(frame(0L, [track(1, -1.0, 0L)])))
  ignore(engine.update(frame(100L, [track(1, 0.0, 100L)])))
  let result = engine.update(frame(200L, [track(1, 3.0, 200L)]))
  assert_eq(result.counting.crossings.length(), 2)
  assert_eq(result.passages.length(), 0)
  assert_eq(result.cancellations[0].reason, @transit.AmbiguousOrder)
  assert_eq(result.pending_count, 0)
}

///|
test "a delayed overlapping exit also cancels an earlier pending entry" {
  let engine = @transit.TransitCounter::new(gates(entry_band=1.5), [section()])
  ignore(engine.update(frame(0L, [track(1, -2.0, 0L)])))
  ignore(engine.update(frame(100L, [track(1, 1.0, 100L)])))
  assert_eq(engine.update(frame(200L, [track(1, 2.0, 200L)])).pending_count, 1)
  let result = engine.update(frame(300L, [track(1, 3.0, 300L)]))
  assert_eq(result.cancellations[0].reason, @transit.AmbiguousOrder)
  assert_eq(result.pending_count, 0)
}

///|
test "missing rejected quality-skipped closed and changed segments all lose continuity" {
  for kind in 0..<5 {
    let engine = counter(limit=Some(0.5))
    started(engine)
    let estimates = match kind {
      0 | 4 => []
      1 =>
        [
          {
            ..track(1, 1.0, 100L),
            status: @motion.RejectedInnovation,
            position: None,
          },
        ]
      2 => [track(1, 1.0, 200L, deviation=Some(0.6))]
      _ => [track(1, 1.0, 200L, segment="2")]
    }
    let result = engine.update(
      frame(200L, estimates, closed=if kind == 4 { ["1"] } else { [] }),
    )
    assert_eq(result.cancellations.length(), 1)
    assert_eq(result.cancellations[0].reason, @transit.Discontinuity)
    assert_eq(result.pending_count, 0)
  }
}

///|
test "initializing and uncertain positions remain usable without a ready speed" {
  let engine = counter()
  ignore(
    engine.update(frame(0L, [track(1, -1.0, 0L, status=@motion.Initializing)])),
  )
  ignore(
    engine.update(frame(100L, [track(1, 1.0, 100L, status=@motion.Uncertain)])),
  )
  assert_eq(
    engine.update(frame(200L, [track(1, 3.0, 200L, status=@motion.Uncertain)])).passages.length(),
    1,
  )
}

///|
test "the exact confirmation timeout wins before a new exit and discontinuity wins over timeout" {
  let engine = counter(ttl=100L)
  started(engine)
  assert_eq(engine.update(frame(199L, [track(1, 1.0, 199L)])).pending_count, 1)
  let expired = engine.update(frame(200L, [track(1, 3.0, 200L)]))
  assert_eq(expired.cancellations[0].reason, @transit.Expired)
  assert_eq(expired.passages.length(), 0)
  let missing = counter(ttl=100L)
  started(missing)
  assert_eq(
    missing.update(frame(200L, [])).cancellations[0].reason,
    @transit.Discontinuity,
  )
  let gap = counter(gap=100L)
  ignore(gap.update(frame(0L, [track(1, -1.0, 0L)])))
  ignore(gap.update(frame(50L, [track(1, 1.0, 50L)])))
  let reset = gap.update(frame(150L, [track(1, 3.0, 150L)]))
  assert_eq(reset.cancellations[0].reason, @transit.Discontinuity)
  assert_eq(reset.counting.crossings.length(), 0)
}

///|
test "reversing either configured boundary cancels a pending transit" {
  let entry_back = counter()
  started(entry_back)
  assert_eq(
    entry_back.update(frame(200L, [track(1, -1.0, 200L)])).cancellations[0].reason,
    @transit.Reversed,
  )
  let exit_back = counter()
  started(exit_back)
  ignore(exit_back.update(frame(200L, [track(1, 1.0, 200L, x=11.0)])))
  ignore(exit_back.update(frame(300L, [track(1, 3.0, 300L, x=11.0)])))
  let reversed = exit_back.update(frame(400L, [track(1, 1.0, 400L)]))
  assert_eq(reversed.cancellations[0].reason, @transit.Reversed)
  assert_eq(reversed.pending_count, 0)
}

///|
test "reentry replaces an older entry before a later same-frame exit completes" {
  let engine = counter()
  started(engine)
  ignore(engine.update(frame(200L, [track(1, 1.0, 200L, x=11.0)])))
  ignore(engine.update(frame(300L, [track(1, -1.0, 300L, x=11.0)])))
  ignore(engine.update(frame(400L, [track(1, -1.0, 400L)])))
  let result = engine.update(frame(500L, [track(1, 3.0, 500L)]))
  assert_eq(result.cancellations[0].reason, @transit.Reentered)
  assert_eq(result.cancellations[0].entry.to_timestamp_us, 100L)
  assert_eq(result.passages[0].entry.to_timestamp_us, 500L)
  assert_eq(result.passages[0].estimated_elapsed_us, 50.0)
}

///|
test "started gate counters detach without reconstructing historical entries" {
  let upstream = gates()
  ignore(upstream.update(frame(0L, [track(1, -1.0, 0L)])))
  ignore(upstream.update(frame(100L, [track(1, 1.0, 100L)])))
  let engine = @transit.TransitCounter::new(upstream, [section()])
  let result = engine.update(frame(200L, [track(1, 3.0, 200L)]))
  assert_eq(result.passages.length(), 0)
  assert_eq(result.counting.counts[0].negative_to_positive, 1L)
  assert_eq(result.counts[0].completed, 0L)
  assert_eq(upstream.checkpoint().last_timestamp_us, Some(100L))
}

///|
test "invalid frames and a saturated gate counter preserve the whole downstream transaction" {
  let engine = counter()
  started(engine)
  let before = @debug.to_string(engine.checkpoint())
  for
    bad in [
      frame(100L, []),
      frame(-1L, []),
      frame(200L, [track(1, 3.0, 200L), track(1, 3.0, 200L)]),
      frame(200L, [track(1, 0.0 / 0.0, 200L)]),
      { ..frame(200L, []), session_id: "different", },
    ] {
    invalid(() => ignore(engine.update(bad)))
    assert_eq(@debug.to_string(engine.checkpoint()), before)
  }
  let checkpoint = engine.checkpoint()
  checkpoint.counting.counts[1] = {
    ..checkpoint.counting.counts[1],
    negative_to_positive: 9223372036854775807L,
  }
  let saturated = @transit.TransitCounter::from_checkpoint(checkpoint)
  let saved = @debug.to_string(saturated.checkpoint())
  invalid(() => ignore(saturated.update(frame(200L, [track(1, 3.0, 200L)]))))
  assert_eq(@debug.to_string(saturated.checkpoint()), saved)
  assert_eq(
    saturated.update(frame(200L, [track(1, 1.0, 200L)])).pending_count,
    1,
  )
}

///|
test "checkpoint restore rejects damaged geometry identities TTL membership and total relations" {
  let engine = counter(ttl=1000L)
  started(engine)
  let saved = engine.checkpoint()
  let pending = saved.pending[0]
  for
    bad in [
      { ..saved, version: 2, },
      { ..saved, counts: [], },
      { ..saved, counts: [{ section_id: "aisle", completed: -1L, }], },
      { ..saved, counts: [{ section_id: "aisle", completed: 1L, }], },
      { ..saved, pending: [pending, pending], },
      { ..saved, pending: [{ ..pending, section_id: "unknown", }], },
      {
        ..saved,
        pending: [{ ..pending, entry: { ..pending.entry, segment_id: "2", }, }],
      },
      {
        ..saved,
        pending: [
          { ..pending, entry: { ..pending.entry, crossing_fraction: 0.4, }, },
        ],
      },
      {
        ..saved,
        pending: [
          {
            ..pending,
            entry: { ..pending.entry, position_m: { x: 6.0, y: 0.0, }, },
          },
        ],
      },
      {
        ..saved,
        pending: [
          { ..pending, entry: { ..pending.entry, to_timestamp_us: 101L, }, },
        ],
      },
      { ..saved, counting: { ..saved.counting, tracks: [], }, },
      { ..saved, max_duration_us: 0L, },
      {
        ..saved,
        counting: {
          ..saved.counting,
          last_timestamp_us: Some(1100L),
          tracks: [],
        },
      },
      {
        ..saved,
        counting: {
          ..saved.counting,
          counts: saved.counting.counts.map(count => {
            ..count,
            negative_to_positive: 0L,
          }),
        },
      },
    ] {
    invalid(() => ignore(@transit.TransitCounter::from_checkpoint(bad)))
  }
  assert_eq(
    @debug.to_string(
      @transit.TransitCounter::from_checkpoint(saved).checkpoint(),
    ),
    @debug.to_string(saved),
  )
}

///|
test "every checkpoint cut continues exact totals anchors pending state and cancellations" {
  let samples = [
    frame(0L, [track(1, -1.0, 0L)]),
    frame(100L, [track(1, 1.0, 100L)]),
    frame(200L, [track(1, 3.0, 200L)]),
    frame(300L, [track(1, -1.0, 300L)]),
    frame(400L, [track(1, 1.0, 400L)]),
    frame(500L, []),
    frame(600L, [track(1, -1.0, 600L, segment="2")]),
    frame(700L, [track(1, 3.0, 700L, segment="2")]),
  ]
  let complete = counter()
  let expected = samples.map(sample => @debug.to_string(complete.update(sample)))
  let final_state = @debug.to_string(complete.checkpoint())
  for cut in 0..<=samples.length() {
    let prefix = counter()
    for index in 0..<cut {
      ignore(prefix.update(samples[index]))
    }
    let restored = @transit.TransitCounter::from_checkpoint(prefix.checkpoint())
    for index in cut..<samples.length() {
      assert_eq(
        @debug.to_string(restored.update(samples[index])),
        expected[index],
      )
    }
    assert_eq(@debug.to_string(restored.checkpoint()), final_state)
  }
}

///|
test "checkpoint arrays and forks do not share mutable pending or total state" {
  let engine = counter()
  started(engine)
  let saved = engine.checkpoint()
  let restored = @transit.TransitCounter::from_checkpoint(saved)
  let branch = engine.fork()
  saved.pending.clear()
  saved.sections.clear()
  saved.counts.clear()
  saved.counting.tracks.clear()
  assert_eq(engine.checkpoint().pending.length(), 1)
  assert_eq(restored.checkpoint().pending.length(), 1)
  assert_eq(
    branch.update(frame(200L, [])).cancellations[0].reason,
    @transit.Discontinuity,
  )
  assert_eq(
    engine.update(frame(200L, [track(1, 3.0, 200L)])).counts[0].completed,
    1L,
  )
  assert_eq(restored.checkpoint().counts[0].completed, 0L)
  assert_eq(branch.checkpoint().counts[0].completed, 0L)
}

///|
test "Int64 maximum clocks and wide brackets never become floating absolute timestamps" {
  let engine = counter()
  let base = 9223372036854774807L
  ignore(engine.update(frame(base, [track(1, -1.0, base)])))
  ignore(engine.update(frame(base + 100L, [track(1, 1.0, base + 100L)])))
  let result = engine.update(frame(base + 200L, [track(1, 3.0, base + 200L)]))
  assert_eq(result.passages[0].estimated_elapsed_us, 100.0)
  assert_eq(result.passages[0].elapsed_upper_us, 200L)
  let wide = counter(gap=9223372036854775807L)
  ignore(wide.update(frame(0L, [track(1, -1.0, 0L)])))
  ignore(
    wide.update(
      frame(9223372036854775805L, [track(1, 1.0, 9223372036854775805L)]),
    ),
  )
  let ending = wide.update(
    frame(9223372036854775807L, [track(1, 3.0, 9223372036854775807L)]),
  )
  assert_eq(ending.passages[0].elapsed_upper_us, 9223372036854775807L)
  assert_true(@types.is_finite(ending.passages[0].estimated_elapsed_us))
  assert_true(ending.passages[0].estimated_elapsed_us > 0.0)
}

///|
test "multiple sections and identities produce bounded deterministic section then track order" {
  let sections = [section(id="second"), section(id="first")]
  let engine = @transit.TransitCounter::new(gates(capacity=32), sections)
  let initial = Array::makei(32, index => {
    track(32 - index, -1.0, 0L, segment=(32 - index).to_string())
  })
  ignore(engine.update(frame(0L, initial)))
  let result = engine.update(
    frame(
      100L,
      Array::makei(32, index => {
        track(32 - index, 3.0, 100L, segment=(32 - index).to_string())
      }),
    ),
  )
  assert_eq(result.passages.length(), 64)
  assert_eq(result.counts[0].completed, 32L)
  assert_eq(result.counts[1].completed, 32L)
  for index in 0..<64 {
    assert_eq(
      result.passages[index].section_id,
      if index < 32 {
        "second"
      } else {
        "first"
      },
    )
    assert_eq(result.passages[index].track_id, index % 32 + 1)
  }
}
