///|
fn assigned_all(
  frame : @motion.FrameResult,
  shape : @zones.FootprintShape,
) -> @zones.FootprintAssignments raise @types.GroundError {
  @zones.FootprintAssignments::new(
    frame.timestamp_us,
    frame.tracks.map(track => {
      @zones.FootprintAssignment::new(track.track_id, track.segment_id, shape)
    }),
  )
}

///|
fn assigned_mixed(
  frame : @motion.FrameResult,
) -> @zones.FootprintAssignments raise @types.GroundError {
  @zones.FootprintAssignments::new(
    frame.timestamp_us,
    frame.tracks.map(track => {
      let shape : @zones.FootprintShape = if track.track_id == 1 {
        @zones.Disk(@zones.DiskFootprint::new(0.25))
      } else {
        @zones.Convex(footprint_shape())
      }
      @zones.FootprintAssignment::new(track.track_id, track.segment_id, shape)
    }),
  )
}

///|
fn assigned_limits(
  band : @zones.AssignedFootprintBand,
) -> Array[(Double, Double)] {
  match band {
    @zones.Disk(disk) => disk.faces.map(face => (face.lower_m, face.upper_m))
    @zones.Convex(convex) =>
      convex.faces.map(face => (face.lower_m, face.upper_m))
  }
}

///|
test "same current center can have different disk and asymmetric body relations with exact old path results" {
  let source = ready_frame()
  let track = { ..source.tracks[0], position: Some({ x: 0.5, y: 0.5, }), }
  let frame = {
    ..source,
    tracks: [track, { ..track, track_id: 2, segment_id: "2", }],
  }
  let evaluator = projector()
  let result = evaluator.evaluate_assigned(frame, assigned_mixed(frame))
  assert_eq(result.evidence.length(), 2)
  guard result.evidence[0].evidence is @zones.Disk(disk) else {
    fail("expected assigned disk")
  }
  guard result.evidence[1].evidence is @zones.Convex(convex) else {
    fail("expected assigned convex body")
  }
  assert_eq(disk.decision, @zones.Inside)
  assert_eq(convex.decision, @zones.Indeterminate)
  let old_disk = evaluator.evaluate_disk(
    { ..frame, tracks: [track], },
    @zones.DiskFootprint::new(0.25),
  )
  let old_convex = evaluator.evaluate_footprint(
    { ..frame, tracks: [frame.tracks[1]], },
    footprint_shape(),
  )
  assert_eq(
    @debug.to_string(disk),
    @debug.to_string(old_disk.evidence[0].evidence),
  )
  assert_eq(
    @debug.to_string(convex),
    @debug.to_string(old_convex.evidence[0].evidence),
  )
}

///|
test "mixed assignment order is irrelevant and output preserves numeric targets configured zones and reason ordering" {
  let source = ready_frame()
  let track = source.tracks[0]
  let frame = {
    ..source,
    tracks: [
      { ..track, track_id: 9, segment_id: "9", },
      { ..track, track_id: 3, segment_id: "3", status: @motion.Uncertain, },
      track,
      { ..track, track_id: 2, segment_id: "2", },
    ],
  }
  let evaluator = @zones.ZoneProjector::new("zones", [
    square(id="second"),
    square(id="first"),
  ])
  let bundle = @zones.FootprintAssignments::new(frame.timestamp_us, [
    @zones.FootprintAssignment::new(
      9,
      "9",
      @zones.Disk(@zones.DiskFootprint::new(0.25)),
    ),
    @zones.FootprintAssignment::new(
      3,
      "3",
      @zones.Disk(@zones.DiskFootprint::new(1.0e308)),
    ),
    @zones.FootprintAssignment::new(2, "2", @zones.Convex(footprint_shape())),
  ])
  let result = evaluator.evaluate_assigned(frame, bundle)
  assert_eq(result.evidence.map(row => row.track_id), [2, 2, 9, 9])
  assert_eq(
    result.evidence.map(row => {
      match row.evidence {
        @zones.Disk(band) => band.zone_id
        @zones.Convex(band) => band.zone_id
      }
    }),
    ["second", "first", "second", "first"],
  )
  assert_eq(result.unavailable.map(row => row.track_id), [1, 3])
  assert_eq(result.unavailable[0].reason, @zones.MissingFootprint)
  assert_eq(result.unavailable[1].reason, @zones.Position(@zones.Uncertain))
}

