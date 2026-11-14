///|
test "intersection metric witness follows covariance correlation and threshold scale" {
  let covariance = @types.Covariance2::new(1.0, 0.5, 1.0)
  let point : @types.Point2 = { x: 2.0, y: 0.75, }
  let small = intersection_ref_square(k=0.5).intersect_position(
    point, covariance,
  )
  intersection_ref_encloses(small, 1.0)
  assert_eq(small.decision, @zones.Disjoint)
  assert_eq(small.witness_edge_index, Some(1))
  guard small.witness_fraction is Some(fraction) else {
    fail("missing edge parameter")
  }
  assert_true((fraction - 0.25).abs() < 1.0e-12)
  assert_eq(small.witness_position_m.x, 1.0)
  assert_true((small.witness_position_m.y - 0.25).abs() < 1.0e-12)
  let large = intersection_ref_square(k=2.0).intersect_position(
    point, covariance,
  )
  intersection_ref_encloses(large, 1.0)
  assert_eq(large.decision, @zones.Intersects)
  assert_eq(large.minimum_quadratic_lower, small.minimum_quadratic_lower)
  assert_eq(large.minimum_quadratic_upper, small.minimum_quadratic_upper)
}

///|
test "intersection does not require legacy face endpoint expansion for far means" {
  let zone = intersection_ref_square(k=2.0)
  let point : @types.Point2 = { x: 1.0e16, y: 0.5, }
  let covariance = @types.Covariance2::isotropic(0.1)
  invalid(() => ignore(zone.evaluate(point, covariance)))
  let result = zone.intersect_position(point, covariance)
  assert_eq(result.decision, @zones.Disjoint)
  assert_true(result.minimum_quadratic_lower > 1.0e33)
  assert_true(@types.is_finite(result.minimum_quadratic_upper))
}

///|
test "intersection rejects invalid mathematical inputs and unrepresentable threshold bounds" {
  let zone = intersection_ref_square()
  let covariance = @types.Covariance2::isotropic(1.0)
  for
    point in [
      @types.Point2::{ x: 1.0 / 0.0, y: 0.0, },
      { x: 0.0, y: 0.0 / 0.0, },
    ] {
    invalid(() => ignore(zone.intersect_position(point, covariance)))
  }
  invalid(() => {
    ignore(
      zone.intersect_position({ x: 0.5, y: 0.5, }, {
        xx: 1.0,
        xy: 2.0,
        yy: 1.0,
      }),
    )
  })
  invalid(() => {
    ignore(
      intersection_ref_square(k=1.0e308).intersect_position(
        { x: 0.5, y: 0.5, },
        covariance,
      ),
    )
  })
  assert_eq(
    zone.intersect_position({ x: 0.5, y: 0.5, }, covariance).decision,
    @zones.Intersects,
  )
}

///|
test "intersection frames sort identities retain configured zone order and exact large clocks" {
  let source = ready_frame()
  let timestamp = 9007199254740993L
  let track = { ..source.tracks[0], last_accepted_timestamp_us: timestamp, }
  let result = @zones.ZoneProjector::new("zones", [
    square(id="second"),
    square(id="first"),
  ]).intersect_position({
    ..source,
    timestamp_us: timestamp,
    tracks: [
      { ..track, track_id: 9, segment_id: "9", },
      { ..track, track_id: 2, segment_id: "2", },
    ],
  })
  assert_eq(result.timestamp_us, timestamp)
  assert_eq(result.evidence.map(row => row.track_id), [2, 2, 9, 9])
  assert_eq(result.evidence.map(row => row.evidence.zone_id), [
    "second", "first", "second", "first",
  ])
  assert_eq(result.unavailable.length(), 0)
}

