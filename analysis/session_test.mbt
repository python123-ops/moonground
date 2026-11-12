///|
fn invalid(action : () -> Unit raise @types.GroundError) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid analysis operation was accepted")
  }
}

///|
fn config(
  max_tracks~ : Int32 = 10,
) -> @motion.MotionConfig raise @types.GroundError {
  @motion.MotionConfig::new(max_tracks~, gate=1.0e12)
}

///|
fn counter(
  session_id~ : String = "analysis",
  max_tracks~ : Int32 = 10,
  limit? : Double,
  gates? : Array[@events.LineGate],
) -> @events.GateCounter raise @types.GroundError {
  let gates = match gates {
    Some(gates) => gates
    None =>
      [
        @events.LineGate::new(
          "entry",
          { x: -5.0, y: 0.0, },
          { x: 5.0, y: 0.0, },
          deadband_m=0.1,
        ),
      ]
  }
  @events.GateCounter::new(
    session_id,
    gates,
    @events.GateConfig::new(max_tracks~, max_position_std_m?=limit),
  )
}

///|
fn pixel_session(
  camera? : @moonground.CameraModel,
) -> @moonground.MeasurementSession raise @types.GroundError {
  @moonground.MeasurementSession::new(
    "analysis",
    @moonground.GroundCalibration::from_homography(
      [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      [
        { x: -10.0, y: -10.0, },
        { x: 10.0, y: -10.0, },
        { x: 10.0, y: 10.0, },
        { x: -10.0, y: 10.0, },
      ],
      max_meters_per_pixel=2.0,
    ),
    config(),
    camera?,
  )
}

///|
fn pixel(
  x : Double,
  y : Double,
  id~ : Int32 = 1,
) -> @moonground.PixelObservation raise @types.GroundError {
  @moonground.PixelObservation::new(
    id,
    { x, y, },
    @types.Covariance2::isotropic(0.01),
  )
}

///|
fn ground(
  x : Double,
  y : Double,
  id~ : Int32 = 1,
  std~ : Double = 0.01,
) -> @types.GroundObservation raise @types.GroundError {
  @types.GroundObservation::new(
    id,
    { x, y, },
    @types.Covariance2::isotropic(std),
  )
}

///|
fn fresh_ground(
  max_tracks~ : Int32 = 10,
  counter_tracks~ : Int32 = 10,
) -> @analysis.AnalysisSession raise @types.GroundError {
  @analysis.AnalysisSession::from_ground(
    @motion.MotionEstimator::new("analysis", config(max_tracks~)),
    counter(max_tracks=counter_tracks),
  )
}

///|
fn motion_checkpoint(
  checkpoint : @analysis.AnalysisCheckpoint,
) -> @motion.MotionCheckpoint {
  match checkpoint.measurement {
    @analysis.Pixel(value) => value.motion
    @analysis.Ground(value) => value
  }
}

///|
test "analysis pixel frames equal separately measured and counted frames" {
  let measurement = pixel_session()
  let counting = counter()
  let combined = @analysis.AnalysisSession::from_pixel(measurement, counting)
  let observations = [
    [pixel(0.0, -1.0)],
    [pixel(0.0, 0.0)],
    [pixel(0.0, 1.0), pixel(100.0, 0.0, id=2)],
    [],
    [pixel(0.0, -1.0)],
  ]
  for index, observations in observations {
    let timestamp = index.to_int64() * 100000L
    let frame = measurement.update(timestamp, observations)
    let events = counting.update(frame.motion)
    let actual = combined.update_pixel(timestamp, observations)
    assert_eq(@debug.to_string(actual.measurement), @debug.to_string(frame))
    assert_eq(@debug.to_string(actual.counting), @debug.to_string(events))
  }
  assert_eq(
    @debug.to_string(combined.checkpoint().counting),
    @debug.to_string(counting.checkpoint()),
  )
}

///|
test "analysis resumes every metric missing lost removed and gap boundary" {
  let observations = [
    [ground(0.0, -1.0)],
    [ground(0.0, 0.0)],
    [ground(0.0, 1.0)],
    [],
    [ground(0.0, -1.0)],
    [],
    [ground(0.0, 1.0)],
    [],
    [ground(0.0, -1.0)],
    [ground(0.0, 1.0)],
  ]
  let times = [
    0L, 100000L, 200000L, 300000L, 400000L, 500000L, 600000L, 700000L, 800000L, 1300000L,
  ]
  let full = fresh_ground()
  let expected : Array[String] = []
  for index, observation in observations {
    expected.push(
      @debug.to_string(
        full.update_ground(
          times[index],
          observation,
          lost=if index == 5 { [1] } else { [] },
          removed=if index == 7 { [1] } else { [] },
        ),
      ),
    )
  }
  let final_checkpoint = @debug.to_string(full.checkpoint())
  for cut in 0..<=observations.length() {
    let prefix = fresh_ground()
    for index in 0..<cut {
      ignore(
        prefix.update_ground(
          times[index],
          observations[index],
          lost=if index == 5 { [1] } else { [] },
          removed=if index == 7 { [1] } else { [] },
        ),
      )
    }
    let resumed = @analysis.AnalysisSession::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<observations.length() {
      assert_eq(
        @debug.to_string(
          resumed.update_ground(
            times[index],
            observations[index],
            lost=if index == 5 { [1] } else { [] },
            removed=if index == 7 { [1] } else { [] },
          ),
        ),
        expected[index],
      )
    }
    assert_eq(@debug.to_string(resumed.checkpoint()), final_checkpoint)
  }
}

///|
test "counter exhaustion rolls back accepted motion path covariance and watermark" {
  let session = fresh_ground()
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  let checkpoint = session.checkpoint()
  let exhausted = @analysis.AnalysisSession::from_checkpoint({
    ..checkpoint,
    counting: {
      ..checkpoint.counting,
      counts: [
        {
          ..checkpoint.counting.counts[0],
          negative_to_positive: 9223372036854775807L,
        },
      ],
    },
  })
  let before = @debug.to_string(exhausted.checkpoint())
  invalid(() => ignore(exhausted.update_ground(100000L, [ground(0.0, 1.0)])))
  assert_eq(@debug.to_string(exhausted.checkpoint()), before)
  let retry = exhausted.update_ground(100000L, [ground(0.0, -2.0)])
  assert_eq(retry.measurement.motion.tracks[0].accepted_count, 2)
  assert_eq(retry.measurement.motion.tracks[0].segment_id, "1")
}

///|
test "counter geometry and capacity failures do not allocate motion segments" {
  let huge = @events.LineGate::new("huge", { x: -1.0e308, y: 0.0, }, {
    x: -9.0e307,
    y: 0.0,
  })
  let session = @analysis.AnalysisSession::from_ground(
    @motion.MotionEstimator::new("analysis", config()),
    counter(gates=[huge]),
  )
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.update_ground(0L, [ground(1.0e308, 1.0)])))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(
    session.update_ground(0L, [ground(0.0, 1.0)]).measurement.motion.tracks[0].segment_id,
    "1",
  )
  let bounded = fresh_ground(max_tracks=2, counter_tracks=1)
  let initial = @debug.to_string(bounded.checkpoint())
  invalid(() => {
    ignore(
      bounded.update_ground(0L, [ground(0.0, -1.0), ground(1.0, 1.0, id=2)]),
    )
  })
  assert_eq(@debug.to_string(bounded.checkpoint()), initial)
  assert_eq(
    bounded.update_ground(0L, [ground(1.0, 1.0, id=3)]).measurement.motion.tracks[0].segment_id,
    "1",
  )
}

