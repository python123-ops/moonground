///|
test "packaged ellipse intersection resolves the supporting face corner gap and exposes an edge witness" {
  let zone = consumer_disk_square(multiplier=1.0)
  let point : @moonground.Point2 = { x: 1.125, y: 1.125, }
  let covariance = @moonground.Covariance2::new(0.015625, 0.0, 0.015625)
  assert_eq(zone.evaluate(point, covariance).decision, @zones.Indeterminate)
  let result = zone.intersect_position(point, covariance)
  assert_eq(result.decision, @zones.Disjoint)
  assert_true(result.minimum_quadratic_lower <= 2.0)
  assert_true(result.minimum_quadratic_upper >= 2.0)
  assert_true(result.minimum_quadratic_lower > 1.0)
  guard result.witness_edge_index is Some(edge) &&
    result.witness_fraction is Some(fraction) else {
    fail("outside centre requires an explicit boundary candidate")
  }
  let vertices = zone.vertices_m()
  let start = vertices[edge]
  let end = vertices[(edge + 1) % vertices.length()]
  let x = start.x + fraction * (end.x - start.x)
  let y = start.y + fraction * (end.y - start.y)
  let candidate = (
      (x - point.x) * (x - point.x) + (y - point.y) * (y - point.y)
    ) /
    0.015625
  assert_true(candidate <= result.minimum_quadratic_upper)
  let overlap = zone.intersect_position(
    { x: 0.5, y: 0.5, },
    @moonground.Covariance2::isotropic(10.0),
  )
  assert_eq(overlap.decision, @zones.Intersects)
  assert_eq(overlap.minimum_quadratic_upper, 0.0)
  assert_true(overlap.witness_edge_index is None)
}

///|
test "packaged ellipse frames replay existing metric checkpoints with exact large clocks and no new state" {
  let motion = @motion.MotionEstimator::new(
    "consumer-intersection",
    @moonground.MotionConfig::new(
      min_observations=2,
      min_span_us=0L,
      gate=1.0e12,
    ),
  )
  let observe = (x : Double) => {
    @moonground.GroundObservation::new(
      7,
      { x, y: 1.125, },
      @moonground.Covariance2::isotropic(0.125),
    )
  }
  let evaluator = @zones.ZoneProjector::new("consumer-intersection", [
    consumer_disk_square(multiplier=1.0),
  ])
  let first = motion.update(9007199254740993L, [observe(1.125)])
  assert_eq(
    evaluator.intersect_position(first).unavailable[0].reason,
    @zones.Initializing,
  )
  ignore(motion.update(9007199254840993L, [observe(1.125)]))
  let restored = @motion.MotionEstimator::from_checkpoint(motion.checkpoint())
  for index in 0..<3 {
    let timestamp = 9007199254940993L + index.to_int64() * 100000L
    let observation = observe(1.125 + index.to_double() * 0.01)
    let frame = motion.update(timestamp, [observation])
    let result = evaluator.intersect_position(frame)
    let expected = @debug.to_string(result)
    assert_eq(result.timestamp_us, timestamp)
    assert_eq(
      @debug.to_string(
        evaluator.intersect_position(restored.update(timestamp, [observation])),
      ),
      expected,
    )
    let malformed = {
      ..frame,
      tracks: frame.tracks.map(track => { ..track, position_covariance: None, }),
    }
    try evaluator.intersect_position(malformed) catch {
      _ => ()
    } noraise {
      _ => fail("Ready admission must require explicit current covariance")
    }
    result.evidence.clear()
    assert_eq(@debug.to_string(evaluator.intersect_position(frame)), expected)
  }
}

///|
test "packaged Brown ellipse evidence follows warm pixel reframe and original complete checkpoint recovery" {
  let (guarded, _, _, left, middle, right) = consumer_brown_guarded()
  guard guarded.checkpoint().analysis.measurement is Pixel(pixel) else {
    fail("pixel fixture missing")
  }
  let session = @moonground.MeasurementSession::from_checkpoint(pixel)
  ignore(session.update(0L, [left]))
  ignore(session.update(150000L, [middle]))
  ignore(session.update(300000L, [right]))
  let saved = session.checkpoint()
  let restored = @moonground.MeasurementSession::from_checkpoint(saved)
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=1.25,
    offset_x=-15.0,
    offset_y=8.0,
  )
  let reframed = session.reframed(transform)
  let evaluator = @zones.ZoneProjector::new("guarded-transit", [
    consumer_disk_square(multiplier=1.0),
  ])
  let expected = evaluator.intersect_position(
    session.update(400000L, [right]).motion,
  )
  assert_eq(
    @debug.to_string(
      evaluator.intersect_position(restored.update(400000L, [right]).motion),
    ),
    @debug.to_string(expected),
  )
  let adapted = evaluator.intersect_position(
    reframed.update(400000L, [right.reframed(transform)]).motion,
  )
  assert_eq(adapted.evidence.length(), 1)
  let actual = adapted.evidence[0].evidence
  let original = expected.evidence[0].evidence
  assert_eq(actual.decision, original.decision)
  assert_true(
    (actual.minimum_quadratic_lower - original.minimum_quadratic_lower).abs() <=
    1.0e-7 * (1.0 + original.minimum_quadratic_lower),
  )
  assert_true(
    (actual.minimum_quadratic_upper - original.minimum_quadratic_upper).abs() <=
    1.0e-7 * (1.0 + original.minimum_quadratic_upper),
  )
  assert_eq(saved.motion.last_timestamp_us, Some(300000L))
}
