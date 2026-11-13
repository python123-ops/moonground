///|
fn evidence_track(
  id : Int32,
  y : Double,
  time : Int64,
  x~ : Double = 5.0,
  segment~ : String = "1",
  status~ : @motion.MotionStatus = @motion.Ready,
  deviation~ : Double? = Some(0.1),
  covariance~ : @types.Covariance2 = @types.Covariance2::isotropic(0.1),
) -> @motion.TrackEstimate raise @types.GroundError {
  {
    ..track(id, y, time, x~, segment~, status~, deviation~),
    position_covariance: Some(covariance),
  }
}

///|
fn evidence_gates(
  gap~ : Int64 = 500000L,
  capacity~ : Int32 = 10,
  limit~ : Double? = None,
  reverse~ : Bool = false,
  multiplier~ : Double = 2.0,
) -> @events.EvidenceGateCounter raise @types.GroundError {
  let definition = gates(gap~, capacity~, limit~, reversed=reverse).checkpoint()
  @events.EvidenceGateCounter::new(
    "transit",
    definition.gates,
    definition.config,
    sigma_multiplier=multiplier,
  )
}

///|
fn evidence_counter(
  gap~ : Int64 = 500000L,
  ttl~ : Int64 = 300000000L,
  limit~ : Double? = None,
  reverse~ : Bool = false,
  multiplier~ : Double = 2.0,
) -> @transit.EvidenceTransitCounter raise @types.GroundError {
  @transit.EvidenceTransitCounter::new(
    evidence_gates(gap~, limit~, reverse~, multiplier~),
    [section()],
    max_duration_us=ttl,
  )
}

///|
fn evidence_pending_counter(
  ttl~ : Int64 = 300000000L,
  limit~ : Double? = None,
) -> @transit.EvidenceTransitCounter raise @types.GroundError {
  let engine = evidence_counter(ttl~, limit~)
  ignore(engine.update(frame(0L, [evidence_track(1, -1.0, 0L)])))
  ignore(engine.update(frame(100L, [evidence_track(1, 1.0, 100L)])))
  engine
}

///|
fn corner() -> @transit.EvidenceTransitCounter raise @types.GroundError {
  @transit.EvidenceTransitCounter::new(
    @events.EvidenceGateCounter::new(
      "transit",
      [
        @events.LineGate::new("entry", { x: -10.0, y: 0.0, }, {
          x: 10.0,
          y: 0.0,
        }),
        @events.LineGate::new("exit", { x: 0.0, y: -10.0, }, {
          x: 0.0,
          y: 10.0,
        }),
      ],
      @events.GateConfig::new(max_tracks=10),
    ),
    [
      @transit.Section::new(
        "corner",
        "entry",
        @events.NegativeToPositive,
        "exit",
        @events.PositiveToNegative,
      ),
    ],
  )
}

///|
test "evidence sections retain bounded detached configuration without reconstructing an earlier entry" {
  let source = evidence_gates()
  ignore(source.update(frame(0L, [evidence_track(1, -1.0, 0L)])))
  ignore(source.update(frame(100L, [evidence_track(1, 1.0, 100L)])))
  let engine = @transit.EvidenceTransitCounter::new(source, [section()])
  assert_eq(engine.checkpoint().pending.length(), 0)
  let isolated = engine.update(frame(200L, [evidence_track(1, 3.0, 200L)]))
  assert_eq(isolated.passages.length(), 0)
  assert_eq(isolated.counting.counting.counts[0].negative_to_positive, 1L)
  assert_eq(source.checkpoint().last_timestamp_us, Some(100L))
  invalid(() => {
    ignore(
      @transit.EvidenceTransitCounter::new(
        evidence_gates(),
        [],
        max_duration_us=1L,
      ),
    )
  })
  invalid(() => {
    ignore(
      @transit.EvidenceTransitCounter::new(
        evidence_gates(),
        [section()],
        max_duration_us=0L,
      ),
    )
  })
  invalid(() => {
    ignore(
      @transit.EvidenceTransitCounter::new(evidence_gates(), [
        section(),
        section(),
      ]),
    )
  })
  let sections = Array::makei(16, index => section(id=index.to_string()))
  ignore(
    @transit.EvidenceTransitCounter::new(
      evidence_gates(capacity=4096),
      sections,
    ),
  )
  invalid(() => {
    ignore(
      @transit.EvidenceTransitCounter::new(
        evidence_gates(capacity=4097),
        sections,
      ),
    )
  })
}

