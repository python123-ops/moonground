///|
fn invalid(action : () -> Unit raise @types.GroundError) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid guarded input was accepted")
  }
}

///|
fn calibration() -> @moonground.GroundCalibration raise @types.GroundError {
  @moonground.GroundCalibration::from_homography(
    [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    [
      { x: -10.0, y: -10.0, },
      { x: 10.0, y: -10.0, },
      { x: 10.0, y: 10.0, },
      { x: -10.0, y: 10.0, },
    ],
    max_meters_per_pixel=2.0,
  )
}

///|
fn analysis(
  max_tracks~ : Int32 = 10,
  gate_tracks~ : Int32 = 10,
  camera? : @moonground.CameraModel,
  projection~ : @moonground.GroundCalibration = calibration(),
) -> @analysis.AnalysisSession raise @types.GroundError {
  @analysis.AnalysisSession::from_pixel(
    @moonground.MeasurementSession::new(
      "guarded",
      projection,
      @moonground.MotionConfig::new(max_tracks~, gate=1.0e12),
      camera?,
    ),
    @events.GateCounter::new(
      "guarded",
      [
        @events.LineGate::new(
          "door",
          { x: -5.0, y: 0.0, },
          { x: 5.0, y: 0.0, },
          deadband_m=0.1,
        ),
      ],
      @events.GateConfig::new(max_tracks=gate_tracks),
    ),
  )
}

///|
fn monitor(
  config~ : @health.HealthConfig = @health.HealthConfig::new(
    confirmation_us=100000L,
    min_observations=2,
  ),
  camera? : @moonground.CameraModel,
  projection~ : @moonground.GroundCalibration = calibration(),
) -> @health.CalibrationMonitor raise @types.GroundError {
  @health.CalibrationMonitor::new(
    projection,
    [
      @health.KnownLandmark::new("a", { x: 0.0, y: 0.0, }),
      @health.KnownLandmark::new("b", { x: 1.0, y: 0.0, }),
      @health.KnownLandmark::new("c", { x: 0.0, y: 1.0, }),
    ],
    config,
    camera?,
  )
}

///|
fn landmarks(
  shift~ : Double = 0.0,
) -> Array[@health.LandmarkObservation] raise @types.GroundError {
  let covariance = @types.Covariance2::isotropic(0.01)
  [
    @health.LandmarkObservation::new("a", { x: shift, y: 0.0, }, covariance),
    @health.LandmarkObservation::new(
      "b",
      { x: 1.0 + shift, y: 0.0, },
      covariance,
    ),
    @health.LandmarkObservation::new("c", { x: shift, y: 1.0, }, covariance),
  ]
}

///|
fn pixel(
  id : Int32,
  y : Double,
  x~ : Double = 0.0,
) -> @moonground.PixelObservation raise @types.GroundError {
  @moonground.PixelObservation::new(
    id,
    { x, y, },
    @types.Covariance2::isotropic(0.01),
  )
}

///|
fn fresh() -> @guarded.GuardedSession raise @types.GroundError {
  @guarded.GuardedSession::new(analysis(), monitor())
}

///|
fn pixel_checkpoint(
  checkpoint : @guarded.GuardedCheckpoint,
) -> @moonground.MeasurementCheckpoint raise {
  guard checkpoint.analysis.measurement is @analysis.Pixel(pixel) else {
    fail("pixel checkpoint missing")
  }
  pixel
}

///|
test "only current confirmed health allows objects and blocked payload identities are explicit" {
  let session = fresh()
  let first = session.update(0L, landmarks(), [pixel(3, -1.0), pixel(1, -1.0)])
  assert_eq(first.decision, @guarded.Blocked)
  assert_eq(first.suppressed_track_ids, [1, 3])
  assert_eq(first.analysis.measurement.motion.tracks.length(), 0)
  assert_eq(pixel_checkpoint(session.checkpoint()).motion.next_segment_id, 1L)
  let allowed = session.update(100000L, landmarks(), [pixel(1, -1.0)])
  assert_eq(allowed.decision, @guarded.Allowed)
  assert_eq(allowed.health.status, @health.Healthy)
  assert_eq(allowed.suppressed_track_ids, [])
  assert_eq(allowed.analysis.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(allowed.analysis.measurement.motion.tracks[0].accepted_count, 1)
}

///|
test "blocking closes paths and gate anchors while totals and segment allocation continue" {
  let session = fresh()
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0)]))
  let crossed = session.update(200000L, landmarks(), [pixel(1, 1.0)])
  assert_eq(crossed.analysis.counting.counts[0].negative_to_positive, 1L)
  let blocked = session.update(250000L, landmarks(shift=0.5), [pixel(1, -1.0)])
  assert_eq(blocked.health.status, @health.Pending)
  assert_eq(blocked.decision, @guarded.Blocked)
  assert_eq(blocked.analysis.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(blocked.analysis.counting.crossings.length(), 0)
  let saved = session.checkpoint()
  assert_eq(pixel_checkpoint(saved).motion.next_segment_id, 2L)
  assert_eq(pixel_checkpoint(saved).motion.tracks.length(), 0)
  assert_eq(saved.analysis.counting.tracks.length(), 0)
  assert_eq(blocked.analysis.counting.counts[0].negative_to_positive, 1L)
  assert_eq(
    session.update(300000L, landmarks(), [pixel(1, -1.0)]).decision,
    @guarded.Blocked,
  )
  let resumed = session.update(400000L, landmarks(), [pixel(1, 1.0)])
  assert_eq(resumed.decision, @guarded.Allowed)
  assert_eq(resumed.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(resumed.analysis.measurement.motion.tracks[0].accepted_count, 1)
  assert_eq(
    resumed.analysis.measurement.motion.tracks[0].observed_path_length_m,
    0.0,
  )
  assert_eq(resumed.analysis.counting.crossings.length(), 0)
  assert_eq(
    session.update(500000L, landmarks(), [pixel(1, -1.0)]).analysis.counting.counts[0].positive_to_negative,
    1L,
  )
}

///|
test "blocked pixels are structurally validated without projection through the blocked calibration" {
  let session = fresh()
  let bad_covariance : @moonground.PixelObservation = {
    track_id: 1,
    position: { x: 0.0, y: 0.0, },
    covariance: { xx: 1.0, xy: 2.0, yy: 1.0, },
  }
  for
    observations in [
      [bad_covariance],
      [pixel(1, 0.0, x=100.0), pixel(1, 0.0, x=101.0)],
    ] {
    invalid(() => ignore(session.update(0L, landmarks(), observations)))
    assert_eq(session.checkpoint().health.last_timestamp_us, None)
  }
  invalid(() => {
    ignore(session.update(0L, landmarks(), [pixel(1, 0.0)], lost=[1]))
  })
  invalid(() => {
    ignore(session.update(0L, landmarks(), [], lost=[2], removed=[2]))
  })
  invalid(() => ignore(session.update(0L, landmarks(), [], removed=[0])))
  let blocked = session.update(0L, landmarks(), [pixel(1, 0.0, x=100.0)])
  assert_eq(blocked.decision, @guarded.Blocked)
  assert_eq(blocked.analysis.measurement.projection_failures.length(), 0)
  assert_eq(blocked.suppressed_track_ids, [1])
  let allowed = session.update(100000L, landmarks(), [pixel(1, 0.0, x=100.0)])
  assert_eq(allowed.decision, @guarded.Allowed)
  assert_eq(allowed.analysis.measurement.projection_failures[0].track_id, 1)
}

///|
test "object capacity errors cannot be hidden by blocked health" {
  let session = @guarded.GuardedSession::new(
    analysis(max_tracks=1, gate_tracks=1),
    monitor(),
  )
  invalid(() => ignore(session.update(0L, [], [pixel(1, -1.0), pixel(2, -1.0)])))
  invalid(() => ignore(session.update(0L, [], [], lost=[1, 2])))
  assert_eq(session.checkpoint().health.last_timestamp_us, None)
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0)]))
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.update(200000L, landmarks(), [pixel(2, 1.0)])))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(
    session.update(200000L, landmarks(), [pixel(1, -1.0)]).analysis.measurement.motion.tracks[0].accepted_count,
    2,
  )
}