///|
test "assignment bundles and nested mixed results detach source arrays and every convex row" {
  let source = ready_frame()
  let track = source.tracks[0]
  let frame = {
    ..source,
    tracks: [track, { ..track, track_id: 2, segment_id: "2", }],
  }
  let records = [
    @zones.FootprintAssignment::new(
      1,
      "1",
      @zones.Disk(@zones.DiskFootprint::new(0.25)),
    ),
    @zones.FootprintAssignment::new(2, "2", @zones.Convex(footprint_shape())),
  ]
  let bundle = @zones.FootprintAssignments::new(frame.timestamp_us, records)
  let evaluator = @zones.ZoneProjector::new("zones", [
    square(id="one"),
    square(id="two"),
  ])
  let original_frame = @debug.to_string(frame)
  let result = evaluator.evaluate_assigned(frame, bundle)
  let expected = @debug.to_string(result)
  records.clear()
  guard result.evidence[0].evidence is @zones.Disk(disk) else {
    fail("expected disk")
  }
  guard result.evidence[2].evidence is @zones.Convex(first) else {
    fail("expected convex")
  }
  guard result.evidence[3].evidence is @zones.Convex(second) else {
    fail("expected second convex")
  }
  first.vertices_offset_m.clear()
  first.faces.clear()
  disk.faces.clear()
  assert_eq(second.vertices_offset_m.length(), 4)
  assert_eq(second.faces.length(), 4)
  result.evidence.clear()
  result.unavailable.clear()
  assert_eq(
    @debug.to_string(evaluator.evaluate_assigned(frame, bundle)),
    expected,
  )
  assert_eq(@debug.to_string(frame), original_frame)
}