///|
test "disjoint evidence brackets preserve exact bounds and the actual original endpoint covariances" {
  let engine = evidence_counter()
  let first = @types.Covariance2::new(0.01, 0.0, 0.01)
  let second = @types.Covariance2::new(0.04, 0.0, 0.04)
  ignore(
    engine.update(frame(0L, [evidence_track(1, -1.0, 0L, covariance=first)])),
  )
  let entered = engine.update(
    frame(100L, [evidence_track(1, 1.0, 100L, covariance=second)]),
  )
  assert_eq(entered.pending_count, 1)
  let pending = engine.checkpoint().pending[0]
  assert_eq(pending.from_covariance.yy, 0.01)
  assert_eq(pending.to_covariance.yy, 0.04)
  let result = engine.update(frame(200L, [evidence_track(1, 3.0, 200L)]))
  assert_eq(result.passages.length(), 1)
  assert_eq(result.passages[0].elapsed_lower_us, 0L)
  assert_eq(result.passages[0].elapsed_upper_us, 200L)
  assert_eq(result.passages[0].estimated_elapsed_us, 100.0)
  assert_eq(result.pending_count, 0)
}

///|
test "same-frame evidence crossings order only by an identical chord rather than gate configuration" {
  for reverse in [false, true] {
    let engine = evidence_counter(reverse~)
    ignore(engine.update(frame(0L, [evidence_track(1, -1.0, 0L)])))
    let result = engine.update(frame(100L, [evidence_track(1, 3.0, 100L)]))
    assert_eq(result.counting.counting.crossings.length(), 2)
    assert_eq(result.passages.length(), 1)
    assert_eq(result.passages[0].estimated_elapsed_us, 50.0)
    assert_eq(result.passages[0].elapsed_lower_us, 0L)
    assert_eq(result.passages[0].elapsed_upper_us, 100L)
  }
}

///|
test "different normal confirmations can create ambiguous different chords in the same frame" {
  let engine = corner()
  ignore(engine.update(frame(0L, [evidence_track(1, -2.0, 0L, x=-2.0)])))
  let unconfirmed = engine.update(
    frame(100L, [evidence_track(1, -0.1, 100L, x=-1.0)]),
  )
  assert_eq(unconfirmed.counting.evidence[0].side, 0)
  let result = engine.update(frame(200L, [evidence_track(1, 2.0, 200L, x=2.0)]))
  assert_eq(result.counting.counting.crossings[0].from_timestamp_us, 0L)
  assert_eq(result.counting.counting.crossings[1].from_timestamp_us, 100L)
  assert_eq(result.passages.length(), 0)
  assert_eq(result.cancellations[0].reason, @transit.AmbiguousOrder)
  assert_eq(result.pending_count, 0)
}

///|
test "a later exit confirmation cannot resolve overlapping different-chord time brackets" {
  let engine = corner()
  ignore(engine.update(frame(0L, [evidence_track(1, -2.0, 0L, x=-2.0)])))
  assert_eq(
    engine.update(frame(100L, [evidence_track(1, 2.0, 100L, x=-0.1)])).pending_count,
    1,
  )
  let result = engine.update(frame(200L, [evidence_track(1, 3.0, 200L, x=2.0)]))
  assert_eq(result.passages.length(), 0)
  assert_eq(result.cancellations[0].reason, @transit.AmbiguousOrder)
  assert_eq(result.pending_count, 0)
}

///|
test "unconfirmed accepted sides retain pending entries without refreshing their confirmation TTL" {
  let engine = evidence_pending_counter(ttl=300L)
  ignore(engine.update(frame(200L, [evidence_track(1, 0.1, 200L)])))
  let kept = engine.update(frame(399L, [evidence_track(1, 0.1, 399L)]))
  assert_eq(kept.pending_count, 1)
  assert_eq(engine.checkpoint().pending[0].entry.to_timestamp_us, 100L)
  ignore(@transit.EvidenceTransitCounter::from_checkpoint(engine.checkpoint()))
  let expired = engine.update(frame(400L, [evidence_track(1, 0.1, 400L)]))
  assert_eq(expired.cancellations[0].reason, @transit.Expired)
  assert_eq(expired.pending_count, 0)
}

///|
test "continuity cancellation takes priority over simultaneous entry expiry" {
  let engine = evidence_pending_counter(ttl=300L)
  let result = engine.update(frame(400L, []))
  assert_eq(result.cancellations[0].reason, @transit.Discontinuity)
  assert_eq(result.pending_count, 0)
}

