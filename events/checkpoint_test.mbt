///|
fn checkpoint_fixture() -> @events.GateCheckpoint raise @types.GroundError {
  let engine = counter()
  ignore(engine.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
  ignore(engine.update(frame(100L, [estimate(1, "1", 5.0, 1.0, 100L)])))
  engine.checkpoint()
}

///|
test "gate checkpoints resume at every missing quality deadband and segment boundary" {
  let frames = [
    frame(0L, [estimate(1, "1", 5.0, -1.0, 0L, status=@motion.Initializing)]),
    frame(100L, [estimate(1, "1", 5.0, 0.0, 100L)]),
    frame(200L, [estimate(1, "1", 5.0, 1.0, 200L, status=@motion.Uncertain)]),
    frame(300L, []),
    frame(400L, [estimate(1, "1", 5.0, -1.0, 400L)]),
    frame(500L, [
      {
        ..estimate(1, "1", 5.0, 1.0, 400L, status=@motion.RejectedInnovation),
        position: None,
      },
    ]),
    frame(600L, [estimate(1, "1", 5.0, 1.0, 600L)]),
    frame(700L, [estimate(1, "2", 5.0, -1.0, 700L)], closed=["1"]),
    frame(800L, [estimate(1, "2", 5.0, 1.0, 800L, deviation=Some(0.3))]),
    frame(900L, [estimate(1, "2", 5.0, -1.0, 900L)]),
    frame(1000L, [estimate(1, "2", 5.0, 1.0, 1000L)]),
    frame(501000L, [estimate(1, "2", 5.0, -1.0, 501000L)]),
  ]
  let config = @events.GateConfig::new(max_position_std_m=0.2)
  let full = counter(config~)
  let expected = frames.map(frame => @debug.to_string(full.update(frame)))
  let final_checkpoint = @debug.to_string(full.checkpoint())
  for cut in 0..<=frames.length() {
    let prefix = counter(config~)
    for index in 0..<cut {
      ignore(prefix.update(frames[index]))
    }
    let resumed = @events.GateCounter::from_checkpoint(prefix.checkpoint())
    for index in cut..<frames.length() {
      assert_eq(
        @debug.to_string(resumed.update(frames[index])),
        expected[index],
      )
    }
    assert_eq(@debug.to_string(resumed.checkpoint()), final_checkpoint)
  }
}

///|
test "new exported restored and returned arrays never alias event counter state" {
  let gates = [line()]
  let engine = @events.GateCounter::new(
    "gate",
    gates,
    @events.GateConfig::new(),
  )
  gates[0] = line(id="replacement")
  ignore(engine.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
  let output = engine.update(frame(100L, [estimate(1, "1", 5.0, 1.0, 100L)]))
  let checkpoint = engine.checkpoint()
  let restored = @events.GateCounter::from_checkpoint(checkpoint)
  let before = @debug.to_string(engine.checkpoint())
  output.counts[0] = {
    gate_id: "tampered",
    negative_to_positive: 999L,
    positive_to_negative: 999L,
  }
  output.crossings.clear()
  checkpoint.gates[0] = line(id="different")
  checkpoint.counts[0] = {
    gate_id: "entry",
    negative_to_positive: 888L,
    positive_to_negative: 0L,
  }
  checkpoint.tracks[0].anchors[0] = None
  checkpoint.tracks.clear()
  assert_eq(@debug.to_string(engine.checkpoint()), before)
  assert_eq(@debug.to_string(restored.checkpoint()), before)
  let next = frame(200L, [estimate(1, "1", 5.0, -1.0, 200L)])
  assert_eq(
    @debug.to_string(engine.update(next)),
    @debug.to_string(restored.update(next)),
  )
  assert_eq(engine.checkpoint().counts[0].gate_id, "entry")
}

///|
test "gate checkpoint rejects incompatible totals identities anchor shapes and expired state" {
  let checkpoint = checkpoint_fixture()
  let track = checkpoint.tracks[0]
  let count = checkpoint.counts[0]
  let before = @debug.to_string(checkpoint)
  let bad_checkpoints = [
    { ..checkpoint, version: 0, },
    { ..checkpoint, version: 2, },
    { ..checkpoint, session_id: "", },
    { ..checkpoint, gates: [], },
    { ..checkpoint, gates: [line(), line()], },
    { ..checkpoint, counts: [], },
    { ..checkpoint, counts: [{ ..count, gate_id: "other", }], },
    { ..checkpoint, counts: [{ ..count, negative_to_positive: -1L, }], },
    { ..checkpoint, counts: [{ ..count, positive_to_negative: -1L, }], },
    { ..checkpoint, last_timestamp_us: None, },
    { ..checkpoint, last_timestamp_us: Some(-1L), },
    { ..checkpoint, last_timestamp_us: Some(99L), },
    { ..checkpoint, last_timestamp_us: Some(500100L), },
    { ..checkpoint, tracks: [track, track], },
    { ..checkpoint, tracks: [track, { ..track, track_id: 2, }], },
    {
      ..checkpoint,
      config: @events.GateConfig::new(max_tracks=1),
      tracks: [track, { ..track, track_id: 2, segment_id: "2", }],
    },
  ]
  for bad in bad_checkpoints {
    invalid(() => ignore(@events.GateCounter::from_checkpoint(bad)))
  }
  let bad_tracks = [
    { ..track, track_id: 0, },
    { ..track, segment_id: "0", },
    { ..track, segment_id: "01", },
    { ..track, anchors: [], },
    { ..track, anchors: [None, None], },
    {
      ..track,
      anchors: [Some({ timestamp_us: -1L, point_m: { x: 5.0, y: 1.0, }, })],
    },
    {
      ..track,
      anchors: [Some({ timestamp_us: 101L, point_m: { x: 5.0, y: 1.0, }, })],
    },
    {
      ..track,
      anchors: [Some({ timestamp_us: 100L, point_m: { x: 5.0, y: 0.0, }, })],
    },
    {
      ..track,
      anchors: [Some({ timestamp_us: 100L, point_m: { x: 5.0, y: 0.05, }, })],
    },
    {
      ..track,
      anchors: [
        Some({ timestamp_us: 100L, point_m: { x: 0.0 / 0.0, y: 1.0, }, }),
      ],
    },
  ]
  for bad in bad_tracks {
    invalid(() => {
      ignore(
        @events.GateCounter::from_checkpoint({ ..checkpoint, tracks: [bad], }),
      )
    })
  }
  let unstarted = counter().checkpoint()
  invalid(() => {
    ignore(
      @events.GateCounter::from_checkpoint({ ..unstarted, counts: [count], }),
    )
  })
  assert_eq(@debug.to_string(checkpoint), before)
}

///|
test "counter overflow rolls back earlier gate increments and permits the same frame timestamp retry" {
  let engine = @events.GateCounter::new(
    "gate",
    [line(id="first"), line(id="second")],
    @events.GateConfig::new(),
  )
  ignore(engine.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
  let saved = engine.checkpoint()
  saved.counts[1] = {
    ..saved.counts[1],
    negative_to_positive: 9223372036854775807L,
  }
  let saturated = @events.GateCounter::from_checkpoint(saved)
  let before = @debug.to_string(saturated.checkpoint())
  invalid(() => {
    ignore(saturated.update(frame(100L, [estimate(1, "1", 5.0, 1.0, 100L)])))
  })
  assert_eq(@debug.to_string(saturated.checkpoint()), before)
  let retry = saturated.update(frame(100L, [estimate(1, "1", 5.0, -2.0, 100L)]))
  assert_eq(retry.crossings.length(), 0)
  assert_eq(retry.counts[0].negative_to_positive, 0L)
  assert_eq(retry.counts[1].negative_to_positive, 9223372036854775807L)
}

///|
test "capacity is bounded per frame and expired missing identities retain no tombstones" {
  let engine = counter(config=@events.GateConfig::new(max_tracks=1))
  ignore(engine.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
  let before = @debug.to_string(engine.checkpoint())
  invalid(() => {
    ignore(
      engine.update(
        frame(100L, [
          estimate(1, "1", 5.0, 1.0, 100L),
          estimate(2, "2", 5.0, 1.0, 100L),
        ]),
      ),
    )
  })
  assert_eq(@debug.to_string(engine.checkpoint()), before)
  ignore(engine.update(frame(100L, [])))
  for id in 2..<102 {
    let timestamp = Int64::from_int(id) * 100L
    ignore(
      engine.update(
        frame(timestamp, [estimate(id, id.to_string(), 5.0, -1.0, timestamp)]),
      ),
    )
    assert_eq(engine.checkpoint().tracks.length(), 1)
    assert_eq(engine.checkpoint().tracks[0].track_id, id)
  }
  let empty = engine.update(frame(20000L, []))
  assert_eq(empty.counts[0].negative_to_positive, 0L)
  assert_eq(engine.checkpoint().tracks.length(), 0)
}