///|
test "late shape failure permits explicit same timestamp correction and never carries old assignments forward" {
  let source = ready_frame()
  let track = source.tracks[0]
  let frame = {
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
  let evaluator = projector()
  assert_eq(evaluator.evaluate(frame).evidence.length(), 2)
  invalid(() => {
    ignore(evaluator.evaluate_assigned(frame, assigned_mixed(frame)))
  })
  let corrected = @zones.FootprintAssignments::new(frame.timestamp_us, [
    @zones.FootprintAssignment::new(
      1,
      "1",
      @zones.Disk(@zones.DiskFootprint::new(0.25)),
    ),
    @zones.FootprintAssignment::new(
      2,
      "2",
      @zones.Disk(@zones.DiskFootprint::new(0.0)),
    ),
  ])
  let expected = @debug.to_string(evaluator.evaluate_assigned(frame, corrected))
  let missing = evaluator.evaluate_assigned(
    frame,
    @zones.FootprintAssignments::new(frame.timestamp_us, []),
  )
  assert_eq(missing.evidence.length(), 0)
  assert_eq(missing.unavailable.map(row => row.reason), [
    @zones.MissingFootprint,
    @zones.MissingFootprint,
  ])
  let earlier = {
    ..source,
    timestamp_us: 0L,
    tracks: [{ ..track, last_accepted_timestamp_us: 0L, }],
  }
  ignore(
    evaluator.evaluate_assigned(
      earlier,
      assigned_all(earlier, @zones.Disk(@zones.DiskFootprint::new(0.25))),
    ),
  )
  assert_eq(
    @debug.to_string(evaluator.evaluate_assigned(frame, corrected)),
    expected,
  )
}

///|
test "explicit assigned zero disk preserves every original point band without a missing shape default" {
  let source = ready_frame()
  let evaluator = @zones.ZoneProjector::new("zones", [
    square(id="point"),
    disk_square(multiplier=2.0),
  ])
  let original = evaluator.evaluate(source)
  let result = evaluator.evaluate_assigned(
    source,
    assigned_all(source, @zones.Disk(@zones.DiskFootprint::new(0.0))),
  )
  assert_eq(result.unavailable.length(), 0)
  for index, row in result.evidence {
    guard row.evidence is @zones.Disk(disk) else { fail("expected zero disk") }
    disk_position_unchanged(disk, original.evidence[index].evidence)
    assert_eq(disk.decision, original.evidence[index].evidence.decision)
    assert_eq(
      disk.separating_edge_index,
      original.evidence[index].evidence.separating_edge_index,
    )
    for edge, face in disk.faces {
      assert_eq(
        face.lower_m,
        original.evidence[index].evidence.faces[edge].lower_m,
      )
      assert_eq(
        face.upper_m,
        original.evidence[index].evidence.faces[edge].upper_m,
      )
    }
  }
}

///|
test "actual maximum assigned convex work admits 128 targets 16 zones 32 faces and 32 shape vertices" {
  let vertices = Array::makei(32, index => @types.Point2::{
    x: index.to_double() - 15.5,
    y: (index * index).to_double() - 360.0,
  })
  let shape = @zones.ConvexFootprint::new(vertices)
  let zones = Array::makei(16, index => {
    @zones.ConvexZone::new(index.to_string(), vertices, sigma_multiplier=0.0)
  })
  let evaluator = @zones.ZoneProjector::new("zones", zones, max_tracks=128)
  let source = ready_frame()
  let track = source.tracks[0]
  let frame = {
    ..source,
    tracks: Array::makei(128, index => {
      ..track,
      track_id: index + 1,
      segment_id: (index + 1).to_string(),
      position: Some({ x: 0.0, y: 0.0, }),
    }),
  }
  let result = evaluator.evaluate_assigned(
    frame,
    assigned_all(frame, @zones.Convex(shape)),
  )
  assert_eq(result.evidence.length(), 2048)
  assert_eq(result.unavailable.length(), 0)
  let mut expanded_faces = 0
  let mut support_projections = 0
  for row in result.evidence {
    guard row.evidence is @zones.Convex(band) else {
      fail("expected maximum convex work")
    }
    assert_eq(band.faces.length(), 32)
    assert_eq(band.vertices_offset_m.length(), 32)
    expanded_faces += band.faces.length()
    support_projections += band.faces.length() * band.vertices_offset_m.length()
  }
  assert_eq(expanded_faces, 65536)
  assert_eq(support_projections, 2097152)
  invalid(() => {
    ignore(@zones.ZoneProjector::new("zones", zones, max_tracks=129))
  })
}

///|
test "old exact motion checkpoint continuation reissues mixed assignments instead of persisting a shape map" {
  let motion = @motion.MotionEstimator::new(
    "zones",
    @motion.MotionConfig::new(min_observations=2, min_span_us=0L, gate=1.0e12),
  )
  ignore(motion.update(9007199254740993L, [observation(0.0)]))
  ignore(motion.update(9007199254840993L, [observation(1.0)]))
  let restored = @motion.MotionEstimator::from_checkpoint(motion.checkpoint())
  let evaluator = projector()
  for index, x in [2.0, 3.0, 4.0] {
    let time = 9007199254940993L + index.to_int64() * 100000L
    let original_frame = motion.update(time, [observation(x)])
    let restored_frame = restored.update(time, [observation(x)])
    let shape : @zones.FootprintShape = if index % 2 == 0 {
      @zones.Disk(@zones.DiskFootprint::new(0.25))
    } else {
      @zones.Convex(footprint_shape())
    }
    assert_eq(
      @debug.to_string(
        evaluator.evaluate_assigned(
          original_frame,
          assigned_all(original_frame, shape),
        ),
      ),
      @debug.to_string(
        evaluator.evaluate_assigned(
          restored_frame,
          assigned_all(restored_frame, shape),
        ),
      ),
    )
  }
}

///|
test "warm Brown reframing and original checkpoint recovery keep mixed disk and ground oriented shape offsets" {
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
  let pixels = (x : Double) => {
    [
      @moonground.PixelObservation::new(
        1,
        { x, y: 0.0, },
        @types.Covariance2::isotropic(0.01),
      ),
      @moonground.PixelObservation::new(
        2,
        { x: x + 0.5, y: 0.0, },
        @types.Covariance2::isotropic(0.01),
      ),
    ]
  }
  ignore(original.update(0L, pixels(0.0)))
  ignore(original.update(100000L, pixels(1.0)))
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
  for index, x in [2.0, 3.0, 4.0] {
    let time = (index + 2).to_int64() * 100000L
    let actual_frame = adapted.update(
        time,
        pixels(x).map(pixel => pixel.reframed(transform)),
      ).motion
    let original_frame = original.update(time, pixels(x)).motion
    let restored_frame = restored.update(
        time,
        pixels(x).map(pixel => pixel.reframed(transform)),
      ).motion
    let actual = evaluator.evaluate_assigned(
      actual_frame,
      assigned_mixed(actual_frame),
    )
    let expected = evaluator.evaluate_assigned(
      original_frame,
      assigned_mixed(original_frame),
    )
    assert_eq(
      @debug.to_string(actual),
      @debug.to_string(
        evaluator.evaluate_assigned(
          restored_frame,
          assigned_mixed(restored_frame),
        ),
      ),
    )
    assert_eq(actual.evidence.length(), 2)
    for row, evidence in actual.evidence {
      let limits = assigned_limits(evidence.evidence)
      let original_limits = assigned_limits(expected.evidence[row].evidence)
      for edge, (lower, upper) in limits {
        let (expected_lower, expected_upper) = original_limits[edge]
        assert_true((lower - expected_lower).abs() < 1.0e-9)
        assert_true((upper - expected_upper).abs() < 1.0e-9)
      }
    }
  }
}