///|
test "missing rejected quality skipped changed segment and exact gate gaps cancel evidence pending state" {
  for mode in 0..<5 {
    let engine = evidence_counter(gap=500L, limit=Some(0.5))
    ignore(engine.update(frame(0L, [evidence_track(1, -1.0, 0L)])))
    ignore(engine.update(frame(100L, [evidence_track(1, 1.0, 100L)])))
    let (time, tracks) = match mode {
      0 => (200L, [])
      1 =>
        (
          200L,
          [evidence_track(1, 1.0, 200L, status=@motion.RejectedInnovation)],
        )
      2 => (200L, [evidence_track(1, 1.0, 200L, deviation=Some(0.6))])
      3 => (200L, [evidence_track(1, 1.0, 200L, segment="2")])
      _ => (600L, [evidence_track(1, 1.0, 600L)])
    }
    let result = engine.update(frame(time, tracks))
    assert_eq(result.pending_count, 0)
    assert_eq(result.cancellations[0].reason, @transit.Discontinuity)
  }
}

///|
test "opposite configured direction at either boundary cancels a pending evidence transit" {
  let first = evidence_pending_counter()
  assert_eq(
    first.update(frame(200L, [evidence_track(1, -1.0, 200L)])).cancellations[0].reason,
    @transit.Reversed,
  )
  let second = @transit.EvidenceTransitCounter::new(evidence_gates(), [
    @transit.Section::new(
      "aisle",
      "entry",
      @events.NegativeToPositive,
      "exit",
      @events.PositiveToNegative,
    ),
  ])
  ignore(second.update(frame(0L, [evidence_track(1, -1.0, 0L)])))
  ignore(second.update(frame(100L, [evidence_track(1, 1.0, 100L)])))
  assert_eq(
    second.update(frame(200L, [evidence_track(1, 3.0, 200L)])).cancellations[0].reason,
    @transit.Reversed,
  )
}

///|
test "a finite-gate reentry replaces the old proof before a same-frame ordered exit" {
  let engine = evidence_pending_counter()
  ignore(engine.update(frame(200L, [evidence_track(1, 1.0, 200L, x=20.0)])))
  ignore(engine.update(frame(300L, [evidence_track(1, -1.0, 300L, x=20.0)])))
  ignore(engine.update(frame(400L, [evidence_track(1, -1.0, 400L)])))
  let result = engine.update(frame(500L, [evidence_track(1, 3.0, 500L)]))
  assert_eq(result.cancellations[0].reason, @transit.Reentered)
  assert_eq(result.cancellations[0].entry.to_timestamp_us, 100L)
  assert_eq(result.passages[0].entry.from_timestamp_us, 400L)
  assert_eq(result.pending_count, 0)
}

///|
test "evidence transit time differences retain exact Int64 maximum clocks" {
  let engine = evidence_counter()
  let end = 9223372036854775807L
  ignore(
    engine.update(frame(end - 300L, [evidence_track(1, -1.0, end - 300L)])),
  )
  ignore(engine.update(frame(end - 200L, [evidence_track(1, 1.0, end - 200L)])))
  let result = engine.update(
    frame(end - 100L, [evidence_track(1, 3.0, end - 100L)]),
  )
  assert_eq(result.passages[0].entry.from_timestamp_us, end - 300L)
  assert_eq(result.passages[0].estimated_elapsed_us, 100.0)
  assert_eq(result.passages[0].elapsed_upper_us, 200L)
  ignore(@transit.EvidenceTransitCounter::from_checkpoint(engine.checkpoint()))
}

///|
test "numeric failures roll back existing pending entries evidence anchors and staged crossings" {
  let engine = evidence_pending_counter()
  let before = @debug.to_string(engine.checkpoint())
  let unsupported = @types.Covariance2::new(1.0, -0.9999999999999999, 1.0)
  invalid(() => {
    ignore(
      engine.update(
        frame(200L, [
          evidence_track(1, 3.0, 200L),
          evidence_track(2, -1.0, 200L, segment="2", covariance=unsupported),
        ]),
      ),
    )
  })
  assert_eq(@debug.to_string(engine.checkpoint()), before)
  assert_eq(
    engine.update(frame(200L, [evidence_track(1, 3.0, 200L)])).passages.length(),
    1,
  )
}

///|
test "malformed covariance and frames fail before committing downstream time or pairing" {
  let engine = evidence_pending_counter(limit=Some(0.5))
  let before = @debug.to_string(engine.checkpoint())
  invalid(() => {
    ignore(
      engine.update(
        frame(200L, [
          evidence_track(1, 1.0, 200L, deviation=Some(0.6), covariance={
            xx: 1.0,
            xy: 2.0,
            yy: 1.0,
          }),
        ]),
      ),
    )
  })
  invalid(() => ignore(engine.update(frame(100L, []))))
  invalid(() => {
    ignore(
      engine.update(
        frame(200L, [evidence_track(1, 1.0, 200L), evidence_track(1, 1.0, 200L)]),
      ),
    )
  })
  assert_eq(@debug.to_string(engine.checkpoint()), before)
}

