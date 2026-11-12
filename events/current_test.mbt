///|
test "current membership follows accepted quality and segment identity without stale filters" {
  let engine = counter(config=@events.GateConfig::new(max_position_std_m=0.5))
  assert_false(engine.has_current_track(1, "1"))
  ignore(engine.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
  assert_true(engine.has_current_track(1, "1"))
  assert_false(engine.has_current_track(1, "2"))
  ignore(
    engine.update(
      frame(10L, [estimate(1, "1", 5.0, 1.0, 10L, deviation=Some(0.6))]),
    ),
  )
  assert_false(engine.has_current_track(1, "1"))
  ignore(engine.update(frame(20L, [estimate(1, "2", 5.0, 1.0, 20L)])))
  assert_true(engine.has_current_track(1, "2"))
  ignore(engine.update(frame(30L, [])))
  assert_false(engine.has_current_track(1, "2"))
}

///|
test "saved crossing validation reuses finite directed geometry and rejects altered fields" {
  let engine = counter()
  ignore(engine.update(frame(0L, [estimate(1, "1", 5.0, -1.0, 0L)])))
  let event = engine.update(frame(10L, [estimate(1, "1", 5.0, 1.0, 10L)])).crossings[0]
  event.validate(line())
  for
    bad in [
      { ..event, gate_id: "unknown", },
      { ..event, track_id: 0, },
      { ..event, segment_id: "01", },
      { ..event, from_timestamp_us: 10L, },
      { ..event, direction: @events.PositiveToNegative, },
      { ..event, crossing_fraction: 0.4, },
      { ..event, crossing_fraction: 0.0 / 0.0, },
      { ..event, position_m: { x: 6.0, y: 0.0, }, },
      { ..event, from_position_m: { x: 5.0, y: 0.0, }, },
      {
        ..event,
        from_position_m: { x: 11.0, y: -1.0, },
        to_position_m: { x: 11.0, y: 1.0, },
      },
    ] {
    invalid(() => bad.validate(line()))
  }
}