///|
test "health validation failures preserve the allowed object state and joint watermark" {
  let session = fresh()
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0)]))
  let before = @debug.to_string(session.checkpoint())
  let invalid_landmark = @health.LandmarkObservation::new(
    "unknown",
    { x: 0.0, y: 0.0, },
    @types.Covariance2::isotropic(0.01),
  )
  invalid(() => {
    ignore(session.update(200000L, [invalid_landmark], [pixel(1, 1.0)]))
  })
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(
    session.update(200000L, landmarks(), [pixel(1, 1.0)]).analysis.counting.counts[0].negative_to_positive,
    1L,
  )
}

///|
test "a gate counter failure rolls back both landmark time and complete object candidates" {
  let initial = fresh()
  ignore(initial.update(0L, landmarks(), []))
  ignore(initial.update(100000L, landmarks(), [pixel(1, -1.0)]))
  let checkpoint = initial.checkpoint()
  checkpoint.analysis.counting.counts[0] = {
    ..checkpoint.analysis.counting.counts[0],
    negative_to_positive: 9223372036854775807L,
  }
  let session = @guarded.GuardedSession::from_checkpoint(checkpoint)
  let before = @debug.to_string(session.checkpoint())
  invalid(() => {
    ignore(
      session.update(200000L, landmarks(), [pixel(1, 1.0), pixel(2, -1.0)]),
    )
  })
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let retry = session.update(200000L, landmarks(), [
    pixel(1, -1.0),
    pixel(2, -1.0),
  ])
  assert_eq(retry.analysis.measurement.motion.tracks[1].segment_id, "2")
  assert_eq(session.checkpoint().health.last_timestamp_us, Some(200000L))
}