///|
test "analysis rejects mode mismatch duplicate conflicting and nonincreasing frames atomically" {
  let ground_session = fresh_ground()
  let pixel_session = @analysis.AnalysisSession::from_pixel(
    pixel_session(),
    counter(),
  )
  invalid(() => ignore(ground_session.update_pixel(0L, [pixel(0.0, -1.0)])))
  invalid(() => ignore(pixel_session.update_ground(0L, [ground(0.0, -1.0)])))
  invalid(() => {
    ignore(
      ground_session.update_ground(0L, [ground(0.0, -1.0), ground(1.0, 1.0)]),
    )
  })
  invalid(() => {
    ignore(ground_session.update_ground(0L, [ground(0.0, -1.0)], lost=[1]))
  })
  ignore(ground_session.update_ground(0L, [ground(0.0, -1.0)]))
  let before = @debug.to_string(ground_session.checkpoint())
  invalid(() => ignore(ground_session.update_ground(0L, [])))
  invalid(() => ignore(ground_session.reframed(@types.PixelTransform::new())))
  assert_eq(@debug.to_string(ground_session.checkpoint()), before)
}

///|
test "analysis pair rejects mismatched sessions watermarks missing tracks and segments" {
  let session = fresh_ground()
  ignore(session.update_ground(100000L, [ground(0.0, -1.0)]))
  let checkpoint = session.checkpoint()
  let bad = [
    { ..checkpoint, version: 2, },
    { ..checkpoint, counting: { ..checkpoint.counting, session_id: "other", }, },
    {
      ..checkpoint,
      counting: { ..checkpoint.counting, last_timestamp_us: Some(100001L), },
    },
    { ..checkpoint, counting: { ..checkpoint.counting, tracks: [], }, },
    {
      ..checkpoint,
      counting: {
        ..checkpoint.counting,
        tracks: [{ ..checkpoint.counting.tracks[0], track_id: 2, }],
      },
    },
    {
      ..checkpoint,
      counting: {
        ..checkpoint.counting,
        tracks: [{ ..checkpoint.counting.tracks[0], segment_id: "2", }],
      },
    },
  ]
  for bad in bad {
    invalid(() => ignore(@analysis.AnalysisSession::from_checkpoint(bad)))
  }
  let measurement = @motion.MotionEstimator::new("analysis", config())
  ignore(measurement.update(100000L, [ground(0.0, -1.0)]))
  invalid(() => {
    ignore(@analysis.AnalysisSession::from_ground(measurement, counter()))
  })
}