///|
test "exhausted gate totals preserve evidence transit pairing and allow same-time noncrossing retry" {
  let engine = evidence_pending_counter()
  let saved = engine.checkpoint()
  saved.counting.counts[1] = {
    ..saved.counting.counts[1],
    negative_to_positive: 9223372036854775807L,
  }
  let exhausted = @transit.EvidenceTransitCounter::from_checkpoint(saved)
  let before = @debug.to_string(exhausted.checkpoint())
  invalid(() => {
    ignore(exhausted.update(frame(200L, [evidence_track(1, 3.0, 200L)])))
  })
  assert_eq(@debug.to_string(exhausted.checkpoint()), before)
  assert_eq(
    exhausted.update(frame(200L, [evidence_track(1, 1.0, 200L)])).pending_count,
    1,
  )
}

///|
test "pending restoration rejects unsupported or unconfirmed endpoint covariances rather than fabricating proof" {
  let saved = evidence_pending_counter().checkpoint()
  let pending = saved.pending[0]
  for
    covariance in [
      @types.Covariance2::isotropic(10.0),
      @types.Covariance2::new(1.0, -0.9999999999999999, 1.0),
      { xx: 1.0, xy: 2.0, yy: 1.0, },
    ] {
    invalid(() => {
      ignore(
        @transit.EvidenceTransitCounter::from_checkpoint({
          ..saved,
          pending: [{ ..pending, from_covariance: covariance, }],
        }),
      )
    })
  }
  invalid(() => {
    ignore(
      @transit.EvidenceTransitCounter::from_checkpoint({
        ..saved,
        pending: [
          { ..pending, to_covariance: @types.Covariance2::isotropic(10.0), },
        ],
      }),
    )
  })
}

///|
test "current and still-retained confirmation anchors bind the original pending endpoint covariance" {
  let engine = evidence_pending_counter()
  for advance in [false, true] {
    if advance {
      ignore(engine.update(frame(200L, [evidence_track(1, 0.1, 200L)])))
    }
    let saved = engine.checkpoint()
    let pending = saved.pending[0]
    let different = @types.Covariance2::isotropic(0.2)
    invalid(() => {
      ignore(
        @transit.EvidenceTransitCounter::from_checkpoint({
          ..saved,
          pending: [{ ..pending, to_covariance: different, }],
        }),
      )
    })
    let track = saved.counting.tracks[0]
    let anchor = track.anchors[0].unwrap()
    for bad_anchor in [None, Some({ ..anchor, timestamp_us: 0L, })] {
      let counting = {
        ..saved.counting,
        tracks: [{ ..track, anchors: [bad_anchor, track.anchors[1]], }],
      }
      ignore(@events.EvidenceGateCounter::from_checkpoint(counting))
      invalid(() => {
        ignore(
          @transit.EvidenceTransitCounter::from_checkpoint({
            ..saved,
            counting,
          }),
        )
      })
    }
    let changed = {
      ..saved.counting,
      tracks: [
        {
          ..track,
          anchors: [
            Some({ ..anchor, point_m: { x: 6.0, y: 1.0, }, }),
            track.anchors[1],
          ],
        },
      ],
    }
    ignore(@events.EvidenceGateCounter::from_checkpoint(changed))
    invalid(() => {
      ignore(
        @transit.EvidenceTransitCounter::from_checkpoint({
          ..saved,
          counting: changed,
        }),
      )
    })
  }
  let later = evidence_pending_counter()
  ignore(
    later.update(
      frame(200L, [
        evidence_track(
          1,
          1.0,
          200L,
          covariance=@types.Covariance2::isotropic(0.3),
        ),
      ]),
    ),
  )
  assert_eq(later.checkpoint().pending[0].to_covariance.yy, 0.1 * 0.1)
  ignore(@transit.EvidenceTransitCounter::from_checkpoint(later.checkpoint()))
  let expired_anchor = evidence_counter(gap=300L, ttl=1000L)
  ignore(expired_anchor.update(frame(0L, [evidence_track(1, -1.0, 0L)])))
  ignore(expired_anchor.update(frame(100L, [evidence_track(1, 1.0, 100L)])))
  for time in [200L, 300L, 400L] {
    ignore(expired_anchor.update(frame(time, [evidence_track(1, 0.1, time)])))
  }
  assert_true(expired_anchor.checkpoint().counting.tracks[0].anchors[0] is None)
  assert_eq(expired_anchor.checkpoint().pending.length(), 1)
  ignore(
    @transit.EvidenceTransitCounter::from_checkpoint(
      expired_anchor.checkpoint(),
    ),
  )
}

