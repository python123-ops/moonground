///|
fn invalid(action : () -> Unit raise @types.GroundError) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid gate state was accepted")
  }
}

///|
fn line(
  id~ : String = "entry",
  deadband~ : Double = 0.05,
) -> @events.LineGate raise @types.GroundError {
  @events.LineGate::new(
    id,
    { x: 0.0, y: 0.0, },
    { x: 10.0, y: 0.0, },
    deadband_m=deadband,
  )
}

///|
fn counter(
  config~ : @events.GateConfig = @events.GateConfig::new(),
) -> @events.GateCounter raise @types.GroundError {
  @events.GateCounter::new("gate", [line()], config)
}

///|
fn estimate(
  id : Int32,
  segment : String,
  x : Double,
  y : Double,
  time : Int64,
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
    session_id: "gate",
    timestamp_us: time,
    tracks,
    closed_segment_ids: closed,
  }
}

///|
test "gate construction bounds coordinates identities deadband and anchor capacity" {
  let origin : @types.Point2 = { x: 0.0, y: 0.0, }
  let endpoint : @types.Point2 = { x: 1.0, y: 0.0, }
  for id in ["", String::make(129, 'g')] {
    invalid(() => ignore(@events.LineGate::new(id, origin, endpoint)))
  }
  invalid(() => ignore(@events.LineGate::new("same", origin, origin)))
  for bad in [-1.0, 1.0 / 0.0, 0.0 / 0.0] {
    invalid(() => {
      ignore(@events.LineGate::new("bad", origin, endpoint, deadband_m=bad))
    })
  }
  invalid(() => {
    ignore(
      @events.LineGate::new("overflow", { x: -1.0e308, y: 0.0, }, {
        x: 1.0e308,
        y: 0.0,
      }),
    )
  })
  invalid(() => {
    ignore(@events.LineGate::new("nan", { x: 0.0 / 0.0, y: 0.0, }, endpoint))
  })
  for gap in [0L, -1L] {
    invalid(() => ignore(@events.GateConfig::new(max_gap_us=gap)))
  }
  for capacity in [0, -1, 10001] {
    invalid(() => ignore(@events.GateConfig::new(max_tracks=capacity)))
  }
  for deviation in [0.0, -1.0, 1.0 / 0.0, 0.0 / 0.0] {
    invalid(() => ignore(@events.GateConfig::new(max_position_std_m=deviation)))
  }
  invalid(() => {
    ignore(@events.GateCounter::new("", [line()], @events.GateConfig::new()))
  })
  invalid(() => {
    ignore(@events.GateCounter::new("gate", [], @events.GateConfig::new()))
  })
  invalid(() => {
    ignore(
      @events.GateCounter::new(
        "gate",
        [line(), line()],
        @events.GateConfig::new(),
      ),
    )
  })
  let gates = Array::makei(16, index => line(id=index.to_string()))
  ignore(
    @events.GateCounter::new(
      "gate",
      gates,
      @events.GateConfig::new(max_tracks=4096),
    ),
  )
  invalid(() => {
    ignore(
      @events.GateCounter::new(
        "gate",
        gates,
        @events.GateConfig::new(max_tracks=4097),
      ),
    )
  })
  gates.push(line(id="seventeen"))
  invalid(() => {
    ignore(
      @events.GateCounter::new(
        "gate",
        gates,
        @events.GateConfig::new(max_tracks=1),
      ),
    )
  })
}

///|
test "directed crossings count accepted positions and sort tracks then configured gates" {
  let forward = line(id="left")
  let reverse = @events.LineGate::new("right", { x: 10.0, y: 0.0, }, {
    x: 0.0,
    y: 0.0,
  })
  let engine = @events.GateCounter::new(
    "gate",
    [forward, reverse],
    @events.GateConfig::new(),
  )
  ignore(
    engine.update(
      frame(0L, [
        estimate(9, "91", 8.0, -1.0, 0L, status=@motion.Initializing),
        estimate(2, "21", 2.0, -1.0, 0L, status=@motion.Uncertain),
      ]),
    ),
  )
  let result = engine.update(
    frame(100000L, [
      estimate(9, "91", 8.0, 1.0, 100000L, status=@motion.Uncertain),
      estimate(2, "21", 2.0, 1.0, 100000L, status=@motion.Initializing),
    ]),
  )
  assert_eq(result.crossings.map(event => event.track_id), [2, 2, 9, 9])
  assert_eq(result.crossings.map(event => event.gate_id), [
    "left", "right", "left", "right",
  ])
  assert_eq(result.crossings[0].direction, @events.NegativeToPositive)
  assert_eq(result.crossings[1].direction, @events.PositiveToNegative)
  assert_eq(result.crossings[0].position_m.x, 2.0)
  assert_eq(result.crossings[0].position_m.y, 0.0)
  assert_eq(result.crossings[0].crossing_fraction, 0.5)
  assert_eq(result.counts[0].negative_to_positive, 2L)
  assert_eq(result.counts[1].positive_to_negative, 2L)
  let back = engine.update(
    frame(200000L, [estimate(2, "21", 2.0, -1.0, 200000L)]),
  )
  assert_eq(back.counts[0].positive_to_negative, 1L)
  assert_eq(back.counts[1].negative_to_positive, 1L)
}