///|
test "analysis pair rejects current changed old and presegment stable anchors" {
  let session = fresh_ground()
  ignore(session.update_ground(100000L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(200000L, [ground(0.0, -2.0)]))
  let checkpoint = session.checkpoint()
  let track = checkpoint.counting.tracks[0]
  let anchors : Array[@events.GateAnchor?] = [
    None,
    Some({ timestamp_us: 200000L, point_m: { x: 1.0, y: -2.0, }, }),
    Some({ timestamp_us: 100000L, point_m: { x: 0.0, y: -1.0, }, }),
    Some({ timestamp_us: 99999L, point_m: { x: 0.0, y: -1.0, }, }),
  ]
  for anchor in anchors {
    invalid(() => {
      ignore(
        @analysis.AnalysisSession::from_checkpoint({
          ..checkpoint,
          counting: {
            ..checkpoint.counting,
            tracks: [{ ..track, anchors: [anchor], }],
          },
        }),
      )
    })
  }
}

///|
test "analysis quality boundary admits exact deviation and excludes skipped tracks" {
  let measurement = @motion.MotionEstimator::new("analysis", config())
  let frame = measurement.update(0L, [
    @types.GroundObservation::new(
      1,
      { x: 0.0, y: -1.0, },
      @types.Covariance2::new(0.04, 0.009, 0.01),
    ),
  ])
  guard frame.tracks[0].position_std_m is Some(limit) else {
    fail("missing deviation")
  }
  let exact = counter(limit~)
  ignore(exact.update(frame))
  ignore(@analysis.AnalysisSession::from_ground(measurement, exact))
  let skipped = counter(limit=limit * 0.999999)
  ignore(skipped.update(frame))
  assert_eq(skipped.checkpoint().tracks.length(), 0)
  ignore(@analysis.AnalysisSession::from_ground(measurement, skipped))
  invalid(() => {
    ignore(
      @analysis.AnalysisSession::from_checkpoint({
        version: 1,
        measurement: Ground(measurement.checkpoint()),
        counting: { ..skipped.checkpoint(), tracks: exact.checkpoint().tracks, },
      }),
    )
  })
}

///|
test "rejected and numerical failure frames resume without preserving gate anchors" {
  let motion = @motion.MotionEstimator::new(
    "analysis",
    @motion.MotionConfig::new(gate=0.01),
  )
  let session = @analysis.AnalysisSession::from_ground(motion, counter())
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  let rejected = session.update_ground(100000L, [ground(0.0, 1000.0)])
  assert_eq(
    rejected.measurement.motion.tracks[0].status,
    @motion.RejectedInnovation,
  )
  assert_eq(session.checkpoint().counting.tracks.length(), 0)
  let resumed = @analysis.AnalysisSession::from_checkpoint(session.checkpoint())
  let failed = session.update_ground(200000L, [ground(1.0e308, 1.0e308)])
  assert_eq(
    failed.measurement.motion.tracks[0].status,
    @motion.NumericalFailure,
  )
  assert_eq(
    @debug.to_string(failed),
    @debug.to_string(resumed.update_ground(200000L, [ground(1.0e308, 1.0e308)])),
  )
  ignore(@analysis.AnalysisSession::from_checkpoint(session.checkpoint()))
}

///|
test "public motion measurement and counter forks preserve independent containers" {
  let measurement = pixel_session()
  let first = measurement.update(0L, [pixel(0.0, -1.0)])
  let counting = counter()
  ignore(counting.update(first.motion))
  let metric = measurement.estimator.fork()
  let pixel_branch = measurement.fork()
  let counter_branch = counting.fork()
  let before = @debug.to_string(measurement.checkpoint())
  let events_before = @debug.to_string(counting.checkpoint())
  metric.tracks.clear()
  assert_eq(@debug.to_string(measurement.checkpoint()), before)
  let next = pixel_branch.update(100000L, [pixel(0.0, 1.0)])
  let next_events = counter_branch.update(next.motion)
  assert_eq(@debug.to_string(measurement.checkpoint()), before)
  assert_eq(@debug.to_string(counting.checkpoint()), events_before)
  pixel_branch.estimator.tracks.clear()
  assert_eq(measurement.active_track_count(), 1)
  let independent = measurement.update(100000L, [pixel(0.0, 1.0)])
  assert_eq(@debug.to_string(independent), @debug.to_string(next))
  assert_eq(
    @debug.to_string(counting.update(independent.motion)),
    @debug.to_string(next_events),
  )
}

///|
test "analysis forks constructors and checkpoint arrays cannot mutate another branch" {
  let measurement = pixel_session()
  let counting = counter()
  let session = @analysis.AnalysisSession::from_pixel(measurement, counting)
  ignore(session.update_pixel(0L, [pixel(0.0, -1.0)]))
  let branch = session.fork()
  let checkpoint = session.checkpoint()
  let restored = @analysis.AnalysisSession::from_checkpoint(checkpoint)
  let before = @debug.to_string(session.checkpoint())
  checkpoint.counting.tracks[0].anchors[0] = None
  checkpoint.counting.counts.clear()
  match checkpoint.measurement {
    Pixel(value) => {
      value.motion.tracks[0].state[0] = 999.0
      value.motion.tracks.clear()
    }
    Ground(_) => fail("unexpected mode")
  }
  ignore(measurement.update(0L, [pixel(5.0, 5.0)]))
  ignore(counting.update(measurement.update(100000L, []).motion))
  ignore(branch.update_pixel(100000L, [pixel(0.0, 1.0)]))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(@debug.to_string(restored.checkpoint()), before)
  // Continue both independent original snapshots through the same crossing.
  let original = session.update_pixel(100000L, [pixel(0.0, 1.0)])
  let expected = restored.update_pixel(100000L, [pixel(0.0, 1.0)])
  assert_eq(@debug.to_string(original), @debug.to_string(expected))
  assert_eq(
    @debug.to_string(branch.checkpoint()),
    @debug.to_string(restored.checkpoint()),
  )
  expected.counting.counts.clear()
  expected.measurement.motion.tracks.clear()
  assert_eq(branch.checkpoint().counting.counts.length(), 1)
}

///|
test "warm pixel reframing retains metric gates anchors totals and resumed motion" {
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let session = @analysis.AnalysisSession::from_pixel(
    pixel_session(camera~),
    counter(),
  )
  ignore(session.update_pixel(0L, [pixel(0.0, -1.0)]))
  let transform = @types.PixelTransform::new(
    scale_x=2.0,
    scale_y=0.5,
    offset_x=4.0,
    offset_y=-2.0,
  )
  let adapted = session.reframed(transform)
  assert_eq(
    @debug.to_string(adapted.checkpoint().counting),
    @debug.to_string(session.checkpoint().counting),
  )
  assert_eq(
    @debug.to_string(motion_checkpoint(adapted.checkpoint())),
    @debug.to_string(motion_checkpoint(session.checkpoint())),
  )
  let restored = @analysis.AnalysisSession::from_checkpoint(
    adapted.checkpoint(),
  )
  for index in 1..<=4 {
    let observation = pixel(0.0, index.to_double() - 1.0)
    let timestamp = index.to_int64() * 100000L
    let expected = session.update_pixel(timestamp, [observation])
    let actual = adapted.update_pixel(timestamp, [
      observation.reframed(transform),
    ])
    let resumed = restored.update_pixel(timestamp, [
      observation.reframed(transform),
    ])
    assert_eq(@debug.to_string(actual), @debug.to_string(resumed))
    assert_eq(
      actual.counting.counts[0].negative_to_positive,
      expected.counting.counts[0].negative_to_positive,
    )
    let a = actual.measurement.motion.tracks[0]
    let b = expected.measurement.motion.tracks[0]
    assert_eq(a.segment_id, b.segment_id)
    assert_eq(a.accepted_count, b.accepted_count)
    guard (a.filtered_state, b.filtered_state) is (Some(a), Some(b)) else {
      fail("missing state")
    }
    for index in 0..<4 {
      assert_true((a[index] - b[index]).abs() < 1.0e-9)
    }
  }
}
