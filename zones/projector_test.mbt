///|
fn invalid(action : () -> Unit raise @types.GroundError) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid zone frame accepted")
  }
}

///|
fn square(
  id~ : String = "square",
) -> @zones.ConvexZone raise @types.GroundError {
  @zones.ConvexZone::new(
    id,
    [
      { x: 0.0, y: 0.0, },
      { x: 1.0, y: 0.0, },
      { x: 1.0, y: 1.0, },
      { x: 0.0, y: 1.0, },
    ],
    sigma_multiplier=0.0,
  )
}

///|
fn projector(
  max_tracks~ : Int32 = 1000,
) -> @zones.ZoneProjector raise @types.GroundError {
  @zones.ZoneProjector::new("zones", [square()], max_tracks~)
}

///|
fn observation(x : Double) -> @types.GroundObservation raise @types.GroundError {
  @types.GroundObservation::new(
    1,
    { x, y: 0.0, },
    @types.Covariance2::isotropic(0.01),
  )
}

///|
fn ready_frame() -> @motion.FrameResult raise @types.GroundError {
  let estimator = @motion.MotionEstimator::new(
    "zones",
    @motion.MotionConfig::new(min_observations=2, min_span_us=0L, gate=1.0e12),
  )
  ignore(estimator.update(0L, [observation(0.0)]))
  estimator.update(100000L, [observation(1.0)])
}

///|
test "projector configuration bounds full face work before evaluating any tracks" {
  invalid(() => ignore(@zones.ZoneProjector::new("", [square()])))
  invalid(() => ignore(@zones.ZoneProjector::new("zones", [])))
  invalid(() => ignore(@zones.ZoneProjector::new("zones", [square(), square()])))
  for max_tracks in [0, 10001] {
    invalid(() => ignore(projector(max_tracks~)))
  }
  ignore(projector(max_tracks=10000))
  let zones = Array::makei(16, i => square(id=i.to_string()))
  ignore(@zones.ZoneProjector::new("zones", zones))
  zones.push(square(id="extra"))
  invalid(() => ignore(@zones.ZoneProjector::new("zones", zones)))
  let vertices = Array::makei(32, i => @types.Point2::{
    x: i.to_double(),
    y: (i * i).to_double(),
  })
  let detailed = [
    @zones.ConvexZone::new("one", vertices),
    @zones.ConvexZone::new("two", vertices),
  ]
  ignore(@zones.ZoneProjector::new("zones", detailed, max_tracks=1024))
  invalid(() => {
    ignore(@zones.ZoneProjector::new("zones", detailed, max_tracks=1025))
  })
}

///|
test "current Ready rows are sorted by numeric target then configured zone order" {
  let source = ready_frame()
  let track = source.tracks[0]
  let result = @zones.ZoneProjector::new("zones", [
    square(id="second"),
    square(id="first"),
  ]).evaluate({
    ..source,
    tracks: [
      { ..track, track_id: 9, segment_id: "9", },
      { ..track, track_id: 2, segment_id: "2", },
    ],
  })
  assert_eq(result.evidence.map(row => row.track_id), [2, 2, 9, 9])
  assert_eq(result.evidence.map(row => row.evidence.zone_id), [
    "second", "first", "second", "first",
  ])
  assert_eq(result.evidence[0].evidence.faces.length(), 4)
  assert_eq(source.tracks[0].track_id, 1)
}

///|
test "unavailable statuses never revive retained filtered positions or override uncertainty policy" {
  let source = ready_frame()
  let track = source.tracks[0]
  let result = projector().evaluate({
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
  })
  assert_eq(result.evidence.length(), 1)
  assert_eq(result.unavailable.map(row => row.reason), [
    @zones.Initializing,
    @zones.Uncertain,
    @zones.RejectedInnovation,
    @zones.NumericalFailure,
  ])
  let unavailable = projector().evaluate({
    ..source,
    tracks: [
      {
        ..track,
        status: @motion.Uncertain,
        position: Some({ x: 1.0 / 0.0, y: 0.0, }),
      },
    ],
  })
  assert_eq(unavailable.evidence.length(), 0)
  assert_eq(unavailable.unavailable[0].segment_id, Some("1"))
}

