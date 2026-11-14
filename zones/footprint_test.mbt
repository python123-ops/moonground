///|
fn footprint_shape() -> @zones.ConvexFootprint raise @types.GroundError {
  @zones.ConvexFootprint::new([
    { x: -0.25, y: -0.25, },
    { x: 1.0, y: -0.25, },
    { x: 1.0, y: 0.25, },
    { x: -0.25, y: 0.25, },
  ])
}

///|
fn footprint_box(
  extent : Double,
) -> @zones.ConvexFootprint raise @types.GroundError {
  @zones.ConvexFootprint::new([
    { x: -extent, y: -extent, },
    { x: extent, y: -extent, },
    { x: extent, y: extent, },
    { x: -extent, y: extent, },
  ])
}

///|
test "footprint frames reuse unavailable admission and skip support work when no current Ready evidence exists" {
  let source = ready_frame()
  let track = source.tracks[0]
  let shape = footprint_shape()
  let changed = {
    ..source,
    tracks: [
      track,
      { ..track, track_id: 2, segment_id: "2", status: @motion.Initializing, },
      { ..track, track_id: 3, segment_id: "3", status: @motion.Uncertain, },
      {
        ..track,
        track_id: 4,
        segment_id: "4",
        status: @motion.RejectedInnovation,
      },
      {
        ..track,
        track_id: 5,
        segment_id: "5",
        status: @motion.NumericalFailure,
      },
    ],
  }
  let evaluator = projector()
  let actual = evaluator.evaluate_footprint(changed, shape)
  let statistical = evaluator.evaluate(changed)
  assert_eq(actual.evidence.length(), 1)
  assert_eq(
    @debug.to_string(actual.unavailable),
    @debug.to_string(statistical.unavailable),
  )
  for index, face in actual.evidence[0].evidence.faces {
    assert_eq(
      face.position_lower_m,
      statistical.evidence[0].evidence.faces[index].lower_m,
    )
    assert_eq(
      face.position_upper_m,
      statistical.evidence[0].evidence.faces[index].upper_m,
    )
  }
  let narrow_axis = @zones.ConvexZone::new(
    "tiny-direction",
    [{ x: 0.0, y: 0.0, }, { x: 1.0e-310, y: 1.0, }, { x: 1.0, y: 1.0, }],
    sigma_multiplier=0.0,
  )
  let unsupported_support = @zones.ZoneProjector::new("zones", [narrow_axis])
  assert_eq(unsupported_support.evaluate(source).evidence.length(), 1)
  invalid(() => {
    ignore(unsupported_support.evaluate_footprint(source, footprint_box(1.0)))
  })
  let skipped = unsupported_support.evaluate_footprint(
    {
      ..source,
      tracks: [
        {
          ..track,
          status: @motion.Uncertain,
          position: Some({ x: 0.0 / 0.0, y: 0.0, }),
        },
      ],
    },
    shape,
  )
  assert_eq(skipped.evidence.length(), 0)
  assert_eq(skipped.unavailable[0].reason, @zones.Uncertain)
  assert_eq(
    unsupported_support.evaluate_footprint(
      { ..source, tracks: [], closed_segment_ids: ["1"], },
      shape,
    ).evidence.length(),
    0,
  )
}

///|
test "footprint entry inherits complete frame identity capacity current field and lifecycle validation" {
  let source = ready_frame()
  let track = source.tracks[0]
  let shape = footprint_shape()
  for
    frame in [
      { ..source, session_id: "other", },
      { ..source, timestamp_us: -1L, },
      { ..source, tracks: [track, track], },
      { ..source, tracks: [{ ..track, segment_id: "01", }], },
      { ..source, closed_segment_ids: ["1"], },
      { ..source, tracks: [{ ..track, position: None, }], },
      { ..source, tracks: [{ ..track, position_covariance: None, }], },
      { ..source, tracks: [{ ..track, last_accepted_timestamp_us: 99999L, }], },
    ] {
    invalid(() => ignore(projector().evaluate_footprint(frame, shape)))
  }
  invalid(() => {
    ignore(
      projector(max_tracks=1).evaluate_footprint(
        {
          ..source,
          tracks: [track, { ..track, track_id: 2, segment_id: "2", }],
        },
        shape,
      ),
    )
  })
}

