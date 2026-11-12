///|
test "status observes committed evidence without advancing its watermark or sample count" {
  let engine = monitor()
  assert_eq(engine.status(), @health.HealthStatus::Insufficient)
  for
    (time, expected) in [
      (0L, @health.Pending),
      (150000L, @health.Pending),
      (300000L, @health.Healthy),
    ] {
    let report = engine.update(time, observations())
    assert_eq(engine.status(), expected)
    assert_eq(engine.status(), report.status)
    let checkpoint = @debug.to_string(engine.checkpoint())
    assert_eq(engine.status(), expected)
    assert_eq(@debug.to_string(engine.checkpoint()), checkpoint)
    assert_eq(
      @health.CalibrationMonitor::from_checkpoint(engine.checkpoint()).status(),
      expected,
    )
  }
  assert_eq(
    engine.update(400000L, observations(shift=0.5)).status,
    @health.Pending,
  )
  assert_eq(engine.status(), @health.Pending)
  ignore(engine.update(550000L, observations(shift=0.5)))
  assert_eq(
    engine.update(700000L, observations(shift=0.5)).status,
    @health.Drift,
  )
  assert_eq(engine.status(), @health.Drift)
  ignore(engine.update(800000L, []))
  assert_eq(engine.status(), @health.HealthStatus::Insufficient)
}