///|
test "intersection respects all unavailable statuses without reviving invalid retained positions" {
  let source = ready_frame()
  let track = source.tracks[0]
  let result = projector().intersect_position({
    ..source,
    tracks: [
      {
        ..track,
        status: @motion.Initializing,
        position: Some({ x: 1.0 / 0.0, y: 0.0, }),
      },
      {
        ..track,
        track_id: 2,
        segment_id: "2",
        status: @motion.Uncertain,
        position_covariance: None,
      },
      {
        ..track,
        track_id: 3,
        segment_id: "3",
        status: @motion.RejectedInnovation,
      },
      {
        ..track,
        track_id: 4,
        segment_id: "4",
        status: @motion.NumericalFailure,
      },
    ],
    closed_segment_ids: ["3", "4"],
  })
  assert_eq(result.evidence.length(), 0)
  assert_eq(result.unavailable.map(row => row.reason), [
    @zones.Initializing,
    @zones.Uncertain,
    @zones.RejectedInnovation,
    @zones.NumericalFailure,
  ])
  assert_eq(result.unavailable.map(row => row.track_id), [1, 2, 3, 4])
}

///|
test "intersection structural validation applies to unavailable identities and closed segments" {
  let source = ready_frame()
  let track = { ..source.tracks[0], status: @motion.Uncertain, }
  let evaluator = projector(max_tracks=1)
  invalid(() => {
    ignore(evaluator.intersect_position({ ..source, session_id: "other", }))
  })
  invalid(() => {
    ignore(evaluator.intersect_position({ ..source, timestamp_us: -1L, }))
  })
  invalid(() => {
    ignore(evaluator.intersect_position({ ..source, tracks: [track, track], }))
  })
  for segment_id in ["0", "01", "9223372036854775808"] {
    invalid(() => {
      ignore(
        evaluator.intersect_position({
          ..source,
          tracks: [{ ..track, segment_id, }],
        }),
      )
    })
  }
  for closed_segment_ids in [["1"], ["2", "2"], ["0"]] {
    invalid(() => {
      ignore(evaluator.intersect_position({ ..source, closed_segment_ids, }))
    })
  }
  invalid(() => {
    ignore(
      evaluator.intersect_position({
        ..source,
        tracks: [{ ..track, track_id: 0, }],
      }),
    )
  })
  invalid(() => {
    ignore(
      evaluator.intersect_position({
        ..source,
        tracks: [
          { ..track, last_accepted_timestamp_us: source.timestamp_us + 1L, },
        ],
      }),
    )
  })
}

///|
test "intersection Ready admission requires current explicit position and covariance" {
  let source = ready_frame()
  let track = source.tracks[0]
  let evaluator = projector()
  for
    changed in [
      { ..track, position: None, },
      { ..track, position_covariance: None, },
      { ..track, last_accepted_timestamp_us: source.timestamp_us - 1L, },
      { ..track, position: Some({ x: 0.0 / 0.0, y: 0.0, }), },
      { ..track, position_covariance: Some({ xx: 1.0, xy: 2.0, yy: 1.0, }), },
    ] {
    invalid(() => {
      ignore(evaluator.intersect_position({ ..source, tracks: [changed], }))
    })
  }
  assert_eq(evaluator.intersect_position(source).evidence.length(), 1)
}

///|
test "intersection repeated frames failure retries and output mutation retain no hidden state" {
  let source = ready_frame()
  let configured = [square()]
  let evaluator = @zones.ZoneProjector::new("zones", configured)
  configured.clear()
  let result = evaluator.intersect_position(source)
  let expected = @debug.to_string(result)
  let original = @debug.to_string(source)
  let bad = {
    ..source.tracks[0],
    track_id: 2,
    segment_id: "2",
    position_covariance: Some({ xx: 1.0, xy: 2.0, yy: 1.0, }),
  }
  invalid(() => {
    ignore(
      evaluator.intersect_position({
        ..source,
        tracks: [source.tracks[0], bad],
      }),
    )
  })
  result.evidence.clear()
  result.unavailable.clear()
  assert_eq(@debug.to_string(evaluator.intersect_position(source)), expected)
  let empty = evaluator.intersect_position({
    ..source,
    tracks: [],
    closed_segment_ids: ["1"],
  })
  assert_eq(empty.evidence.length(), 0)
  assert_eq(empty.unavailable.length(), 0)
  assert_eq(@debug.to_string(evaluator.intersect_position(source)), expected)
  assert_eq(@debug.to_string(source), original)
}
