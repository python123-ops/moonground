///|
test "packaged closed convex zones explain tangent and conservatively disjoint corner evidence" {
  let vertices = [
    @moonground.Point2::new(0.0, 0.0),
    @moonground.Point2::new(1.0, 0.0),
    @moonground.Point2::new(1.0, 1.0),
    @moonground.Point2::new(0.0, 1.0),
  ]
  let zone = @zones.ConvexZone::new("workspace", vertices, sigma_multiplier=1.0)
  vertices[0] = { x: -100.0, y: -100.0, }
  let covariance = @moonground.Covariance2::isotropic(0.25)
  let corner = zone.evaluate({ x: 1.2, y: 1.2, }, covariance)
  assert_eq(corner.decision, @zones.Indeterminate)
  assert_true(corner.separating_edge_index is None)
  let separated = zone.evaluate({ x: 2.0, y: 0.5, }, covariance)
  assert_eq(separated.decision, @zones.Outside)
  assert_eq(separated.separating_edge_index, Some(1))
  assert_true(separated.faces[1].lower_m > 0.0)
  assert_eq(separated.faces[1].outward_normal.x, 1.0)
  let tangent = zone.evaluate({ x: 1.25, y: 0.5, }, covariance)
  assert_eq(tangent.faces[1].lower_m, 0.0)
  assert_eq(tangent.decision, @zones.Indeterminate)
  let saved_vertices = zone.vertices_m()
  saved_vertices[0] = { x: -100.0, y: -100.0, }
  assert_eq(zone.vertices_m()[0].x, 0.0)
  let enclosed = @zones.ConvexZone::new("tangent-inside", zone.vertices_m()).evaluate(
    { x: 0.5, y: 0.5, },
    covariance,
  )
  assert_eq(enclosed.decision, @zones.Inside)
  for face in enclosed.faces {
    assert_eq(face.upper_m, 0.0)
  }
  let exact = @zones.ConvexZone::new(
    "closed-corner",
    zone.vertices_m(),
    sigma_multiplier=0.0,
  ).evaluate({ x: 1.0, y: 1.0, }, covariance)
  assert_eq(exact.decision, @zones.Inside)
  assert_true(exact.faces[0].normal_std_m > 0.0)
}

///|
test "packaged zone projector is stateless detached and bounds all configured faces" {
  let zone = @zones.ConvexZone::new("workspace", [
    { x: 0.0, y: -1.0, },
    { x: 10.0, y: -1.0, },
    { x: 10.0, y: 1.0, },
    { x: 0.0, y: 1.0, },
  ])
  let zones = [zone]
  let projector = @zones.ZoneProjector::new("consumer-zone", zones)
  zones.clear()
  let motion = @motion.MotionEstimator::new(
    "consumer-zone",
    @moonground.MotionConfig::new(min_observations=2, min_span_us=0L),
  )
  let first = motion.update(0L, [consumer_transit_analysis_observation(7, 0.0)])
  assert_eq(
    projector.evaluate(first).unavailable[0].reason,
    @zones.Initializing,
  )
  let second = motion.update(100000L, [
    consumer_transit_analysis_observation(7, 0.1),
  ])
  let result = projector.evaluate(second)
  assert_eq(result.evidence.length(), 1)
  assert_eq(result.evidence[0].evidence.decision, @zones.Inside)
  let expected = @debug.to_string(result)
  result.evidence[0].evidence.faces.clear()
  assert_eq(@debug.to_string(projector.evaluate(second)), expected)
  assert_eq(
    projector.evaluate(first).unavailable[0].reason,
    @zones.Initializing,
  )
  let uncertain = {
    ..second,
    tracks: second.tracks.map(track => { ..track, status: @motion.Uncertain, }),
  }
  let masked = projector.evaluate(uncertain)
  assert_eq(masked.evidence.length(), 0)
  assert_eq(masked.unavailable[0].reason, @zones.Uncertain)
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
    _ => fail("stale positions must not become current region evidence")
  }
  assert_eq(@debug.to_string(projector.evaluate(second)), expected)
  let other = @zones.ConvexZone::new("other", zone.vertices_m())
  try
    @zones.ZoneProjector::new("consumer-zone", [zone, other], max_tracks=10000)
  catch {
    _ => ()
  } noraise {
    _ => fail("capacity times all configured faces must stay within 65536")
  }
}

///|
test "packaged Brown region evidence survives old checkpoints and warm pixel reframe" {
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
  let projector = @zones.ZoneProjector::new("guarded-transit", [
    @zones.ConvexZone::new("metric-workspace", [
      { x: -100.0, y: -100.0, },
      { x: 100.0, y: -100.0, },
      { x: 100.0, y: 100.0, },
      { x: -100.0, y: 100.0, },
    ]),
  ])
  let expected = projector.evaluate(session.update(400000L, [right]).motion)
  let continued = projector.evaluate(restored.update(400000L, [right]).motion)
  assert_eq(@debug.to_string(continued), @debug.to_string(expected))
  let actual = projector.evaluate(
    adapted.update(400000L, [right.reframed(transform)]).motion,
  )
  assert_eq(actual.evidence.length(), 1)
  assert_eq(
    actual.evidence[0].evidence.decision,
    expected.evidence[0].evidence.decision,
  )
  for index in 0..<4 {
    assert_true(
      (actual.evidence[0].evidence.faces[index].distance_m -
      expected.evidence[0].evidence.faces[index].distance_m).abs() <
      1.0e-8,
    )
    assert_true(
      (actual.evidence[0].evidence.faces[index].normal_std_m -
      expected.evidence[0].evidence.faces[index].normal_std_m).abs() <
      1.0e-8,
    )
  }
  assert_eq(saved.motion.last_timestamp_us, Some(300000L))
}