///|
test "evidence checkpoint rejects wrong configuration geometry capacity totals age and current segment" {
  let saved = evidence_pending_counter(ttl=300L).checkpoint()
  let pending = saved.pending[0]
  for
    bad in [
      { ..saved, version: 2, },
      { ..saved, pending: Array::make(11, pending), },
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
        counting: { ..saved.counting, last_timestamp_us: Some(400L), },
      },
      { ..saved, counts: [{ ..saved.counts[0], completed: 1L, }], },
      {
        ..saved,
        counting: {
          ..saved.counting,
          counts: [
            { ..saved.counting.counts[0], negative_to_positive: 0L, },
            saved.counting.counts[1],
          ],
        },
      },
    ] {
    invalid(() => ignore(@transit.EvidenceTransitCounter::from_checkpoint(bad)))
  }
}

///|
test "every evidence transit cut preserves original proofs completions and all cancellation state" {
  let frames = [
    frame(0L, [evidence_track(1, -1.0, 0L)]),
    frame(100L, [evidence_track(1, 1.0, 100L)]),
    frame(200L, [evidence_track(1, 3.0, 200L)]),
    frame(300L, []),
    frame(400L, [evidence_track(1, -1.0, 400L, segment="2")]),
    frame(500L, [evidence_track(1, 1.0, 500L, segment="2")]),
    frame(600L, [evidence_track(1, 0.1, 600L, segment="2")]),
    frame(700L, []),
  ]
  let engine = evidence_counter()
  let expected : Array[String] = []
  for frame in frames {
    expected.push(@debug.to_string(engine.update(frame)))
  }
  for cut in 0..<=frames.length() {
    let prefix = evidence_counter()
    for index in 0..<cut {
      ignore(prefix.update(frames[index]))
    }
    let resumed = @transit.EvidenceTransitCounter::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<frames.length() {
      assert_eq(
        @debug.to_string(resumed.update(frames[index])),
        expected[index],
      )
    }
    assert_eq(
      @debug.to_string(resumed.checkpoint()),
      @debug.to_string(engine.checkpoint()),
    )
  }
}

///|
test "evidence transit constructors checkpoints forks and result arrays remain detached" {
  let source = evidence_gates()
  let engine = @transit.EvidenceTransitCounter::new(source, [section()])
  ignore(engine.update(frame(0L, [evidence_track(1, -1.0, 0L)])))
  ignore(engine.update(frame(100L, [evidence_track(1, 1.0, 100L)])))
  let branch = engine.fork()
  let saved = engine.checkpoint()
  let resumed = @transit.EvidenceTransitCounter::from_checkpoint(saved)
  let before = @debug.to_string(engine.checkpoint())
  saved.pending.clear()
  saved.counting.tracks[0].anchors.clear()
  saved.sections.clear()
  saved.counts.clear()
  ignore(source.update(frame(0L, [evidence_track(2, 0.0, 0L, segment="2")])))
  let result = branch.update(frame(200L, [evidence_track(1, 3.0, 200L)]))
  assert_eq(@debug.to_string(engine.checkpoint()), before)
  assert_eq(@debug.to_string(resumed.checkpoint()), before)
  assert_eq(
    @debug.to_string(result),
    @debug.to_string(
      resumed.update(frame(200L, [evidence_track(1, 3.0, 200L)])),
    ),
  )
  result.counts.clear()
  result.counting.counting.counts.clear()
  result.counting.evidence.clear()
  assert_eq(
    @debug.to_string(branch.checkpoint()),
    @debug.to_string(resumed.checkpoint()),
  )
}

///|
test "zero multiplier evidence transit preserves every legacy pairing result on supported covariance" {
  let legacy = counter()
  let evidence = evidence_counter(multiplier=0.0)
  for index, y in [-1.0, 1.0, 3.0, -1.0, 1.0] {
    let time = index.to_int64() * 100L
    let input = frame(time, [evidence_track(1, y, time)])
    let expected = legacy.update(input)
    let actual = evidence.update(input)
    assert_eq(
      @debug.to_string(actual.counting.counting),
      @debug.to_string(expected.counting),
    )
    assert_eq(
      @debug.to_string(actual.passages),
      @debug.to_string(expected.passages),
    )
    assert_eq(
      @debug.to_string(actual.cancellations),
      @debug.to_string(expected.cancellations),
    )
    assert_eq(
      @debug.to_string(actual.counts),
      @debug.to_string(expected.counts),
    )
  }
}
