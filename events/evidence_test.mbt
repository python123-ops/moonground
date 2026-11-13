///|
fn evidence_counter(
  multiplier~ : Double = 2.0,
  config~ : @events.GateConfig = @events.GateConfig::new(),
  gates~ : Array[@events.LineGate] = [line()],
) -> @events.EvidenceGateCounter raise @types.GroundError {
  @events.EvidenceGateCounter::new(
    "gate",
    gates,
    config,
    sigma_multiplier=multiplier,
  )
}

///|
fn evidence_track(
  id : Int32,
  segment : String,
  x : Double,
  y : Double,
  time : Int64,
  covariance~ : @types.Covariance2 = @types.Covariance2::isotropic(0.1),
  deviation~ : Double? = Some(0.1),
  status~ : @motion.MotionStatus = @motion.Ready,
) -> @motion.TrackEstimate raise @types.GroundError {
  {
    ..estimate(id, segment, x, y, time, deviation~, status~),
    position_covariance: Some(covariance),
  }
}

///|
fn assert_relative(actual : Double, expected : Double) -> Unit raise {
  assert_true((actual / expected - 1.0).abs() < 1.0e-7)
}

///|
test "evidence policy validates finite nonnegative multipliers and old bounded gate budgets" {
  for multiplier in [-1.0, 1.0 / 0.0, 0.0 / 0.0] {
    invalid(() => ignore(evidence_counter(multiplier~)))
  }
  ignore(evidence_counter(multiplier=0.0))
  let gates = Array::makei(16, index => line(id=index.to_string()))
  ignore(
    evidence_counter(gates~, config=@events.GateConfig::new(max_tracks=4096)),
  )
  invalid(() => {
    ignore(
      evidence_counter(gates~, config=@events.GateConfig::new(max_tracks=4097)),
    )
  })
}

///|
test "normal intervals establish sides while crossings retain finite mean-chord fields" {
  let engine = evidence_counter()
  let initial = engine.update(
    frame(0L, [evidence_track(1, "1", 5.0, -1.0, 0L)]),
  )
  assert_eq(initial.evidence[0].side, -1)
  assert_relative(initial.evidence[0].normal_std_m, 0.1)
  assert_eq(initial.evidence[0].distance_m, -1.0)
  assert_eq(initial.evidence[0].lower_m, -1.2)
  assert_eq(initial.evidence[0].upper_m, -0.8)
  let result = engine.update(
    frame(100L, [evidence_track(1, "1", 5.0, 1.0, 100L)]),
  )
  assert_eq(result.evidence[0].side, 1)
  assert_eq(result.counting.counts[0].negative_to_positive, 1L)
  assert_eq(result.counting.crossings[0].from_timestamp_us, 0L)
  assert_eq(result.counting.crossings[0].to_timestamp_us, 100L)
  assert_eq(result.counting.crossings[0].crossing_fraction, 0.5)
}

///|
test "zero multiplier retains covariance diagnostics and exactly matches legacy valid-covariance streams" {
  let config = @events.GateConfig::new(max_position_std_m=0.5)
  let old = counter(config~)
  let evidence = evidence_counter(multiplier=0.0, config~)
  let frames = [
    frame(0L, [
      evidence_track(1, "1", 5.0, -1.0, 0L, status=@motion.Initializing),
    ]),
    frame(100L, [evidence_track(1, "1", 5.0, 0.0, 100L)]),
    frame(200L, [
      evidence_track(1, "1", 5.0, 1.0, 200L, status=@motion.Uncertain),
    ]),
    frame(300L, [evidence_track(1, "1", 5.0, -1.0, 300L, deviation=Some(0.6))]),
    frame(400L, []),
    frame(500L, [evidence_track(1, "2", 5.0, -1.0, 500L)]),
    frame(600L, [evidence_track(1, "2", 5.0, 1.0, 600L)]),
  ]
  for input in frames {
    let current = evidence.update(input)
    assert_eq(
      @debug.to_string(current.counting),
      @debug.to_string(old.update(input)),
    )
    for row in current.evidence {
      assert_eq(row.lower_m, row.distance_m)
      assert_eq(row.upper_m, row.distance_m)
      assert_true(row.normal_std_m > 0.0)
    }
  }
  let snapshot = evidence.checkpoint()
  assert_eq(snapshot.sigma_multiplier, 0.0)
  assert_true(snapshot.tracks[0].anchors[0].unwrap().covariance.xx > 0.0)
  ignore(@events.EvidenceGateCounter::from_checkpoint(snapshot))
}