///|
test "closed deadband ignores jitter and brackets the latest same-side stable anchor" {
  let engine = counter()
  ignore(engine.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
  ignore(engine.update(frame(100L, [estimate(1, "1", 5.0, -0.5, 100L)])))
  for (time, y) in [(200L, -0.05), (300L, 0.05), (400L, -0.04), (500L, 0.0)] {
    assert_eq(
      engine.update(frame(time, [estimate(1, "1", 5.0, y, time)])).crossings.length(),
      0,
    )
  }
  let event = engine.update(frame(600L, [estimate(1, "1", 5.0, 1.0, 600L)])).crossings[0]
  assert_eq(event.from_timestamp_us, 100L)
  assert_eq(event.to_timestamp_us, 600L)
  assert_eq(event.from_position_m.y, -0.5)
  assert_true((event.crossing_fraction - 1.0 / 3.0).abs() < 1.0e-15)
  let initial_band = counter()
  ignore(initial_band.update(frame(0L, [estimate(1, "1", 5.0, 0.0, 0L)])))
  assert_eq(
    initial_band.update(frame(100L, [estimate(1, "1", 5.0, 1.0, 100L)])).crossings.length(),
    0,
  )
  let zero = @events.GateCounter::new(
    "gate",
    [line(deadband=0.0)],
    @events.GateConfig::new(),
  )
  ignore(zero.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
  ignore(zero.update(frame(100L, [estimate(1, "1", 5.0, 0.0, 100L)])))
  assert_eq(
    zero.update(frame(200L, [estimate(1, "1", 5.0, 1.0, 200L)])).crossings.length(),
    1,
  )
}

///|
test "finite endpoints are included and an extension crossing still switches stable side" {
  let engine = counter()
  let xs = [-1.0, 0.0, 10.0, 11.0]
  ignore(
    engine.update(
      frame(
        0L,
        Array::makei(4, index => {
          estimate(index + 1, (index + 1).to_string(), xs[index], -1.0, 0L)
        }),
      ),
    ),
  )
  let result = engine.update(
    frame(
      100L,
      Array::makei(4, index => {
        estimate(index + 1, (index + 1).to_string(), xs[index], 1.0, 100L)
      }),
    ),
  )
  assert_eq(result.crossings.map(event => event.track_id), [2, 3])
  assert_eq(result.counts[0].negative_to_positive, 2L)
  // Track 1 crossed the infinite extension. Moving along the positive side
  // into the finite gate must not turn that old crossing into a new event.
  assert_eq(
    engine.update(frame(200L, [estimate(1, "1", 5.0, 1.0, 200L)])).crossings.length(),
    0,
  )
  let back = engine.update(frame(300L, [estimate(1, "1", 5.0, -1.0, 300L)]))
  assert_eq(back.crossings.length(), 1)
  assert_eq(back.crossings[0].direction, @events.PositiveToNegative)
}

///|
test "missing rejected and numerical frames immediately break all event continuity" {
  for status in [@motion.RejectedInnovation, @motion.NumericalFailure] {
    let engine = counter()
    ignore(engine.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
    let rejected = {
      ..estimate(1, "1", 5.0, 1.0, 0L, status~),
      position: None,
    }
    assert_eq(engine.update(frame(100L, [rejected])).crossings.length(), 0)
    assert_eq(engine.checkpoint().tracks.length(), 0)
    assert_eq(
      engine.update(frame(200L, [estimate(1, "1", 5.0, 1.0, 200L)])).crossings.length(),
      0,
    )
    assert_eq(
      engine.update(frame(300L, [estimate(1, "1", 5.0, -1.0, 300L)])).crossings.length(),
      1,
    )
  }
  let missing = counter()
  ignore(missing.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
  ignore(missing.update(frame(100L, [])))
  assert_eq(missing.checkpoint().tracks.length(), 0)
  assert_eq(
    missing.update(frame(200L, [estimate(1, "1", 5.0, 1.0, 200L)])).crossings.length(),
    0,
  )
}

///|
test "optional position deviation skips unknown or excessive uncertainty and clears anchors" {
  for deviation in [None, Some(0.21)] {
    let engine = counter(config=@events.GateConfig::new(max_position_std_m=0.2))
    ignore(engine.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
    ignore(
      engine.update(frame(100L, [estimate(1, "1", 5.0, 1.0, 100L, deviation~)])),
    )
    assert_eq(engine.checkpoint().tracks.length(), 0)
    assert_eq(
      engine.update(
        frame(200L, [estimate(1, "1", 5.0, 1.0, 200L, deviation=Some(0.2))]),
      ).crossings.length(),
      0,
    )
    assert_eq(
      engine.update(
        frame(300L, [
          estimate(
            1,
            "1",
            5.0,
            -1.0,
            300L,
            status=@motion.Uncertain,
            deviation=Some(0.2),
          ),
        ]),
      ).crossings.length(),
      1,
    )
  }
  let unrestricted = counter()
  ignore(
    unrestricted.update(
      frame(0L, [estimate(1, "1", 5.0, -1.0, 0L, deviation=None)]),
    ),
  )
  assert_eq(
    unrestricted.update(
      frame(100L, [estimate(1, "1", 5.0, 1.0, 100L, deviation=None)]),
    ).crossings.length(),
    1,
  )
}

///|
test "gap boundary segment replacement and aging deadband anchors cannot bridge a crossing" {
  for interval in [249L, 250L] {
    let engine = counter(config=@events.GateConfig::new(max_gap_us=250L))
    ignore(engine.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
    let events = engine.update(
      frame(interval, [estimate(1, "1", 5.0, 1.0, interval)]),
    ).crossings.length()
    assert_eq(events, if interval < 250L { 1 } else { 0 })
  }
  let aging = counter(config=@events.GateConfig::new(max_gap_us=250L))
  ignore(aging.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
  ignore(aging.update(frame(100L, [estimate(1, "1", 5.0, 0.0, 100L)])))
  ignore(aging.update(frame(200L, [estimate(1, "1", 5.0, 0.0, 200L)])))
  assert_eq(
    aging.update(frame(250L, [estimate(1, "1", 5.0, 1.0, 250L)])).crossings.length(),
    0,
  )
  let replaced = counter()
  ignore(replaced.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
  let result = replaced.update(
    frame(100L, [estimate(1, "2", 5.0, 1.0, 100L)], closed=["1"]),
  )
  assert_eq(result.crossings.length(), 0)
  assert_eq(
    replaced.update(frame(200L, [estimate(1, "2", 5.0, -1.0, 200L)])).crossings.length(),
    1,
  )
}

///|
test "invalid identities timestamps accepted points and closed conflicts leave frame retryable" {
  let engine = counter()
  ignore(engine.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
  let before = @debug.to_string(engine.checkpoint())
  let good = estimate(1, "1", 5.0, 1.0, 100L)
  let bad_tracks = [
    { ..good, track_id: 0, },
    { ..good, segment_id: "0", },
    { ..good, segment_id: "01", },
    { ..good, segment_id: "+1", },
    { ..good, segment_id: "9223372036854775808", },
    { ..good, position: None, },
    { ..good, position: Some({ x: 0.0 / 0.0, y: 1.0, }), },
    { ..good, last_accepted_timestamp_us: 99L, },
    { ..good, position_std_m: Some(0.0), },
    { ..good, position_std_m: Some(1.0 / 0.0), },
  ]
  for bad in bad_tracks {
    invalid(() => ignore(engine.update(frame(100L, [bad]))))
    assert_eq(@debug.to_string(engine.checkpoint()), before)
  }
  for
    bad in [
      { ..frame(100L, [good]), session_id: "different", },
      frame(0L, []),
      frame(-1L, []),
      frame(100L, [good, good]),
      frame(100L, [good, { ..good, track_id: 2, }]),
      frame(100L, [good], closed=["1"]),
      frame(100L, [good], closed=["2", "2"]),
      frame(100L, [good], closed=["00"]),
    ] {
    invalid(() => ignore(engine.update(bad)))
    assert_eq(@debug.to_string(engine.checkpoint()), before)
  }
  assert_eq(engine.update(frame(100L, [good])).crossings.length(), 1)
}

///|
test "crossing fraction avoids distance overflow and retains exact near-maximum Int64 brackets" {
  let engine = counter()
  let from = 9223372036854575807L
  let to = 9223372036854675807L
  ignore(
    engine.update(
      frame(from, [estimate(1, "9223372036854775807", 5.0, -1.0e308, from)]),
    ),
  )
  let event = engine.update(
      frame(to, [estimate(1, "9223372036854775807", 5.0, 1.0e308, to)]),
    ).crossings[0]
  assert_eq(event.from_timestamp_us, from)
  assert_eq(event.to_timestamp_us, to)
  assert_eq(event.crossing_fraction, 0.5)
  assert_eq(event.position_m.y, 0.0)
  let diagonal = @events.GateCounter::new(
    "gate",
    [
      @events.LineGate::new("diagonal", { x: 0.0, y: 0.0, }, {
        x: 10.0,
        y: 10.0,
      }),
    ],
    @events.GateConfig::new(),
  )
  ignore(diagonal.update(frame(0L, [estimate(1, "1", 7.0, 3.0, 0L)])))
  let crossing = diagonal.update(
      frame(100L, [estimate(1, "1", 3.0, 7.0, 100L)]),
    ).crossings[0]
  assert_eq(crossing.direction, @events.NegativeToPositive)
  assert_eq(crossing.position_m.x, 5.0)
  assert_eq(crossing.position_m.y, 5.0)
}

///|
test "unrepresentable frame geometry fails before committing any totals or anchors" {
  let engine = @events.GateCounter::new(
    "gate",
    [
      @events.LineGate::new("large", { x: 1.0e308, y: 0.0, }, {
        x: 1.1e308,
        y: 0.0,
      }),
    ],
    @events.GateConfig::new(),
  )
  ignore(engine.update(frame(0L, [estimate(1, "1", 1.05e308, -1.0, 0L)])))
  let before = @debug.to_string(engine.checkpoint())
  invalid(() => {
    ignore(engine.update(frame(100L, [estimate(1, "1", -1.0e308, 1.0, 100L)])))
  })
  assert_eq(@debug.to_string(engine.checkpoint()), before)
  assert_eq(
    engine.update(frame(100L, [estimate(1, "1", 1.05e308, 1.0, 100L)])).crossings.length(),
    1,
  )
}

///|
test "rotated gates include computed endpoints without extending the finite segment" {
  let integer_gate = @events.GateCounter::new(
    "gate",
    [
      @events.LineGate::new(
        "integer",
        { x: 0.0, y: 0.0, },
        { x: 1.0, y: 6.0, },
        deadband_m=0.0,
      ),
    ],
    @events.GateConfig::new(),
  )
  ignore(integer_gate.update(frame(0L, [estimate(1, "1", -5.0, 7.0, 0L)])))
  let integer_result = integer_gate.update(
    frame(100L, [estimate(1, "1", 7.0, 5.0, 100L)]),
  )
  assert_eq(integer_result.crossings.length(), 1)
  assert_eq(integer_result.crossings[0].position_m.x, 1.0)
  assert_eq(integer_result.crossings[0].position_m.y, 6.0)
  // This endpoint's unit dot displacement rounds one ULP above norm(length).
  // Testing against that independently rounded length would exclude the end.
  let start : @types.Point2 = { x: -56.09727223062044, y: 29.24953864130191, }
  let end : @types.Point2 = { x: -62.36115774854238, y: -67.48476557615874, }
  let engine = @events.GateCounter::new(
    "gate",
    [@events.LineGate::new("rotated", start, end)],
    @events.GateConfig::new(),
  )
  ignore(engine.update(frame(0L, [estimate(1, "1", end.x - 1.0, end.y, 0L)])))
  let result = engine.update(
    frame(100L, [estimate(1, "1", end.x + 1.0, end.y, 100L)]),
  )
  assert_eq(result.crossings.length(), 1)
  assert_eq(result.crossings[0].position_m.x, end.x)
  assert_eq(result.crossings[0].position_m.y, end.y)
  // The same translated chord beyond the end must stay excluded.
  let outside = @events.GateCounter::new(
    "gate",
    [@events.LineGate::new("rotated", start, end)],
    @events.GateConfig::new(),
  )
  ignore(
    outside.update(frame(0L, [estimate(1, "1", end.x - 1.0, end.y - 1.0, 0L)])),
  )
  assert_eq(
    outside.update(
      frame(100L, [estimate(1, "1", end.x + 1.0, end.y - 1.0, 100L)]),
    ).crossings.length(),
    0,
  )
}

///|
test "unrepresentable crossing fractions reject the whole frame instead of returning an off-line point" {
  for (from_x, to_x) in [(1.0e308, -1.0), (1.0e-320, -1.0e308)] {
    let engine = @events.GateCounter::new(
      "gate",
      [
        @events.LineGate::new(
          "vertical",
          { x: 0.0, y: -10.0, },
          { x: 0.0, y: 10.0, },
          deadband_m=0.0,
        ),
      ],
      @events.GateConfig::new(),
    )
    ignore(engine.update(frame(0L, [estimate(1, "1", from_x, 0.0, 0L)])))
    let before = @debug.to_string(engine.checkpoint())
    invalid(() => {
      ignore(engine.update(frame(100L, [estimate(1, "1", to_x, 0.0, 100L)])))
    })
    assert_eq(@debug.to_string(engine.checkpoint()), before)
    assert_eq(
      engine.update(frame(100L, [estimate(1, "1", from_x, 0.0, 100L)])).crossings.length(),
      0,
    )
  }
}