///|
test "missing landmarks drift and a long evidence gap all block immediately" {
  for kind in 0..<3 {
    let session = fresh()
    ignore(session.update(0L, landmarks(), []))
    ignore(session.update(100000L, landmarks(), [pixel(1, -1.0)]))
    let timestamp = if kind == 2 { 600000L } else { 200000L }
    let current = if kind == 0 {
      []
    } else if kind == 1 {
      landmarks(shift=0.5)
    } else {
      landmarks()
    }
    let frame = session.update(timestamp, current, [pixel(1, 1.0)])
    assert_eq(frame.decision, @guarded.Blocked)
    assert_eq(frame.analysis.measurement.motion.closed_segment_ids, ["1"])
    assert_eq(frame.analysis.measurement.motion.tracks.length(), 0)
    assert_eq(frame.analysis.counting.crossings.length(), 0)
  }
}

///|
test "construction requires pixel mode matching watermark capacity and full projection policy" {
  invalid(() => {
    ignore(
      @guarded.GuardedSession::new(
        analysis(max_tracks=2, gate_tracks=1),
        monitor(),
      ),
    )
  })
  let ground = @analysis.AnalysisSession::from_ground(
    @moonground.MotionEstimator::new(
      "guarded",
      @moonground.MotionConfig::new(max_tracks=10),
    ),
    @events.GateCounter::new(
      "guarded",
      [@events.LineGate::new("door", { x: -5.0, y: 0.0, }, { x: 5.0, y: 0.0, })],
      @events.GateConfig::new(max_tracks=10),
    ),
  )
  invalid(() => ignore(@guarded.GuardedSession::new(ground, monitor())))
  let health = monitor()
  ignore(health.update(0L, landmarks()))
  invalid(() => ignore(@guarded.GuardedSession::new(analysis(), health)))
  let altered = @moonground.GroundCalibration::from_homography(
    [1.0, 0.0, 0.01, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    calibration().roi(),
    max_meters_per_pixel=2.0,
  )
  invalid(() => {
    ignore(
      @guarded.GuardedSession::new(analysis(projection=altered), monitor()),
    )
  })
  let noise = @moonground.GroundCalibration::from_homography(
    calibration().matrix(),
    calibration().roi(),
    max_meters_per_pixel=2.0,
    ground_noise_floor_m=0.002,
  )
  invalid(() => {
    ignore(@guarded.GuardedSession::new(analysis(projection=noise), monitor()))
  })
  let zero_camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
  )
  invalid(() => {
    ignore(
      @guarded.GuardedSession::new(analysis(camera=zero_camera), monitor()),
    )
  })
  let different_camera = @moonground.CameraModel::new(
    fx=31.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
  )
  invalid(() => {
    ignore(
      @guarded.GuardedSession::new(
        analysis(camera=zero_camera),
        monitor(camera=different_camera),
      ),
    )
  })
}