///|
test "touching either closed band boundary remains unconfirmed" {
  let engine = evidence_counter(gates=[line(deadband=0.25)])
  let covariance = @types.Covariance2::isotropic(0.125)
  for
    (time, y, expected) in [
      (0L, 0.5, 0),
      (1L, -0.5, 0),
      (2L, 0.5001, 1),
      (3L, -0.5001, -1),
    ] {
    assert_eq(
      engine.update(
        frame(time, [evidence_track(1, "1", 5.0, y, time, covariance~)]),
      ).evidence[0].side,
      expected,
    )
  }
}

///|
test "independent extreme tangent variance does not obscure a well-resolved normal" {
  let covariance = @types.Covariance2::new(1.0e200, 0.0, 1.0e-100)
  let horizontal = line(deadband=0.0)
  let vertical = @events.LineGate::new("vertical", { x: 0.0, y: 0.0, }, {
    x: 0.0,
    y: 10.0,
  })
  let engine = evidence_counter(gates=[horizontal, vertical])
  let result = engine.update(
    frame(0L, [evidence_track(1, "1", 1.0, 1.0e-40, 0L, covariance~)]),
  )
  assert_relative(result.evidence[0].normal_std_m, 1.0e-50)
  assert_eq(result.evidence[0].side, 1)
  assert_relative(result.evidence[1].normal_std_m, 1.0e100)
  assert_eq(result.evidence[1].side, 0)
}

///|
test "correlated rotated covariance keeps the correct normal variance at extreme scales" {
  let diagonal = @events.LineGate::new("diagonal", { x: 0.0, y: 0.0, }, {
    x: 1.0,
    y: 1.0,
  })
  for scale in [1.0e-300, 1.0, 1.0e300] {
    for correlation in [-0.9, 0.9] {
      let covariance = @types.Covariance2::new(
        scale,
        correlation * scale,
        scale,
      )
      let engine = evidence_counter(gates=[diagonal])
      let result = engine.update(
        frame(0L, [evidence_track(1, "1", 0.0, 0.0, 0L, covariance~)]),
      )
      assert_relative(
        result.evidence[0].normal_std_m,
        scale.sqrt() * (1.0 - correlation).sqrt(),
      )
      assert_eq(result.evidence[0].side, 0)
    }
  }
}

///|
test "compensated determinant supports strong correlation before its explicit cancellation boundary" {
  let diagonal = @events.LineGate::new("diagonal", { x: 0.0, y: 0.0, }, {
    x: 1.0,
    y: -1.0,
  })
  for scale in [1.0e-300, 1.0e300] {
    let cross = -(1.0 - 1.0e-10) * scale
    let covariance = @types.Covariance2::new(scale, cross, scale)
    let engine = evidence_counter(gates=[diagonal])
    let result = engine.update(
      frame(0L, [evidence_track(1, "1", 0.0, 0.0, 0L, covariance~)]),
    )
    assert_relative(result.evidence[0].normal_std_m, (scale + cross).sqrt())
  }
}

///|
test "near-perfect correlation is rejected atomically rather than reporting a low deviation" {
  for
    covariance in [
      @types.Covariance2::new(1.0e300, -9.999999999999999e299, 1.0e300),
      @types.Covariance2::new(1.0e-300, -9.999999999999999e-301, 1.0e-300),
    ] {
    for multiplier in [0.0, 2.0] {
      let engine = evidence_counter(multiplier~)
      let before = @debug.to_string(engine.checkpoint())
      invalid(() => {
        ignore(
          engine.update(
            frame(0L, [evidence_track(1, "1", 5.0, 0.0, 0L, covariance~)]),
          ),
        )
      })
      assert_eq(@debug.to_string(engine.checkpoint()), before)
    }
  }
}

///|
test "correlated LDL underflow is rejected while the corresponding independent covariance remains supported" {
  let covariance = @types.Covariance2::new(1.0e200, 5.0e44, 1.0e-110)
  let engine = evidence_counter()
  invalid(() => {
    ignore(
      engine.update(
        frame(0L, [evidence_track(1, "1", 5.0, 0.0, 0L, covariance~)]),
      ),
    )
  })
  let independent = @types.Covariance2::new(1.0e200, 0.0, 1.0e-110)
  assert_relative(
    engine.update(
      frame(0L, [evidence_track(1, "1", 5.0, 0.0, 0L, covariance=independent)]),
    ).evidence[0].normal_std_m,
    1.0e-55,
  )
}

