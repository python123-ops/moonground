///|
fn consumer_convex_footprint(
  scale~ : Double = 1.0,
) -> @zones.ConvexFootprint raise @moonground.GroundError {
  @zones.ConvexFootprint::new([
    { x: -0.25 * scale, y: -0.25 * scale, },
    { x: 1.0 * scale, y: -0.25 * scale, },
    { x: 1.0 * scale, y: 0.25 * scale, },
    { x: -0.25 * scale, y: 0.25 * scale, },
  ])
}

///|
test "packaged asymmetric footprint preserves anchor offset supports and closed contact" {
  let zone = @zones.ConvexZone::new(
    "workspace",
    [
      { x: 0.0, y: 0.0, },
      { x: 4.0, y: 0.0, },
      { x: 4.0, y: 4.0, },
      { x: 0.0, y: 4.0, },
    ],
    sigma_multiplier=0.0,
  )
  let covariance = @moonground.Covariance2::isotropic(0.1)
  let footprint = consumer_convex_footprint()
  let touching = zone.evaluate_footprint(
    { x: 3.0, y: 1.0, },
    covariance,
    footprint,
  )
  assert_eq(touching.decision, @zones.Inside)
  assert_eq(touching.faces[1].footprint_lower_m, -0.25)
  assert_eq(touching.faces[1].footprint_upper_m, 1.0)
  assert_eq(touching.faces[1].upper_m, 0.0)
  let outside_anchor = zone.evaluate_footprint(
    { x: 4.25, y: 1.0, },
    covariance,
    footprint,
  )
  assert_eq(outside_anchor.faces[1].lower_m, 0.0)
  assert_eq(outside_anchor.decision, @zones.Indeterminate)
  let vertex = @zones.ConvexFootprint::new([
    { x: 0.0, y: 0.0, },
    { x: 0.5, y: 0.0, },
    { x: 0.0, y: 0.25, },
  ])
  let original = zone.evaluate({ x: 1.0, y: 1.0, }, covariance)
  let one_sided = zone.evaluate_footprint(
    { x: 1.0, y: 1.0, },
    covariance,
    vertex,
  )
  assert_eq(one_sided.faces[1].footprint_lower_m, 0.0)
  assert_eq(one_sided.faces[1].lower_m, original.faces[1].lower_m)
  assert_eq(one_sided.faces[3].footprint_upper_m, 0.0)
  assert_eq(one_sided.faces[3].upper_m, original.faces[3].upper_m)
  let copy = footprint.vertices_offset_m()
  copy.clear()
  touching.vertices_offset_m.clear()
  assert_eq(footprint.vertices_offset_m().length(), 4)
}

///|
test "packaged convex footprint evaluation preserves position bands lifecycle and stateless errors" {
  let zone = @zones.ConvexZone::new("workspace", [
    { x: 0.0, y: -1.0, },
    { x: 10.0, y: -1.0, },
    { x: 10.0, y: 1.0, },
    { x: 0.0, y: 1.0, },
  ])
  let projector = @zones.ZoneProjector::new("consumer-footprint-zone", [zone])
  let footprint = consumer_convex_footprint()
  let motion = @motion.MotionEstimator::new(
    "consumer-footprint-zone",
    @moonground.MotionConfig::new(min_observations=2, min_span_us=0L),
  )
  let first = motion.update(0L, [consumer_transit_analysis_observation(7, 0.0)])
  assert_eq(
    projector.evaluate_footprint(first, footprint).unavailable[0].reason,
    @zones.Initializing,
  )
  let second = motion.update(100000L, [
    consumer_transit_analysis_observation(7, 0.1),
  ])
  let original = projector.evaluate(second)
  let disk = projector.evaluate_footprint(second, footprint)
  assert_eq(disk.evidence[0].evidence.decision, @zones.Inside)
  for index in 0..<4 {
    let face = disk.evidence[0].evidence.faces[index]
    assert_eq(
      face.position_lower_m,
      original.evidence[0].evidence.faces[index].lower_m,
    )
    assert_eq(
      face.position_upper_m,
      original.evidence[0].evidence.faces[index].upper_m,
    )
    assert_true(face.lower_m < face.position_lower_m)
    assert_true(face.upper_m > face.position_upper_m)
  }
  let expected = @debug.to_string(disk)
  disk.evidence[0].evidence.faces.clear()
  assert_eq(
    @debug.to_string(projector.evaluate_footprint(second, footprint)),
    expected,
  )
  assert_eq(
    projector.evaluate_footprint(first, footprint).unavailable[0].reason,
    @zones.Initializing,
  )
  try
    zone.evaluate_footprint(
      { x: 0.5, y: 0.5, },
      @moonground.Covariance2::isotropic(0.1),
      consumer_convex_footprint(scale=1.0e-30),
    )
  catch {
    _ => ()
  } noraise {
    _ =>
      fail("positive physical contribution may not disappear into uncertainty")
  }
  assert_eq(
    @debug.to_string(projector.evaluate_footprint(second, footprint)),
    expected,
  )
  let invalid_shapes : Array[Array[@moonground.Point2]] = [
    [],
    [{ x: 0.0, y: 0.0, }],
    [{ x: 1.0, y: 1.0, }, { x: 2.0, y: 1.0, }, { x: 1.0, y: 2.0, }],
  ]
  for points in invalid_shapes {
    try @zones.ConvexFootprint::new(points) catch {
      _ => ()
    } noraise {
      _ => fail("footprint must be strictly convex and contain its anchor")
    }
  }
}

///|
test "packaged Brown convex footprint region evidence preserves explicit metres across old checkpoints and reframe" {
  let (guarded, _, _, left, middle, right) = consumer_brown_guarded()
  guard guarded.checkpoint().analysis.measurement is Pixel(pixel) else {
    fail("pixel fixture missing")
  }
  let session = @moonground.MeasurementSession::from_checkpoint(pixel)
  ignore(session.update(0L, [left]))
  ignore(session.update(150000L, [middle]))
  ignore(session.update(300000L, [right]))
  let restored = @moonground.MeasurementSession::from_checkpoint(
    session.checkpoint(),
  )
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
  let footprint = consumer_convex_footprint()
  let expected = projector.evaluate_footprint(
    session.update(400000L, [right]).motion,
    footprint,
  )
  assert_eq(
    @debug.to_string(
      projector.evaluate_footprint(
        restored.update(400000L, [right]).motion,
        footprint,
      ),
    ),
    @debug.to_string(expected),
  )
  let actual = projector.evaluate_footprint(
    adapted.update(400000L, [right.reframed(transform)]).motion,
    footprint,
  )
  assert_eq(
    @debug.to_string(actual.evidence[0].evidence.vertices_offset_m),
    @debug.to_string(footprint.vertices_offset_m()),
  )
  assert_eq(
    actual.evidence[0].evidence.decision,
    expected.evidence[0].evidence.decision,
  )
  for index in 0..<4 {
    assert_true(
      (actual.evidence[0].evidence.faces[index].lower_m -
      expected.evidence[0].evidence.faces[index].lower_m).abs() <
      1.0e-8,
    )
    assert_true(
      (actual.evidence[0].evidence.faces[index].upper_m -
      expected.evidence[0].evidence.faces[index].upper_m).abs() <
      1.0e-8,
    )
  }
}