///|
test "nonhealthy combinations cannot import active paths and healthy paths cannot predate confirmation" {
  let objects = analysis()
  let health = monitor()
  ignore(objects.update_pixel(0L, [pixel(1, -1.0)]))
  ignore(health.update(0L, landmarks()))
  invalid(() => ignore(@guarded.GuardedSession::new(objects, health)))
  ignore(objects.update_pixel(100000L, []))
  ignore(health.update(100000L, landmarks()))
  assert_eq(health.status(), @health.Healthy)
  invalid(() => ignore(@guarded.GuardedSession::new(objects, health)))
  let sampled = analysis()
  let fast = monitor(
    config=@health.HealthConfig::new(confirmation_us=0L, min_observations=2),
  )
  ignore(sampled.update_pixel(0L, [pixel(1, -1.0)]))
  ignore(sampled.update_pixel(1L, []))
  ignore(fast.update(0L, landmarks()))
  ignore(fast.update(1L, landmarks()))
  invalid(() => ignore(@guarded.GuardedSession::new(sampled, fast)))
}

///|
test "guarded checkpoints resume every policy boundary with identical frames and final state" {
  let times = [
    0L, 100000L, 200000L, 250000L, 300000L, 400000L, 500000L, 600000L, 700000L, 800000L,
    1300000L,
  ]
  let health_frames = Array::makei(times.length(), i => {
    if i == 3 {
      landmarks(shift=0.5)
    } else if i == 7 {
      []
    } else {
      landmarks()
    }
  })
  let object_frames = Array::makei(times.length(), i => {
    if i == 6 {
      []
    } else {
      [pixel(1, if i % 2 == 0 { -1.0 } else { 1.0 })]
    }
  })
  let full = fresh()
  let expected = Array::makei(times.length(), i => {
    @debug.to_string(
      full.update(
        times[i],
        health_frames[i],
        object_frames[i],
        removed=if i == 6 { [1] } else { [] },
      ),
    )
  })
  let final_checkpoint = @debug.to_string(full.checkpoint())
  for cut in 0..<=times.length() {
    let prefix = fresh()
    for i in 0..<cut {
      ignore(
        prefix.update(
          times[i],
          health_frames[i],
          object_frames[i],
          removed=if i == 6 { [1] } else { [] },
        ),
      )
    }
    let resumed = @guarded.GuardedSession::from_checkpoint(prefix.checkpoint())
    for i in cut..<times.length() {
      assert_eq(
        @debug.to_string(
          resumed.update(
            times[i],
            health_frames[i],
            object_frames[i],
            removed=if i == 6 { [1] } else { [] },
          ),
        ),
        expected[i],
      )
    }
    assert_eq(@debug.to_string(resumed.checkpoint()), final_checkpoint)
  }
}

///|
test "restoration rejects a valid legacy pair that retains an object while blocked" {
  let session = fresh()
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0)]))
  let warm = session.checkpoint()
  ignore(session.update(200000L, [], [pixel(1, 1.0)]))
  let blocked = session.checkpoint()
  let legacy = @analysis.AnalysisSession::from_checkpoint(warm.analysis)
  ignore(legacy.update_pixel(200000L, []))
  invalid(() => {
    ignore(
      @guarded.GuardedSession::from_checkpoint({
        ..blocked,
        analysis: legacy.checkpoint(),
      }),
    )
  })
  invalid(() => {
    ignore(@guarded.GuardedSession::from_checkpoint({ ..blocked, version: 2, }))
  })
  invalid(() => {
    ignore(
      @guarded.GuardedSession::from_checkpoint({
        ..blocked,
        health: warm.health,
      }),
    )
  })
}

///|
test "constructor fork checkpoint and returned arrays are independent" {
  let objects = analysis()
  let health = monitor()
  let session = @guarded.GuardedSession::new(objects, health)
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0)]))
  let snapshot = session.checkpoint()
  let resumed = @guarded.GuardedSession::from_checkpoint(snapshot)
  let branch = session.fork()
  let before = @debug.to_string(session.checkpoint())
  snapshot.health.landmarks.clear()
  pixel_checkpoint(snapshot).motion.tracks[0].state[0] = 999.0
  snapshot.analysis.counting.tracks[0].anchors[0] = None
  ignore(objects.update_pixel(0L, [pixel(9, 1.0)]))
  ignore(health.update(0L, []))
  let blocked = branch.update(200000L, [], [pixel(2, 1.0)])
  blocked.suppressed_track_ids.clear()
  blocked.health.landmarks.clear()
  blocked.analysis.measurement.motion.closed_segment_ids.clear()
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(@debug.to_string(resumed.checkpoint()), before)
  let original = session.update(200000L, landmarks(), [pixel(1, 1.0)])
  assert_eq(
    @debug.to_string(resumed.update(200000L, landmarks(), [pixel(1, 1.0)])),
    @debug.to_string(original),
  )
}