///|
test "radius overflow underflow and intervals which cannot expand all reject without committing" {
  let cases = [
    (1.0e308, @types.Covariance2::isotropic(10.0), 0.0),
    (1.0e-200, @types.Covariance2::isotropic(1.0e-150), 0.0),
    (1.0e154, @types.Covariance2::isotropic(1.0e154), 1.0e308),
    (2.0, @types.Covariance2::isotropic(0.1), 1.0e300),
  ]
  for (multiplier, covariance, y) in cases {
    let engine = evidence_counter(multiplier~)
    let before = @debug.to_string(engine.checkpoint())
    invalid(() => {
      ignore(
        engine.update(
          frame(0L, [evidence_track(1, "1", 5.0, y, 0L, covariance~)]),
        ),
      )
    })
    assert_eq(@debug.to_string(engine.checkpoint()), before)
  }
}

///|
test "accepted covariance is required and invalid typed covariance cannot hide behind quality skips" {
  for multiplier in [0.0, 2.0] {
    let engine = evidence_counter(
      multiplier~,
      config=@events.GateConfig::new(max_position_std_m=0.5),
    )
    for
      input in [
        estimate(1, "1", 5.0, -1.0, 0L),
        evidence_track(
          1,
          "1",
          5.0,
          -1.0,
          0L,
          covariance={ xx: 1.0, xy: 2.0, yy: 1.0, },
          deviation=Some(0.6),
        ),
        evidence_track(1, "1", 5.0, -1.0, 0L, covariance={
          xx: 1.0,
          xy: 0.0,
          yy: 0.0 / 0.0,
        }),
      ] {
      invalid(() => ignore(engine.update(frame(0L, [input]))))
      assert_eq(engine.checkpoint().last_timestamp_us, None)
    }
  }
}

///|
test "unconfirmed observations retain the original anchor only until its exact age limit" {
  for final_time in [299L, 300L] {
    let engine = evidence_counter(
      config=@events.GateConfig::new(max_gap_us=300L),
    )
    ignore(engine.update(frame(0L, [evidence_track(1, "1", 5.0, -1.0, 0L)])))
    for (time, y) in [(100L, -0.1), (200L, 0.1)] {
      assert_eq(
        engine.update(frame(time, [evidence_track(1, "1", 5.0, y, time)])).evidence[0].side,
        0,
      )
      assert_eq(
        engine.checkpoint().tracks[0].anchors[0].unwrap().timestamp_us,
        0L,
      )
    }
    let result = engine.update(
      frame(final_time, [evidence_track(1, "1", 5.0, 1.0, final_time)]),
    )
    assert_eq(
      result.counting.crossings.length(),
      if final_time == 299L {
        1
      } else {
        0
      },
    )
  }
}

///|
test "confirmed same-side points refresh the saved covariance while uncertainty does not" {
  let engine = evidence_counter()
  ignore(engine.update(frame(0L, [evidence_track(1, "1", 5.0, -2.0, 0L)])))
  let covariance = @types.Covariance2::isotropic(0.2)
  ignore(
    engine.update(
      frame(100L, [evidence_track(1, "1", 5.0, -1.0, 100L, covariance~)]),
    ),
  )
  ignore(engine.update(frame(200L, [evidence_track(1, "1", 5.0, -0.1, 200L)])))
  let anchor = engine.checkpoint().tracks[0].anchors[0].unwrap()
  assert_eq(anchor.timestamp_us, 100L)
  assert_eq(anchor.covariance.xx, covariance.xx)
  let result = engine.update(
    frame(300L, [evidence_track(1, "1", 5.0, 1.0, 300L)]),
  )
  assert_eq(result.counting.crossings[0].from_timestamp_us, 100L)
}

///|
test "missing rejected quality-skipped and changed segments never retain stale side evidence" {
  for kind in 0..<4 {
    let engine = evidence_counter(
      config=@events.GateConfig::new(max_position_std_m=0.5),
    )
    ignore(engine.update(frame(0L, [evidence_track(1, "1", 5.0, -1.0, 0L)])))
    let tracks = match kind {
      0 => []
      1 =>
        [
          {
            ..estimate(1, "1", 5.0, -1.0, 0L),
            status: @motion.RejectedInnovation,
            position: None,
          },
        ]
      2 => [evidence_track(1, "1", 5.0, 1.0, 100L, deviation=Some(0.6))]
      _ => [evidence_track(1, "2", 5.0, 1.0, 100L)]
    }
    let skipped = engine.update(frame(100L, tracks))
    assert_eq(skipped.counting.crossings.length(), 0)
    assert_eq(skipped.evidence.length(), if kind == 3 { 1 } else { 0 })
    let segment = if kind == 3 { "2" } else { "1" }
    assert_eq(
      engine.update(frame(200L, [evidence_track(1, segment, 5.0, 1.0, 200L)])).counting.crossings.length(),
      0,
    )
  }
}