///|
test "Ready requires actual current position covariance and never falls back to filter diagnostics" {
  let source = ready_frame()
  let track = source.tracks[0]
  for
    changed in [
      { ..track, position: None, },
      { ..track, position_covariance: None, },
      { ..track, last_accepted_timestamp_us: 99999L, },
      { ..track, position_covariance: Some({ xx: 1.0, xy: 2.0, yy: 1.0, }), },
      { ..track, position: Some({ x: 1.0 / 0.0, y: 0.0, }), },
    ] {
    invalid(() => ignore(projector().evaluate({ ..source, tracks: [changed], })))
  }
  assert_eq(projector().evaluate(source).evidence.length(), 1)
}

///|
test "all statuses enforce session time unique target and canonical Int64 segment identity" {
  let source = ready_frame()
  let track = source.tracks[0]
  invalid(() => ignore(projector().evaluate({ ..source, session_id: "other", })))
  invalid(() => ignore(projector().evaluate({ ..source, timestamp_us: -1L, })))
  invalid(() => {
    ignore(
      projector(max_tracks=1).evaluate({
        ..source,
        tracks: [track, { ..track, track_id: 2, segment_id: "2", }],
      }),
    )
  })
  for
    tracks in [
      [track, track],
      [track, { ..track, track_id: 2, }],
      [{ ..track, track_id: 0, }],
      [{ ..track, status: @motion.Uncertain, last_accepted_timestamp_us: -1L, }],
      [
        {
          ..track,
          status: @motion.NumericalFailure,
          last_accepted_timestamp_us: 100001L,
        },
      ],
    ] {
    invalid(() => ignore(projector().evaluate({ ..source, tracks, })))
  }
  for segment_id in ["", "0", "01", "+1", "-1", "9223372036854775808"] {
    invalid(() => {
      ignore(
        projector().evaluate({ ..source, tracks: [{ ..track, segment_id, }], }),
      )
    })
  }
  assert_eq(
    projector().evaluate({
      ..source,
      tracks: [{ ..track, segment_id: "9223372036854775807", }],
    }).evidence.length(),
    1,
  )
}

///|
test "closed segments are bounded canonical unique and cannot be currently accepted" {
  let source = ready_frame()
  for ids in [["0"], ["01"], ["2", "2"], ["1"]] {
    invalid(() => {
      ignore(projector().evaluate({ ..source, closed_segment_ids: ids, }))
    })
  }
  invalid(() => {
    ignore(
      projector(max_tracks=1).evaluate({
        ..source,
        tracks: [],
        closed_segment_ids: ["1", "2"],
      }),
    )
  })
  assert_eq(
    projector().evaluate({
      ..source,
      tracks: [{ ..source.tracks[0], status: @motion.RejectedInnovation, }],
      closed_segment_ids: ["1"],
    }).unavailable.length(),
    1,
  )
}

///|
test "late numerical failure and repeated reordered missing frames leave no hidden projector clock" {
  let source = ready_frame()
  let evaluator = projector()
  let expected = @debug.to_string(evaluator.evaluate(source))
  let track = source.tracks[0]
  invalid(() => {
    ignore(
      evaluator.evaluate({
        ..source,
        tracks: [
          track,
          {
            ..track,
            track_id: 2,
            segment_id: "2",
            position_covariance: Some({
              xx: 1.0,
              xy: -0.9999999999999999,
              yy: 1.0,
            }),
          },
        ],
      }),
    )
  })
  ignore(
    evaluator.evaluate({
      ..source,
      timestamp_us: 0L,
      tracks: [{ ..track, last_accepted_timestamp_us: 0L, }],
    }),
  )
  assert_eq(@debug.to_string(evaluator.evaluate(source)), expected)
  let missing = evaluator.evaluate({
    ..source,
    tracks: [],
    closed_segment_ids: ["1"],
  })
  assert_eq(missing.evidence.length(), 0)
  assert_eq(missing.unavailable.length(), 0)
  assert_eq(@debug.to_string(evaluator.evaluate(source)), expected)
}