///|
test "first-frame permission and all policy timestamps remain exact near Int64 maximum" {
  let session = @guarded.GuardedSession::new(
    analysis(),
    monitor(
      config=@health.HealthConfig::new(confirmation_us=0L, min_observations=1),
    ),
  )
  let end = 9223372036854775807L
  assert_eq(
    session.update(end - 2L, landmarks(), [pixel(1, -1.0)]).decision,
    @guarded.Allowed,
  )
  assert_eq(
    session.update(end - 1L, [], [pixel(1, 1.0)]).decision,
    @guarded.Blocked,
  )
  let final_frame = session.update(end, landmarks(), [pixel(1, 1.0)])
  assert_eq(final_frame.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(final_frame.health.timestamp_us, end)
  ignore(@guarded.GuardedSession::from_checkpoint(session.checkpoint()))
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.update(end, landmarks(), [])))
  assert_eq(@debug.to_string(session.checkpoint()), before)
}

///|
test "a single pixel transform preserves Brown health policy and metric counting through recovery" {
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let session = @guarded.GuardedSession::new(
    analysis(camera~),
    monitor(camera~),
  )
  let raw = (point : @types.Point2) => {
    let factor = 1.0 +
      0.02 *
      (point.x / 30.0 * (point.x / 30.0) + point.y / 40.0 * (point.y / 40.0))
    @types.Point2::{ x: point.x * factor, y: point.y * factor, }
  }
  let refs = landmarks().map(item => {
    @health.LandmarkObservation::new(
      item.landmark_id,
      raw(item.pixel),
      item.covariance,
    )
  })
  let object = (y : Double) => {
    let observation = pixel(1, y)
    @moonground.PixelObservation::new(
      1,
      raw(observation.position),
      observation.covariance,
    )
  }
  ignore(session.update(0L, refs, [object(-1.0)]))
  ignore(session.update(100000L, refs, [object(-1.0)]))
  let transform = @types.PixelTransform::new(
    scale_x=0.5,
    scale_y=0.75,
    offset_x=-40.0,
    offset_y=16.0,
  )
  let adapted = session.reframed(transform)
  let restored = @guarded.GuardedSession::from_checkpoint(adapted.checkpoint())
  for i in 2..<7 {
    let time = i.to_int64() * 100000L
    let landmark_frame = if i == 3 { [] } else { refs }
    let observations = [object(if i % 2 == 0 { 1.0 } else { -1.0 })]
    let actual_refs = landmark_frame.map(item => item.reframed(transform))
    let actual_observations = observations.map(item => item.reframed(transform))
    let expected = session.update(time, landmark_frame, observations)
    let actual = adapted.update(time, actual_refs, actual_observations)
    assert_eq(
      @debug.to_string(restored.update(time, actual_refs, actual_observations)),
      @debug.to_string(actual),
    )
    assert_eq(actual.decision, expected.decision)
    assert_eq(actual.health.status, expected.health.status)
    assert_eq(
      actual.analysis.measurement.motion.closed_segment_ids,
      expected.analysis.measurement.motion.closed_segment_ids,
    )
    assert_eq(
      actual.analysis.counting.counts[0].negative_to_positive,
      expected.analysis.counting.counts[0].negative_to_positive,
    )
    assert_eq(
      actual.analysis.counting.counts[0].positive_to_negative,
      expected.analysis.counting.counts[0].positive_to_negative,
    )
    assert_eq(
      actual.analysis.measurement.motion.tracks.length(),
      expected.analysis.measurement.motion.tracks.length(),
    )
    for index, track in actual.analysis.measurement.motion.tracks {
      let before = expected.analysis.measurement.motion.tracks[index]
      assert_eq(track.segment_id, before.segment_id)
      assert_eq(track.accepted_count, before.accepted_count)
      guard (track.filtered_state, before.filtered_state) is (Some(a), Some(b)) else {
        fail("filter state missing")
      }
      for coordinate in 0..<4 {
        assert_true((a[coordinate] - b[coordinate]).abs() < 1.0e-8)
      }
    }
  }
}