///|
test "normal evidence does not turn finite endpoint or extension checks into confidence claims" {
  let covariance = @types.Covariance2::new(1.0e12, 0.0, 0.01)
  let engine = evidence_counter()
  let xs = [-1.0, 0.0, 10.0, 11.0]
  ignore(
    engine.update(
      frame(
        0L,
        Array::makei(4, index => {
          evidence_track(
            index + 1,
            (index + 1).to_string(),
            xs[index],
            -1.0,
            0L,
            covariance~,
          )
        }),
      ),
    ),
  )
  let result = engine.update(
    frame(
      100L,
      Array::makei(4, index => {
        evidence_track(
          index + 1,
          (index + 1).to_string(),
          xs[index],
          1.0,
          100L,
          covariance~,
        )
      }),
    ),
  )
  assert_eq(result.evidence.length(), 4)
  assert_true(result.evidence.all(row => row.side == 1))
  assert_eq(result.counting.crossings.length(), 2)
  assert_eq(result.counting.crossings[0].position_m.x, 0.0)
  assert_eq(result.counting.crossings[1].position_m.x, 10.0)
}

///|
test "every evidence checkpoint cut preserves policy covariance anchors and subsequent frames" {
  let inputs = [
    frame(0L, [evidence_track(1, "1", 5.0, -1.0, 0L)]),
    frame(100L, [evidence_track(1, "1", 5.0, -0.1, 100L)]),
    frame(200L, [evidence_track(1, "1", 5.0, 0.1, 200L)]),
    frame(300L, [evidence_track(1, "1", 5.0, 1.0, 300L)]),
    frame(400L, []),
    frame(500L, [evidence_track(1, "2", 5.0, -1.0, 500L)]),
    frame(600L, [evidence_track(1, "2", 5.0, 1.0, 600L)]),
  ]
  let complete = evidence_counter()
  let expected = inputs.map(input => @debug.to_string(complete.update(input)))
  let state = @debug.to_string(complete.checkpoint())
  for cut in 0..<=inputs.length() {
    let prefix = evidence_counter()
    for index in 0..<cut {
      ignore(prefix.update(inputs[index]))
    }
    let restored = @events.EvidenceGateCounter::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<inputs.length() {
      assert_eq(
        @debug.to_string(restored.update(inputs[index])),
        expected[index],
      )
    }
    assert_eq(@debug.to_string(restored.checkpoint()), state)
  }
}

///|
test "restoration rechecks covariance proof age shapes identities and exact count constraints" {
  let engine = evidence_counter()
  ignore(engine.update(frame(0L, [evidence_track(1, "1", 5.0, -1.0, 0L)])))
  let snapshot = engine.checkpoint()
  let saved = snapshot.tracks[0]
  let anchor = saved.anchors[0].unwrap()
  for
    bad in [
      { ..snapshot, version: 2, },
      { ..snapshot, sigma_multiplier: -1.0, },
      { ..snapshot, counts: [], },
      {
        ..snapshot,
        counts: [{ ..snapshot.counts[0], negative_to_positive: -1L, }],
      },
      { ..snapshot, tracks: [saved, saved], },
      { ..snapshot, tracks: Array::make(1001, saved), },
      { ..snapshot, tracks: [{ ..saved, anchors: Array::make(65537, None), }], },
      { ..snapshot, tracks: [{ ..saved, segment_id: "01", }], },
      { ..snapshot, tracks: [{ ..saved, anchors: [], }], },
      {
        ..snapshot,
        tracks: [{ ..saved, anchors: [Some({ ..anchor, timestamp_us: 1L, })], }],
      },
      {
        ..snapshot,
        tracks: [
          {
            ..saved,
            anchors: [
              Some({ ..anchor, covariance: { xx: 1.0, xy: 2.0, yy: 1.0, }, }),
            ],
          },
        ],
      },
      {
        ..snapshot,
        tracks: [
          {
            ..saved,
            anchors: [
              Some({
                ..anchor,
                covariance: @types.Covariance2::isotropic(10.0),
              }),
            ],
          },
        ],
      },
      { ..snapshot, last_timestamp_us: Some(500000L), },
      { ..snapshot, last_timestamp_us: None, },
    ] {
    invalid(() => ignore(@events.EvidenceGateCounter::from_checkpoint(bad)))
  }
  assert_eq(
    @debug.to_string(
      @events.EvidenceGateCounter::from_checkpoint(snapshot).checkpoint(),
    ),
    @debug.to_string(snapshot),
  )
}