///|
test "per zone footprint supports remain aligned across sorted Ready targets and unavailable rows" {
  let zones = [
    square(id="second"),
    @zones.ConvexZone::new(
      "first",
      [{ x: -2.0, y: -2.0, }, { x: 6.0, y: -2.0, }, { x: -2.0, y: 6.0, }],
      sigma_multiplier=0.0,
    ),
  ]
  let evaluator = @zones.ZoneProjector::new("zones", zones)
  let source = ready_frame()
  let track = source.tracks[0]
  let frame = {
    ..source,
    tracks: [
      {
        ..track,
        track_id: 9,
        segment_id: "9",
        position: Some({ x: 2.0, y: 1.0, }),
      },
      { ..track, track_id: 3, segment_id: "3", status: @motion.Uncertain, },
      { ..track, track_id: 2, segment_id: "2", },
    ],
  }
  let shape = footprint_shape()
  let result = evaluator.evaluate_footprint(frame, shape)
  assert_eq(result.evidence.map(row => row.track_id), [2, 2, 9, 9])
  assert_eq(result.evidence.map(row => row.evidence.zone_id), [
    "second", "first", "second", "first",
  ])
  assert_eq(result.unavailable[0].track_id, 3)
  for index, row in result.evidence {
    let point = if row.track_id == 2 {
      track.position.unwrap()
    } else {
      @types.Point2::{ x: 2.0, y: 1.0, }
    }
    assert_eq(
      @debug.to_string(row.evidence),
      @debug.to_string(
        zones[index % zones.length()].evaluate_footprint(
          point,
          track.position_covariance.unwrap(),
          shape,
        ),
      ),
    )
  }
}

///|
test "footprint source getters and every returned row own detached vertex and face arrays" {
  let shapes : Array[@types.Point2] = [
    { x: -0.25, y: -0.25, },
    { x: 1.0, y: -0.25, },
    { x: 1.0, y: 0.25, },
    { x: -0.25, y: 0.25, },
  ]
  let shape = @zones.ConvexFootprint::new(shapes)
  let configured = [square(id="one"), square(id="two")]
  let evaluator = @zones.ZoneProjector::new("zones", configured)
  let frame = ready_frame()
  let original = @debug.to_string(frame)
  let result = evaluator.evaluate_footprint(frame, shape)
  let expected = @debug.to_string(result)
  shapes.clear()
  shape.vertices_offset_m().clear()
  configured.clear()
  result.evidence[0].evidence.vertices_offset_m.clear()
  assert_eq(result.evidence[1].evidence.vertices_offset_m.length(), 4)
  result.evidence[0].evidence.faces.clear()
  assert_eq(result.evidence[1].evidence.faces.length(), 4)
  result.evidence.clear()
  result.unavailable.clear()
  assert_eq(
    @debug.to_string(evaluator.evaluate_footprint(frame, shape)),
    expected,
  )
  assert_eq(@debug.to_string(frame), original)
}

///|
test "a late footprint expansion failure cannot change same time retries repeats or reordered frame evaluation" {
  let evaluator = projector()
  let source = ready_frame()
  let track = source.tracks[0]
  let shape = footprint_shape()
  let expected = @debug.to_string(evaluator.evaluate_footprint(source, shape))
  let invalid_frame = {
    ..source,
    tracks: [
      track,
      {
        ..track,
        track_id: 2,
        segment_id: "2",
        position: Some({ x: 1.0e300, y: 0.0, }),
      },
    ],
  }
  assert_eq(evaluator.evaluate(invalid_frame).evidence.length(), 2)
  invalid(() => ignore(evaluator.evaluate_footprint(invalid_frame, shape)))
  ignore(
    evaluator.evaluate_footprint(
      {
        ..source,
        timestamp_us: 0L,
        tracks: [{ ..track, last_accepted_timestamp_us: 0L, }],
      },
      shape,
    ),
  )
  let corrected = {
    ..source,
    tracks: [track, { ..track, track_id: 2, segment_id: "2", }],
  }
  assert_eq(evaluator.evaluate_footprint(corrected, shape).evidence.length(), 2)
  assert_eq(
    @debug.to_string(evaluator.evaluate_footprint(source, shape)),
    expected,
  )
  assert_eq(
    @debug.to_string(evaluator.evaluate_footprint(source, shape)),
    expected,
  )
}

