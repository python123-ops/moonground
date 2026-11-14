///|
fn disk_square(
  multiplier~ : Double = 1.0,
) -> @zones.ConvexZone raise @types.GroundError {
  @zones.ConvexZone::new(
    "disk-square",
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
fn disk_position_unchanged(
  actual : @zones.DiskZoneBand,
  expected : @zones.ZoneBand,
) -> Unit raise {
  assert_eq(actual.zone_id, expected.zone_id)
  assert_eq(actual.sigma_multiplier, expected.sigma_multiplier)
  assert_eq(actual.faces.length(), expected.faces.length())
  for index, face in actual.faces {
    let original = expected.faces[index]
    assert_eq(face.edge_index, original.edge_index)
    assert_eq(
      @debug.to_string(face.outward_normal),
      @debug.to_string(original.outward_normal),
    )
    assert_eq(face.distance_m, original.distance_m)
    assert_eq(face.normal_std_m, original.normal_std_m)
    assert_eq(face.position_lower_m, original.lower_m)
    assert_eq(face.position_upper_m, original.upper_m)
  }
}

///|
test "disk radius is an explicit finite nonnegative physical parameter including zero" {
  for radius in [-1.0, -1.0e-300, 1.0 / 0.0, 0.0 / 0.0] {
    invalid(() => ignore(@zones.DiskFootprint::new(radius)))
  }
  for radius in [0.0, 4.9406564584124654e-324, 0.25, 1.7976931348623157e308] {
    assert_eq(@zones.DiskFootprint::new(radius).radius_m, radius)
  }
}

///|
test "zero radius copies every original statistical field bound decision and witness exactly" {
  let zero = @zones.DiskFootprint::new(0.0)
  for multiplier in [0.0, 1.0, 2.0] {
    let zone = disk_square(multiplier~)
    for
      position in [
        @types.Point2::{ x: 0.0, y: 0.0, },
        { x: 0.5, y: 0.5, },
        { x: 1.2, y: 1.2, },
        { x: 2.0, y: 2.0, },
      ] {
      let covariance = @types.Covariance2::new(0.0625, 0.01, 0.125)
      let original = zone.evaluate(position, covariance)
      let actual = zone.evaluate_disk(position, covariance, zero)
      disk_position_unchanged(actual, original)
      assert_eq(actual.decision, original.decision)
      assert_eq(actual.separating_edge_index, original.separating_edge_index)
      for index, face in actual.faces {
        assert_eq(face.lower_m, original.faces[index].lower_m)
        assert_eq(face.upper_m, original.faces[index].upper_m)
      }
    }
  }
}

///|
test "a contained center band can have a physical disk extending across the boundary" {
  let zone = disk_square(multiplier=2.0)
  let point : @types.Point2 = { x: 0.5, y: 0.5, }
  let covariance = @types.Covariance2::isotropic(0.1)
  assert_eq(zone.evaluate(point, covariance).decision, @zones.Inside)
  let disk = zone.evaluate_disk(
    point,
    covariance,
    @zones.DiskFootprint::new(0.4),
  )
  assert_eq(disk.decision, @zones.Indeterminate)
  assert_eq(disk.separating_edge_index, None)
  disk_position_unchanged(disk, zone.evaluate(point, covariance))
  assert_true(disk.faces[0].lower_m < disk.faces[0].position_lower_m)
  assert_true(disk.faces[0].upper_m > disk.faces[0].position_upper_m)
}

///|
test "an outside mean can touch or straddle the boundary without proving whole disk separation" {
  let zone = disk_square(multiplier=0.0)
  let footprint = @zones.DiskFootprint::new(0.5)
  let covariance = @types.Covariance2::isotropic(0.1)
  for x in [1.25, 1.5] {
    let point : @types.Point2 = { x, y: 0.5, }
    assert_eq(zone.evaluate(point, covariance).decision, @zones.Outside)
    assert_eq(
      zone.evaluate_disk(point, covariance, footprint).decision,
      @zones.Indeterminate,
    )
  }
  let outside = zone.evaluate_disk({ x: 1.75, y: 0.5, }, covariance, footprint)
  assert_eq(outside.decision, @zones.Outside)
  assert_eq(outside.separating_edge_index, Some(1))
  assert_eq(outside.faces[1].lower_m, 0.25)
}

///|
test "closed inner and outer tangencies retain exact equality and adjacent ULP decisions" {
  let zone = disk_square()
  let covariance = @types.Covariance2::isotropic(0.25)
  let footprint = @zones.DiskFootprint::new(0.25)
  let inside = zone.evaluate_disk({ x: 0.5, y: 0.5, }, covariance, footprint)
  assert_eq(inside.decision, @zones.Inside)
  for face in inside.faces {
    assert_eq(face.upper_m, 0.0)
  }
  let touching = zone.evaluate_disk({ x: 1.5, y: 0.5, }, covariance, footprint)
  assert_eq(touching.faces[1].lower_m, 0.0)
  assert_eq(touching.decision, @zones.Indeterminate)
  let next = (1.5.reinterpret_as_int64() + 1L).reinterpret_as_double()
  assert_eq(
    zone.evaluate_disk({ x: next, y: 0.5, }, covariance, footprint).decision,
    @zones.Outside,
  )
}

///|
test "zero sigma multiplier still validates covariance and retains a nonzero physical body" {
  let zone = disk_square(multiplier=0.0)
  let point : @types.Point2 = { x: 1.0, y: 0.5, }
  let covariance = @types.Covariance2::isotropic(0.25)
  let disk = zone.evaluate_disk(
    point,
    covariance,
    @zones.DiskFootprint::new(0.25),
  )
  assert_eq(zone.evaluate(point, covariance).decision, @zones.Inside)
  assert_eq(disk.decision, @zones.Indeterminate)
  assert_eq(disk.faces[1].position_lower_m, 0.0)
  assert_eq(disk.faces[1].position_upper_m, 0.0)
  assert_eq(disk.faces[1].lower_m, -0.25)
  assert_eq(disk.faces[1].upper_m, 0.25)
  assert_eq(disk.faces[1].normal_std_m, 0.25)
  invalid(() => {
    ignore(
      zone.evaluate_disk(
        point,
        { xx: 1.0, xy: 2.0, yy: 1.0, },
        @zones.DiskFootprint::new(0.25),
      ),
    )
  })
}

///|
test "changing physical radius does not alter anisotropic correlated position uncertainty" {
  let zone = disk_square()
  let point : @types.Point2 = { x: 0.5, y: 0.5, }
  let covariance = @types.Covariance2::new(0.015625, 0.01, 0.0625)
  let position = zone.evaluate(point, covariance)
  let small = zone.evaluate_disk(
    point,
    covariance,
    @zones.DiskFootprint::new(0.125),
  )
  let large = zone.evaluate_disk(
    point,
    covariance,
    @zones.DiskFootprint::new(0.5),
  )
  disk_position_unchanged(small, position)
  disk_position_unchanged(large, position)
  assert_eq(small.faces[0].normal_std_m, 0.25)
  assert_eq(small.faces[1].normal_std_m, 0.125)
  assert_eq(small.decision, @zones.Inside)
  assert_eq(large.decision, @zones.Indeterminate)
  assert_eq(covariance.xx, 0.015625)
}

///|
test "disk separation remains a sufficient face test and keeps the first original edge" {
  let zone = disk_square(multiplier=0.0)
  let covariance = @types.Covariance2::isotropic(0.1)
  let corner = zone.evaluate_disk(
    { x: 1.2, y: 1.2, },
    covariance,
    @zones.DiskFootprint::new(0.25),
  )
  assert_eq(corner.decision, @zones.Indeterminate)
  let outside = zone.evaluate_disk(
    { x: 2.0, y: 2.0, },
    covariance,
    @zones.DiskFootprint::new(0.25),
  )
  assert_eq(outside.decision, @zones.Outside)
  assert_eq(outside.separating_edge_index, Some(1))
  assert_eq(outside.faces.length(), 4)
  assert_true(outside.faces[1].lower_m > 0.0)
  assert_true(outside.faces[2].lower_m > 0.0)
}

///|
test "rotation reflection translation and metric scaling preserve physical and statistical support separately" {
  let vertices : Array[@types.Point2] = [
    { x: 0.0, y: 0.0, },
    { x: 3.0, y: 4.0, },
    { x: 0.0, y: 5.0, },
  ]
  let center : @types.Point2 = { x: 0.5, y: 2.0, }
  let reference = @zones.ConvexZone::new(
    "reference",
    vertices,
    sigma_multiplier=1.0,
  ).evaluate_disk(
    center,
    @types.Covariance2::isotropic(0.125),
    @zones.DiskFootprint::new(0.125),
  )
  for scale in [1.0e-100, 1.0, 1.0e100] {
    for reflect in [-1.0, 1.0] {
      let transform = (p : @types.Point2) => @types.Point2::{
        x: scale * (17.0 - p.y),
        y: scale * (-3.0 + reflect * p.x),
      }
      let actual = @zones.ConvexZone::new(
        "transformed",
        vertices.map(transform),
        sigma_multiplier=1.0,
      ).evaluate_disk(
        transform(center),
        @types.Covariance2::isotropic(0.125 * scale),
        @zones.DiskFootprint::new(0.125 * scale),
      )
      assert_eq(actual.decision, reference.decision)
      for index, face in actual.faces {
        assert_true(
          (face.lower_m / scale - reference.faces[index].lower_m).abs() <
          1.0e-13,
        )
        assert_true(
          (face.upper_m / scale - reference.faces[index].upper_m).abs() <
          1.0e-13,
        )
        assert_true(
          (face.position_lower_m / scale -
          reference.faces[index].position_lower_m).abs() <
          1.0e-13,
        )
      }
    }
  }
}

///|
test "positive disk and statistical contributions cannot silently swallow one another" {
  let point : @types.Point2 = { x: 0.5, y: 0.5, }
  invalid(() => {
    ignore(
      disk_square().evaluate_disk(
        point,
        @types.Covariance2::isotropic(0.25),
        @zones.DiskFootprint::new(1.0e-30),
      ),
    )
  })
  invalid(() => {
    ignore(
      disk_square().evaluate_disk(
        point,
        @types.Covariance2::isotropic(1.0e-10),
        @zones.DiskFootprint::new(1.0e10),
      ),
    )
  })
}

///|
test "combined overflow and finite radii that cannot expand original endpoints are typed errors" {
  let point : @types.Point2 = { x: 0.5, y: 0.5, }
  invalid(() => {
    ignore(
      disk_square(multiplier=1.0e154).evaluate_disk(
        point,
        @types.Covariance2::isotropic(1.0e154),
        @zones.DiskFootprint::new(1.0e308),
      ),
    )
  })
  invalid(() => {
    ignore(
      disk_square(multiplier=0.0).evaluate_disk(
        { x: 1.0e308, y: 0.0, },
        @types.Covariance2::isotropic(1.0),
        @zones.DiskFootprint::new(1.0e308),
      ),
    )
  })
  invalid(() => {
    ignore(
      disk_square().evaluate_disk(
        { x: 9007199254740996.0, y: 0.0, },
        @types.Covariance2::isotropic(2.0),
        @zones.DiskFootprint::new(0.5),
      ),
    )
  })
  invalid(() => {
    ignore(
      disk_square(multiplier=0.0).evaluate_disk(
        point,
        @types.Covariance2::isotropic(1.0),
        @zones.DiskFootprint::new(4.9406564584124654e-324),
      ),
    )
  })
}

///|
test "a large physical object never conceals unsupported original position evidence" {
  let footprint = @zones.DiskFootprint::new(1.0e300)
  invalid(() => {
    ignore(
      disk_square().evaluate_disk(
        { x: 1.0e300, y: 0.0, },
        @types.Covariance2::isotropic(1.0),
        footprint,
      ),
    )
  })
  invalid(() => {
    ignore(
      disk_square(multiplier=0.0).evaluate_disk(
        { x: 0.5, y: 0.5, },
        { xx: 1.0, xy: -0.9999999999999999, yy: 1.0, },
        footprint,
      ),
    )
  })
  invalid(() => {
    ignore(
      disk_square().evaluate_disk(
        { x: 0.0 / 0.0, y: 0.0, },
        @types.Covariance2::isotropic(1.0),
        footprint,
      ),
    )
  })
}

///|
test "disk frame admission retains Ready only and all original unavailable reasons" {
  let source = ready_frame()
  let track = source.tracks[0]
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
  let actual = evaluator.evaluate_disk(changed, @zones.DiskFootprint::new(0.25))
  let position = evaluator.evaluate(changed)
  assert_eq(actual.evidence.length(), 1)
  assert_eq(
    @debug.to_string(actual.unavailable),
    @debug.to_string(position.unavailable),
  )
  disk_position_unchanged(
    actual.evidence[0].evidence,
    position.evidence[0].evidence,
  )
}

///|
test "disk frame validation inherits original session capacity identities lifecycle and current fields" {
  let source = ready_frame()
  let track = source.tracks[0]
  let footprint = @zones.DiskFootprint::new(0.25)
  for
    frame in [
      { ..source, session_id: "other", },
      { ..source, timestamp_us: -1L, },
      { ..source, tracks: [track, track], },
      { ..source, tracks: [{ ..track, segment_id: "01", }], },
      { ..source, closed_segment_ids: ["1"], },
      { ..source, tracks: [{ ..track, position: None, }], },
      { ..source, tracks: [{ ..track, last_accepted_timestamp_us: 99999L, }], },
    ] {
    invalid(() => ignore(projector().evaluate_disk(frame, footprint)))
  }
  invalid(() => {
    ignore(
      projector(max_tracks=1).evaluate_disk(
        {
          ..source,
          tracks: [track, { ..track, track_id: 2, segment_id: "2", }],
        },
        footprint,
      ),
    )
  })
}

///|
test "disk rows preserve target and zone ordering and returned nested arrays do not alias configuration" {
  let zones = [square(id="second"), square(id="first")]
  let evaluator = @zones.ZoneProjector::new("zones", zones)
  let source = ready_frame()
  let track = source.tracks[0]
  let frame = {
    ..source,
    tracks: [
      { ..track, track_id: 9, segment_id: "9", },
      { ..track, track_id: 2, segment_id: "2", },
    ],
  }
  let before = @debug.to_string(frame)
  let footprint = @zones.DiskFootprint::new(0.25)
  let actual = evaluator.evaluate_disk(frame, footprint)
  let expected = @debug.to_string(actual)
  assert_eq(actual.evidence.map(row => row.track_id), [2, 2, 9, 9])
  assert_eq(actual.evidence.map(row => row.evidence.zone_id), [
    "second", "first", "second", "first",
  ])
  zones.clear()
  actual.evidence[0].evidence.faces.clear()
  actual.evidence.clear()
  actual.unavailable.clear()
  assert_eq(
    @debug.to_string(evaluator.evaluate_disk(frame, footprint)),
    expected,
  )
  assert_eq(@debug.to_string(frame), before)
}

///|
test "late disk expansion failure and reordered frames cannot advance a hidden state" {
  let evaluator = projector()
  let source = ready_frame()
  let footprint = @zones.DiskFootprint::new(0.25)
  let expected = @debug.to_string(evaluator.evaluate_disk(source, footprint))
  let track = source.tracks[0]
  invalid(() => {
    ignore(
      evaluator.evaluate_disk(
        {
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
        },
        footprint,
      ),
    )
  })
  ignore(
    evaluator.evaluate_disk(
      {
        ..source,
        timestamp_us: 0L,
        tracks: [{ ..track, last_accepted_timestamp_us: 0L, }],
      },
      footprint,
    ),
  )
  assert_eq(
    evaluator.evaluate_disk(
      { ..source, tracks: [], closed_segment_ids: ["1"], },
      footprint,
    ).evidence.length(),
    0,
  )
  assert_eq(
    @debug.to_string(evaluator.evaluate_disk(source, footprint)),
    expected,
  )
  assert_eq(
    @debug.to_string(evaluator.evaluate_disk(source, footprint)),
    expected,
  )
}

///|
test "existing motion checkpoints reproduce disk evidence with exact clocks above two to the fifty third" {
  let motion = @motion.MotionEstimator::new(
    "zones",
    @motion.MotionConfig::new(min_observations=2, min_span_us=0L, gate=1.0e12),
  )
  ignore(motion.update(9007199254740993L, [observation(0.0)]))
  ignore(motion.update(9007199254840993L, [observation(1.0)]))
  let restored = @motion.MotionEstimator::from_checkpoint(motion.checkpoint())
  let evaluator = projector()
  let footprint = @zones.DiskFootprint::new(0.25)
  for index, x in [2.0, 3.0, 4.0] {
    let time = 9007199254940993L + index.to_int64() * 100000L
    assert_eq(
      @debug.to_string(
        evaluator.evaluate_disk(
          motion.update(time, [observation(x)]),
          footprint,
        ),
      ),
      @debug.to_string(
        evaluator.evaluate_disk(
          restored.update(time, [observation(x)]),
          footprint,
        ),
      ),
    )
  }
}

///|
test "warm Brown pixel reframing and complete original checkpoint keep disk radius in meters" {
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
  let footprint = @zones.DiskFootprint::new(0.25)
  for index, x in [2.0, 3.0, 4.0] {
    let time = (index + 2).to_int64() * 100000L
    let actual = evaluator.evaluate_disk(
      adapted.update(time, [pixel(x).reframed(transform)]).motion,
      footprint,
    )
    let expected = evaluator.evaluate_disk(
      original.update(time, [pixel(x)]).motion,
      footprint,
    )
    assert_eq(
      @debug.to_string(actual),
      @debug.to_string(
        evaluator.evaluate_disk(
          restored.update(time, [pixel(x).reframed(transform)]).motion,
          footprint,
        ),
      ),
    )
    assert_eq(actual.evidence[0].evidence.radius_m, 0.25)
    for edge in 0..<4 {
      assert_true(
        (actual.evidence[0].evidence.faces[edge].lower_m -
        expected.evidence[0].evidence.faces[edge].lower_m).abs() <
        1.0e-9,
      )
      assert_true(
        (actual.evidence[0].evidence.faces[edge].upper_m -
        expected.evidence[0].evidence.faces[edge].upper_m).abs() <
        1.0e-9,
      )
    }
  }
}