///|
test "projector configuration and returned nested arrays are detached from callers" {
  let configured = [square()]
  let evaluator = @zones.ZoneProjector::new("zones", configured)
  let frame = ready_frame()
  let original = @debug.to_string(frame)
  let result = evaluator.evaluate(frame)
  let expected = @debug.to_string(result)
  configured.clear()
  result.evidence[0].evidence.faces.clear()
  result.evidence.clear()
  result.unavailable.clear()
  assert_eq(@debug.to_string(evaluator.evaluate(frame)), expected)
  assert_eq(@debug.to_string(frame), original)
}

///|
test "existing complete motion checkpoint reproduces current zone evidence above Double integer precision" {
  let estimator = @motion.MotionEstimator::new(
    "zones",
    @motion.MotionConfig::new(min_observations=2, min_span_us=0L, gate=1.0e12),
  )
  ignore(estimator.update(9007199254740993L, [observation(0.0)]))
  ignore(estimator.update(9007199254840993L, [observation(1.0)]))
  let restored = @motion.MotionEstimator::from_checkpoint(
    estimator.checkpoint(),
  )
  let evaluator = projector()
  for index, x in [2.0, 3.0, 4.0] {
    let timestamp = 9007199254940993L + index.to_int64() * 100000L
    assert_eq(
      @debug.to_string(
        evaluator.evaluate(estimator.update(timestamp, [observation(x)])),
      ),
      @debug.to_string(
        evaluator.evaluate(restored.update(timestamp, [observation(x)])),
      ),
    )
  }
}

///|
test "real initialization uncertain covariance and rejected innovation keep existing position readiness" {
  let estimator = @motion.MotionEstimator::new(
    "zones",
    @motion.MotionConfig::new(
      min_observations=2,
      min_span_us=0L,
      max_position_std_m=1.0e-8,
    ),
  )
  assert_eq(
    projector().evaluate(estimator.update(0L, [observation(0.0)])).unavailable[0].reason,
    @zones.Initializing,
  )
  let uncertain = estimator.update(100000L, [observation(0.0)])
  assert_eq(uncertain.tracks[0].status, @motion.Uncertain)
  assert_eq(
    projector().evaluate(uncertain).unavailable[0].reason,
    @zones.Uncertain,
  )
  assert_eq(
    projector().evaluate(estimator.update(200000L, [observation(100000.0)])).unavailable[0].reason,
    @zones.RejectedInnovation,
  )
}

///|
test "warm Brown reframing and existing complete checkpoint preserve current metric facet evidence" {
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
  for index, x in [2.0, 3.0, 4.0] {
    let time = (index + 2).to_int64() * 100000L
    let actual = evaluator.evaluate(
      adapted.update(time, [pixel(x).reframed(transform)]).motion,
    )
    let expected = evaluator.evaluate(original.update(time, [pixel(x)]).motion)
    assert_eq(
      @debug.to_string(actual),
      @debug.to_string(
        evaluator.evaluate(
          restored.update(time, [pixel(x).reframed(transform)]).motion,
        ),
      ),
    )
    for edge in 0..<4 {
      assert_true(
        (actual.evidence[0].evidence.faces[edge].distance_m -
        expected.evidence[0].evidence.faces[edge].distance_m).abs() <
        1.0e-9,
      )
      assert_true(
        (actual.evidence[0].evidence.faces[edge].normal_std_m -
        expected.evidence[0].evidence.faces[edge].normal_std_m).abs() <
        1.0e-9,
      )
    }
  }
}
