///|
test "evidence membership retains unconfirmed targets while original anchors expire" {
  let engine = evidence_counter(config=@events.GateConfig::new(max_gap_us=300L))
  let id = engine.checkpoint().gates[0].gate_id
  ignore(engine.update(frame(0L, [evidence_track(1, "1", 5.0, -1.0, 0L)])))
  let original = engine.anchor(1, "1", id).unwrap()
  ignore(engine.update(frame(100L, [evidence_track(1, "1", 5.0, 0.0, 100L)])))
  assert_true(engine.has_current_track(1, "1"))
  assert_eq(engine.anchor(1, "1", id).unwrap().timestamp_us, 0L)
  assert_true(engine.anchor(1, "2", id) is None)
  ignore(engine.update(frame(300L, [evidence_track(1, "1", 5.0, 0.0, 300L)])))
  assert_true(engine.has_current_track(1, "1"))
  assert_true(engine.anchor(1, "1", id) is None)
  assert_eq(original.point_m.y, -1.0)
  ignore(engine.update(frame(301L, [])))
  assert_false(engine.has_current_track(1, "1"))
}

///|
test "evidence anchor queries reject malformed identities and unknown gates without mutation" {
  let engine = evidence_counter()
  let id = engine.checkpoint().gates[0].gate_id
  let before = @debug.to_string(engine.checkpoint())
  invalid(() => ignore(engine.anchor(0, "1", id)))
  invalid(() => ignore(engine.anchor(1, "01", id)))
  invalid(() => ignore(engine.anchor(1, "0", id)))
  invalid(() => ignore(engine.anchor(1, "1", "unknown")))
  assert_true(engine.anchor(1, "1", id) is None)
  assert_false(engine.has_current_track(1, "01"))
  assert_eq(@debug.to_string(engine.checkpoint()), before)
}

///|
test "read evidence anchors remain independent of fork updates and exported arrays" {
  let engine = evidence_counter()
  let id = engine.checkpoint().gates[0].gate_id
  let covariance = @types.Covariance2::new(0.04, 0.01, 0.02)
  ignore(
    engine.update(
      frame(0L, [evidence_track(1, "1", 5.0, -1.0, 0L, covariance~)]),
    ),
  )
  let anchor = engine.anchor(1, "1", id).unwrap()
  let branch = engine.fork()
  ignore(branch.update(frame(1L, [evidence_track(1, "1", 5.0, 1.0, 1L)])))
  let snapshot = engine.checkpoint()
  snapshot.tracks[0].anchors.clear()
  assert_eq(anchor.timestamp_us, 0L)
  assert_eq(anchor.covariance.xy, 0.01)
  assert_eq(engine.anchor(1, "1", id).unwrap().point_m.y, -1.0)
  assert_eq(branch.anchor(1, "1", id).unwrap().point_m.y, 1.0)
}
