///|
fn consumer_disk_square(
  multiplier~ : Double = 2.0,
) -> @zones.ConvexZone raise @moonground.GroundError {
  @zones.ConvexZone::new(
    "workspace",
    [
      { x: 0.0, y: 0.0, },
      { x: 1.0, y: 0.0, },
      { x: 1.0, y: 1.0, },
      { x: 0.0, y: 1.0, },
    ],
    sigma_multiplier=multiplier,
  )
}

///|
test "packaged disk footprint distinguishes anchor and physical extent with closed tangencies" {
  let zone = consumer_disk_square(multiplier=0.0)
  let covariance = @moonground.Covariance2::isotropic(0.1)
  let footprint = @zones.DiskFootprint::new(0.125)
  assert_eq(footprint.radius_m, 0.125)
  assert_eq(
    zone.evaluate({ x: 0.9, y: 0.5, }, covariance).decision,
    @zones.Inside,
  )
  assert_eq(
    zone.evaluate_disk({ x: 0.9, y: 0.5, }, covariance, footprint).decision,
    @zones.Indeterminate,
  )
  let outer = zone.evaluate_disk({ x: 1.125, y: 0.5, }, covariance, footprint)
  assert_eq(outer.faces[1].lower_m, 0.0)
  assert_eq(outer.decision, @zones.Indeterminate)
  let inner = zone.evaluate_disk(
    { x: 0.5, y: 0.5, },
    covariance,
    @zones.DiskFootprint::new(0.5),
  )
  assert_eq(inner.decision, @zones.Inside)
  for face in inner.faces {
    assert_eq(face.upper_m, 0.0)
  }
  let positive = consumer_disk_square()
  let point = positive.evaluate({ x: 0.5, y: 0.5, }, covariance)
  let zero = positive.evaluate_disk(
    { x: 0.5, y: 0.5, },
    covariance,
    @zones.DiskFootprint::new(0.0),
  )
  assert_eq(point.decision, zero.decision)
  assert_eq(point.separating_edge_index, zero.separating_edge_index)
  for index in 0..<4 {
    assert_eq(zero.faces[index].lower_m, point.faces[index].lower_m)
    assert_eq(zero.faces[index].upper_m, point.faces[index].upper_m)
    assert_eq(zero.faces[index].position_lower_m, point.faces[index].lower_m)
    assert_eq(zero.faces[index].position_upper_m, point.faces[index].upper_m)
  }
}

///|
test "packaged disk evaluation preserves position bands lifecycle and stateless errors" {
  let zone = @zones.ConvexZone::new("workspace", [
    { x: 0.0, y: -1.0, },
    { x: 10.0, y: -1.0, },
    { x: 10.0, y: 1.0, },
    { x: 0.0, y: 1.0, },
  ])
  let projector = @zones.ZoneProjector::new("consumer-disk-zone", [zone])
  let footprint = @zones.DiskFootprint::new(0.125)
  let motion = @motion.MotionEstimator::new(
    "consumer-disk-zone",
    @moonground.MotionConfig::new(min_observations=2, min_span_us=0L),
  )
  let first = motion.update(0L, [consumer_transit_analysis_observation(7, 0.0)])
  assert_eq(
    projector.evaluate_disk(first, footprint).unavailable[0].reason,
    @zones.Initializing,
  )
  let second = motion.update(100000L, [
    consumer_transit_analysis_observation(7, 0.1),
  ])
  let original = projector.evaluate(second)
  let disk = projector.evaluate_disk(second, footprint)
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
    @debug.to_string(projector.evaluate_disk(second, footprint)),
    expected,
  )
  assert_eq(
    projector.evaluate_disk(first, footprint).unavailable[0].reason,
    @zones.Initializing,
  )
  try
    zone.evaluate_disk(
      { x: 0.5, y: 0.5, },
      @moonground.Covariance2::isotropic(0.1),
      @zones.DiskFootprint::new(1.0e-30),
    )
  catch {
    _ => ()
  } noraise {
    _ =>
      fail("positive physical contribution may not disappear into uncertainty")
  }
  assert_eq(
    @debug.to_string(projector.evaluate_disk(second, footprint)),
    expected,
  )
  for radius in [-1.0, 0.0 / 0.0, 1.0 / 0.0] {
    try @zones.DiskFootprint::new(radius) catch {
      _ => ()
    } noraise {
      _ => fail("physical radius must be finite and nonnegative")
    }
  }
}

///|
test "packaged Brown disk region evidence preserves explicit metres across old checkpoints and reframe" {
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
  let footprint = @zones.DiskFootprint::new(0.25)
  let expected = projector.evaluate_disk(
    session.update(400000L, [right]).motion,
    footprint,
  )
  assert_eq(
    @debug.to_string(
      projector.evaluate_disk(
        restored.update(400000L, [right]).motion,
        footprint,
      ),
    ),
    @debug.to_string(expected),
  )
  let actual = projector.evaluate_disk(
    adapted.update(400000L, [right.reframed(transform)]).motion,
    footprint,
  )
  assert_eq(actual.evidence[0].evidence.radius_m, 0.25)
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