///|
test "footprint numerical domains retain both positive contributions and strict endpoint expansion" {
  let zone = disk_square()
  let point : @types.Point2 = { x: 0.5, y: 0.5, }
  invalid(() => {
    ignore(
      zone.evaluate_footprint(
        point,
        @types.Covariance2::isotropic(1.0e-10),
        footprint_box(1.0e10),
      ),
    )
  })
  invalid(() => {
    ignore(
      zone.evaluate_footprint(
        { x: 9007199254740996.0, y: 0.0, },
        @types.Covariance2::isotropic(2.0),
        footprint_box(0.5),
      ),
    )
  })
  invalid(() => {
    ignore(
      disk_square(multiplier=1.0e154).evaluate_footprint(
        point,
        @types.Covariance2::isotropic(1.0e154),
        footprint_box(8.0e307),
      ),
    )
  })
  invalid(() => {
    ignore(
      disk_square(multiplier=0.0).evaluate_footprint(
        point,
        { xx: 1.0, xy: -0.9999999999999999, yy: 1.0, },
        footprint_box(1.0),
      ),
    )
  })
}

///|
test "complete original motion checkpoints reproduce asymmetric footprint evidence above exact Double integer time" {
  let motion = @motion.MotionEstimator::new(
    "zones",
    @motion.MotionConfig::new(min_observations=2, min_span_us=0L, gate=1.0e12),
  )
  ignore(motion.update(9007199254740993L, [observation(0.0)]))
  ignore(motion.update(9007199254840993L, [observation(1.0)]))
  let restored = @motion.MotionEstimator::from_checkpoint(motion.checkpoint())
  let evaluator = projector()
  let shape = footprint_shape()
  for index, x in [2.0, 3.0, 4.0] {
    let time = 9007199254940993L + index.to_int64() * 100000L
    assert_eq(
      @debug.to_string(
        evaluator.evaluate_footprint(
          motion.update(time, [observation(x)]),
          shape,
        ),
      ),
      @debug.to_string(
        evaluator.evaluate_footprint(
          restored.update(time, [observation(x)]),
          shape,
        ),
      ),
    )
  }
}

///|
test "warm Brown pixel reframing leaves deterministic ground footprint orientation and offsets unchanged" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    [
      { x: -10.0, y: -10.0, },
      { x: 10.0, y: -10.0, },
      { x: 10.0, y: 10.0, },
      { x: -10.0, y: 10.0, },
    ],
    max_meters_per_pixel=2.0,
  )
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let original = @moonground.MeasurementSession::new(
    "zones",
    calibration,
    @motion.MotionConfig::new(min_observations=2, min_span_us=0L, gate=1.0e12),
    camera~,
  )
  let pixel = (x : Double) => {
    @moonground.PixelObservation::new(
      1,
      { x, y: 0.0, },
      @types.Covariance2::isotropic(0.01),
    )
  }
  ignore(original.update(0L, [pixel(0.0)]))
  ignore(original.update(100000L, [pixel(1.0)]))
  let transform = @types.PixelTransform::new(
    scale_x=2.0,
    scale_y=0.5,
    offset_x=4.0,
    offset_y=-2.0,
  )
  let adapted = original.reframed(transform)
  let restored = @moonground.MeasurementSession::from_checkpoint(
    adapted.checkpoint(),
  )
  let evaluator = projector()
  let shape = footprint_shape()
  for index, x in [2.0, 3.0, 4.0] {
    let time = (index + 2).to_int64() * 100000L
    let actual = evaluator.evaluate_footprint(
      adapted.update(time, [pixel(x).reframed(transform)]).motion,
      shape,
    )
    let expected = evaluator.evaluate_footprint(
      original.update(time, [pixel(x)]).motion,
      shape,
    )
    assert_eq(
      @debug.to_string(actual),
      @debug.to_string(
        evaluator.evaluate_footprint(
          restored.update(time, [pixel(x).reframed(transform)]).motion,
          shape,
        ),
      ),
    )
    assert_eq(
      @debug.to_string(actual.evidence[0].evidence.vertices_offset_m),
      @debug.to_string(shape.vertices_offset_m()),
    )
    for edge in 0..<4 {
      let face = actual.evidence[0].evidence.faces[edge]
      let original_face = expected.evidence[0].evidence.faces[edge]
      assert_eq(face.footprint_lower_m, original_face.footprint_lower_m)
      assert_eq(face.footprint_upper_m, original_face.footprint_upper_m)
      assert_true((face.lower_m - original_face.lower_m).abs() < 1.0e-9)
      assert_true((face.upper_m - original_face.upper_m).abs() < 1.0e-9)
    }
  }
}
