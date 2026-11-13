///|
test "packaged directed velocity separates anisotropic covariance and closed threshold equality" {
  let covariance = @moonground.Covariance2::new(0.000001, 0.0, 1000000.0)
  let probe = @velocity.VelocityProbe::new(
    "along",
    { x: 1.0e308, y: 0.0, },
    0.5,
  )
  let band = probe.evaluate({ x: 1.0, y: 0.0, }, covariance)
  assert_true((band.axis_std_mps - 0.001).abs() < 1.0e-15)
  assert_eq(band.decision, @velocity.Above)
  let closed = @velocity.VelocityProbe::new("closed", { x: 1.0, y: 0.0, }, 0.5)
  let precise = @moonground.Covariance2::isotropic(0.25)
  assert_eq(
    closed.evaluate({ x: 0.0, y: 0.0, }, precise).decision,
    @velocity.AtOrBelow,
  )
  assert_eq(
    closed.evaluate({ x: 1.0, y: 0.0, }, precise).decision,
    @velocity.Indeterminate,
  )
  let exact = @velocity.VelocityProbe::new(
    "mean-only",
    { x: 1.0, y: 0.0, },
    -1.0,
    sigma_multiplier=0.0,
  ).evaluate({ x: -1.0, y: 0.0, }, precise)
  assert_eq(exact.decision, @velocity.AtOrBelow)
  assert_eq(exact.lower_mps, -1.0)
  assert_eq(exact.upper_mps, -1.0)
  assert_true(exact.axis_std_mps > 0.0)
  assert_eq(covariance.linear_std({ x: 0.0, y: 0.0, }), 0.0)
  let orthogonal = @velocity.VelocityProbe::new(
    "orthogonal",
    { x: 1.0, y: 1.0, },
    0.0,
  ).evaluate({ x: 1.0, y: -1.0, }, precise)
  assert_eq(orthogonal.component_mps, 0.0)
  assert_eq(orthogonal.decision, @velocity.Indeterminate)
}

///|
test "packaged velocity projector is stateless detached and preserves unavailable motion" {
  let estimator = @motion.MotionEstimator::new(
    "consumer-velocity",
    @moonground.MotionConfig::new(min_observations=2, min_span_us=0L),
  )
  let probes = [@velocity.VelocityProbe::new("along", { x: 0.0, y: 1.0, }, 0.0)]
  let projector = @velocity.VelocityProjector::new("consumer-velocity", probes)
  probes.clear()
  let first = estimator.update(0L, [
    consumer_transit_analysis_observation(7, 0.0),
  ])
  let unavailable = projector.evaluate(first)
  assert_eq(unavailable.evidence.length(), 0)
  assert_eq(unavailable.unavailable[0].reason, @velocity.Initializing)
  let second = estimator.update(100000L, [
    consumer_transit_analysis_observation(7, 0.1),
  ])
  let evidence = projector.evaluate(second)
  assert_eq(evidence.evidence.length(), 1)
  let expected = @debug.to_string(evidence)
  evidence.evidence.clear()
  assert_eq(@debug.to_string(projector.evaluate(second)), expected)
  assert_eq(
    @debug.to_string(projector.evaluate(first)),
    @debug.to_string(unavailable),
  )
  let stale = {
    ..second,
    tracks: second.tracks.map(track => {
      ..track,
      last_accepted_timestamp_us: 99999L,
    }),
  }
  try projector.evaluate(stale) catch {
    _ => ()
  } noraise {
    _ => fail("stale Ready vectors must not become current velocity evidence")
  }
  assert_eq(@debug.to_string(projector.evaluate(second)), expected)
  let uncertain = {
    ..second,
    tracks: second.tracks.map(track => { ..track, status: @motion.Uncertain, }),
  }
  let masked = projector.evaluate(uncertain)
  assert_eq(masked.evidence.length(), 0)
  assert_eq(masked.unavailable[0].reason, @velocity.Uncertain)
  let track = uncertain.tracks[0]
  let explicit = @velocity.VelocityProbe::new(
    "explicit",
    { x: 0.0, y: 1.0, },
    0.0,
  ).evaluate(track.velocity.unwrap(), track.velocity_covariance.unwrap())
  assert_true(explicit.axis_std_mps > 0.0)
}

///|
test "packaged Brown velocity survives old checkpoint continuation and warm pixel reframe" {
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
  let adapted = session.reframed(transform)
  let projector = @velocity.VelocityProjector::new("guarded-transit", [
    @velocity.VelocityProbe::new("direction", { x: 3.0, y: 4.0, }, -0.5),
  ])
  let expected = projector.evaluate(session.update(400000L, [right]).motion)
  let continued = projector.evaluate(restored.update(400000L, [right]).motion)
  assert_eq(@debug.to_string(continued), @debug.to_string(expected))
  let actual = projector.evaluate(
    adapted.update(400000L, [right.reframed(transform)]).motion,
  )
  assert_eq(actual.evidence.length(), 1)
  assert_true(
    (actual.evidence[0].evidence.component_mps -
    expected.evidence[0].evidence.component_mps).abs() <
    1.0e-8,
  )
  assert_true(
    (actual.evidence[0].evidence.axis_std_mps -
    expected.evidence[0].evidence.axis_std_mps).abs() <
    1.0e-8,
  )
  assert_eq(
    actual.evidence[0].evidence.decision,
    expected.evidence[0].evidence.decision,
  )
  assert_eq(saved.motion.last_timestamp_us, Some(300000L))
}