///|
test "evidence checkpoints forks and result arrays have no mutable aliases" {
  let engine = evidence_counter()
  ignore(engine.update(frame(0L, [evidence_track(1, "1", 5.0, -1.0, 0L)])))
  let snapshot = engine.checkpoint()
  let restored = @events.EvidenceGateCounter::from_checkpoint(snapshot)
  let branch = engine.fork()
  snapshot.tracks[0].anchors[0] = None
  snapshot.gates.clear()
  snapshot.counts.clear()
  assert_true(engine.checkpoint().tracks[0].anchors[0] is Some(_))
  let result = branch.update(
    frame(100L, [evidence_track(1, "1", 5.0, 1.0, 100L)]),
  )
  result.evidence.clear()
  result.counting.counts.clear()
  assert_eq(branch.checkpoint().counts[0].negative_to_positive, 1L)
  assert_eq(engine.checkpoint().counts[0].negative_to_positive, 0L)
  assert_eq(
    restored.update(frame(100L, [evidence_track(1, "1", 5.0, 1.0, 100L)])).counting.counts[0].negative_to_positive,
    1L,
  )
}

///|
test "a late interval failure rolls back earlier staged crossings and supports same-time correction" {
  let engine = evidence_counter()
  ignore(
    engine.update(
      frame(0L, [
        evidence_track(1, "1", 5.0, -1.0, 0L),
        evidence_track(2, "2", 5.0, -1.0, 0L),
      ]),
    ),
  )
  let before = @debug.to_string(engine.checkpoint())
  invalid(() => {
    ignore(
      engine.update(
        frame(100L, [
          evidence_track(1, "1", 5.0, 1.0, 100L),
          evidence_track(2, "2", 5.0, 1.0e300, 100L),
        ]),
      ),
    )
  })
  assert_eq(@debug.to_string(engine.checkpoint()), before)
  assert_eq(
    engine.update(
      frame(100L, [
        evidence_track(1, "1", 5.0, 1.0, 100L),
        evidence_track(2, "2", 5.0, 1.0, 100L),
      ]),
    ).counting.counts[0].negative_to_positive,
    2L,
  )
}

///|
test "counter overflow preserves evidence anchors and exact Int64 timestamp watermarks" {
  let engine = evidence_counter()
  let start = 9223372036854775707L
  let end = 9223372036854775807L
  ignore(
    engine.update(frame(start, [evidence_track(1, "1", 5.0, -1.0, start)])),
  )
  let snapshot = engine.checkpoint()
  snapshot.counts[0] = {
    ..snapshot.counts[0],
    negative_to_positive: 9223372036854775807L,
  }
  let saturated = @events.EvidenceGateCounter::from_checkpoint(snapshot)
  let before = @debug.to_string(saturated.checkpoint())
  invalid(() => {
    ignore(
      saturated.update(frame(end, [evidence_track(1, "1", 5.0, 1.0, end)])),
    )
  })
  assert_eq(@debug.to_string(saturated.checkpoint()), before)
  let result = engine.update(
    frame(end, [evidence_track(1, "1", 5.0, 1.0, end)]),
  )
  assert_eq(result.counting.crossings[0].from_timestamp_us, start)
  assert_eq(result.counting.crossings[0].to_timestamp_us, end)
  assert_eq(
    saturated.update(frame(end, [evidence_track(1, "1", 5.0, -1.0, end)])).counting.counts[0].negative_to_positive,
    end,
  )
}

///|
test "evidence rows follow track identity then configured gate order without modifying legacy records" {
  let engine = evidence_counter(gates=[line(id="second"), line(id="first")])
  let result = engine.update(
    frame(0L, [
      evidence_track(2, "2", 5.0, 1.0, 0L),
      evidence_track(1, "1", 5.0, 1.0, 0L),
    ]),
  )
  assert_eq(result.evidence.map(row => row.track_id), [1, 1, 2, 2])
  assert_eq(result.evidence.map(row => row.gate_id), [
    "second", "first", "second", "first",
  ])
  let old_anchor : @events.GateAnchor = {
    timestamp_us: 0L,
    point_m: { x: 5.0, y: 1.0, },
  }
  let old_track : @events.GateTrackCheckpoint = {
    track_id: 1,
    segment_id: "1",
    anchors: [Some(old_anchor)],
  }
  let legacy = counter().checkpoint()
  ignore(
    @events.GateCounter::from_checkpoint({
      ..legacy,
      last_timestamp_us: Some(0L),
      tracks: [old_track],
    }),
  )
}
