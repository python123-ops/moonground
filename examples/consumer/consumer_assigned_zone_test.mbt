///|
fn consumer_assigned_bundle(
  frame : @motion.FrameResult,
  shape : @zones.FootprintShape,
) -> @zones.FootprintAssignments raise @moonground.GroundError {
  @zones.FootprintAssignments::new(
    frame.timestamp_us,
    frame.tracks.map(track => {
      @zones.FootprintAssignment::new(track.track_id, track.segment_id, shape)
    }),
  )
}

///|
test "packaged assigned disk convex and missing targets retain original position bands" {
  let estimator = @motion.MotionEstimator::new(
    "consumer-assigned",
    @moonground.MotionConfig::new(min_observations=2, min_span_us=0L),
  )
  let observations = [
    consumer_transit_analysis_observation(1, 0.0),
    consumer_transit_analysis_observation(2, 0.0),
    consumer_transit_analysis_observation(3, 0.0),
  ]
  ignore(estimator.update(0L, observations))
  let frame = estimator.update(100000L, observations)
  let projector = @zones.ZoneProjector::new("consumer-assigned", [
    @zones.ConvexZone::new("workspace", [
      { x: -10.0, y: -10.0, },
      { x: 10.0, y: -10.0, },
      { x: 10.0, y: 10.0, },
      { x: -10.0, y: 10.0, },
    ]),
  ])
  let disk = @zones.DiskFootprint::new(0.125)
  let convex = consumer_convex_footprint()
  let assignments = @zones.FootprintAssignments::new(frame.timestamp_us, [
    @zones.FootprintAssignment::new(
      2,
      frame.tracks[1].segment_id,
      @zones.Convex(convex),
    ),
    @zones.FootprintAssignment::new(
      1,
      frame.tracks[0].segment_id,
      @zones.Disk(disk),
    ),
  ])
  let result = projector.evaluate_assigned(frame, assignments)
  assert_eq(result.evidence.map(row => row.track_id), [1, 2])
  assert_eq(result.unavailable[0].track_id, 3)
  assert_eq(result.unavailable[0].reason, @zones.MissingFootprint)
  guard result.evidence[0].evidence is @zones.Disk(disk_band) else {
    fail("disk target lost its explicit shape")
  }
  guard result.evidence[1].evidence is @zones.Convex(convex_band) else {
    fail("convex target lost its explicit shape")
  }
  let original_disk = projector.evaluate_disk(
      { ..frame, tracks: [frame.tracks[0]], },
      disk,
    ).evidence[0].evidence
  let original_convex = projector.evaluate_footprint(
      { ..frame, tracks: [frame.tracks[1]], },
      convex,
    ).evidence[0].evidence
  assert_eq(@debug.to_string(disk_band), @debug.to_string(original_disk))
  assert_eq(@debug.to_string(convex_band), @debug.to_string(original_convex))
  let position = projector.evaluate(frame)
  assert_eq(
    disk_band.faces[0].position_lower_m,
    position.evidence[0].evidence.faces[0].lower_m,
  )
  assert_eq(
    convex_band.faces[0].position_upper_m,
    position.evidence[1].evidence.faces[0].upper_m,
  )
  convex_band.vertices_offset_m.clear()
  assert_eq(
    projector.evaluate_assigned(frame, assignments).evidence.length(),
    2,
  )
}

///|
test "packaged assignment time and segment matching stay stateless across missing and nonReady rows" {
  let estimator = @motion.MotionEstimator::new(
    "consumer-assigned-binding",
    @moonground.MotionConfig::new(min_observations=2, min_span_us=0L),
  )
  let frame = estimator.update(9007199254740993L, [
    consumer_transit_analysis_observation(1, 0.0),
  ])
  let projector = @zones.ZoneProjector::new(frame.session_id, [
    @zones.ConvexZone::new("workspace", [
      { x: -10.0, y: -10.0, },
      { x: 10.0, y: -10.0, },
      { x: 10.0, y: 10.0, },
      { x: -10.0, y: 10.0, },
    ]),
  ])
  let shape : @zones.FootprintShape = @zones.Disk(
    @zones.DiskFootprint::new(1.0e308),
  )
  let entries = [
    @zones.FootprintAssignment::new(1, frame.tracks[0].segment_id, shape),
  ]
  let bundle = @zones.FootprintAssignments::new(frame.timestamp_us, entries)
  entries.clear()
  let result = projector.evaluate_assigned(frame, bundle)
  assert_eq(result.unavailable[0].reason, @zones.Position(@zones.Initializing))
  assert_eq(
    projector.evaluate_assigned(
      frame,
      @zones.FootprintAssignments::new(frame.timestamp_us, []),
    ).unavailable[0].reason,
    @zones.Position(@zones.Initializing),
  )
  let invalid = [
    @zones.FootprintAssignments::new(frame.timestamp_us - 1L, []),
    @zones.FootprintAssignments::new(frame.timestamp_us, [
      @zones.FootprintAssignment::new(1, "9223372036854775807", shape),
    ]),
    @zones.FootprintAssignments::new(frame.timestamp_us, [
      @zones.FootprintAssignment::new(2, "2", shape),
    ]),
  ]
  for assignments in invalid {
    try projector.evaluate_assigned(frame, assignments) catch {
      _ => ()
    } noraise {
      _ => fail("stale assignment was accepted")
    }
  }
  assert_eq(
    @debug.to_string(projector.evaluate_assigned(frame, bundle)),
    @debug.to_string(result),
  )
  try
    @zones.FootprintAssignments::new(frame.timestamp_us, [
      @zones.FootprintAssignment::new(1, "1", shape),
      @zones.FootprintAssignment::new(1, "1", shape),
    ])
  catch {
    _ => ()
  } noraise {
    _ => fail("duplicate target assignments accepted")
  }
}

///|
test "packaged Brown checkpoint and warm reframe reissue exact current target assignments" {
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
  let shape : @zones.FootprintShape = @zones.Convex(consumer_convex_footprint())
  let baseline = session.update(400000L, [right]).motion
  let continued = restored.update(400000L, [right]).motion
  let changed = adapted.update(400000L, [right.reframed(transform)]).motion
  let expected = projector.evaluate_assigned(
    baseline,
    consumer_assigned_bundle(baseline, shape),
  )
  assert_eq(
    @debug.to_string(
      projector.evaluate_assigned(
        continued,
        consumer_assigned_bundle(continued, shape),
      ),
    ),
    @debug.to_string(expected),
  )
  let actual = projector.evaluate_assigned(
    changed,
    consumer_assigned_bundle(changed, shape),
  )
  guard actual.evidence[0].evidence is @zones.Convex(actual_band) else {
    fail("convex assignment missing")
  }
  guard expected.evidence[0].evidence is @zones.Convex(expected_band) else {
    fail("convex baseline missing")
  }
  assert_eq(actual_band.decision, expected_band.decision)
  assert_eq(
    @debug.to_string(actual_band.vertices_offset_m),
    @debug.to_string(expected_band.vertices_offset_m),
  )
  for index in 0..<4 {
    assert_true(
      (actual_band.faces[index].lower_m - expected_band.faces[index].lower_m).abs() <
      1.0e-8,
    )
    assert_true(
      (actual_band.faces[index].upper_m - expected_band.faces[index].upper_m).abs() <
      1.0e-8,
    )
  }
}
