///|
fn guarded_transit_analysis(
  max_tracks~ : Int32 = 10,
  gate_tracks~ : Int32 = 10,
  camera? : @moonground.CameraModel,
  projection~ : @moonground.GroundCalibration = calibration(),
  multiplier~ : Double = 2.0,
) -> @analysis.EvidenceTransitSession raise @types.GroundError {
  @analysis.EvidenceTransitSession::from_pixel(
    @moonground.MeasurementSession::new(
      "guarded",
      projection,
      @moonground.MotionConfig::new(max_tracks~, q=1.0e6, gate=1.0e12),
      camera?,
    ),
    @transit.EvidenceTransitCounter::new(
      @events.EvidenceGateCounter::new(
        "guarded",
        [
          @events.LineGate::new(
            "entry",
            { x: -5.0, y: 0.0, },
            { x: 5.0, y: 0.0, },
            deadband_m=0.1,
          ),
          @events.LineGate::new(
            "exit",
            { x: -5.0, y: 2.0, },
            { x: 5.0, y: 2.0, },
            deadband_m=0.1,
          ),
        ],
        @events.GateConfig::new(max_tracks=gate_tracks),
        sigma_multiplier=multiplier,
      ),
      [
        @transit.Section::new(
          "aisle",
          "entry",
          @events.NegativeToPositive,
          "exit",
          @events.NegativeToPositive,
        ),
      ],
      max_duration_us=1000000L,
    ),
  )
}

///|
fn guarded_transit(
  config~ : @health.HealthConfig = @health.HealthConfig::new(
    confirmation_us=100000L,
    min_observations=2,
  ),
  camera? : @moonground.CameraModel,
  projection~ : @moonground.GroundCalibration = calibration(),
  multiplier~ : Double = 2.0,
) -> @guarded.EvidenceGuardedTransitSession raise @types.GroundError {
  @guarded.EvidenceGuardedTransitSession::new(
    guarded_transit_analysis(camera?, projection~, multiplier~),
    monitor(config~, camera?, projection~),
  )
}

///|
fn guarded_transit_immediate(
  multiplier~ : Double = 2.0,
) -> @guarded.EvidenceGuardedTransitSession raise @types.GroundError {
  guarded_transit(
    config=@health.HealthConfig::new(confirmation_us=0L, min_observations=1),
    multiplier~,
  )
}

///|
fn guarded_transit_pixel(
  checkpoint : @guarded.EvidenceGuardedTransitCheckpoint,
) -> @moonground.MeasurementCheckpoint raise {
  guard checkpoint.analysis.measurement is Pixel(pixel) else {
    fail("missing guarded transit pixel state")
  }
  pixel
}

///|
test "guarded transit frames equal independent health-gated measurement and evidence interval processing" {
  let base = guarded_transit_analysis().checkpoint()
  let legacy_guard = @guarded.EvidenceGuardedSession::new(
    @analysis.EvidenceAnalysisSession::from_checkpoint({
      version: 1,
      measurement: base.measurement,
      counting: base.transit.counting,
    }),
    monitor(),
  )
  let downstream = @transit.EvidenceTransitCounter::from_checkpoint(
    base.transit,
  )
  let combined = guarded_transit()
  for index, y in [-1.0, -1.0, 1.0, 3.0, 1.0, -1.0] {
    let time = index.to_int64() * 100000L
    let reference = legacy_guard.update(time, landmarks(), [pixel(1, y)])
    let actual = combined.update(time, landmarks(), [pixel(1, y)])
    assert_eq(actual.decision, reference.decision)
    assert_eq(
      @debug.to_string(actual.health),
      @debug.to_string(reference.health),
    )
    assert_eq(
      @debug.to_string(actual.analysis.measurement),
      @debug.to_string(reference.analysis.measurement),
    )
    assert_eq(
      @debug.to_string(actual.analysis.transit),
      @debug.to_string(downstream.update(reference.analysis.measurement.motion)),
    )
  }
  assert_eq(combined.checkpoint().analysis.transit.counts[0].completed, 1L)
}

///|
test "complete guarded transit checkpoints resume every health transition entry completion and suppression cut" {
  let positions = [-1.0, -1.0, 1.0, 3.0, -1.0, 1.0, 3.0, -1.0, 1.0, 3.0]
  let full = guarded_transit()
  let reports = [
    landmarks(),
    landmarks(),
    landmarks(),
    landmarks(),
    landmarks(shift=0.5),
    landmarks(shift=0.5),
    [],
    landmarks(),
    landmarks(),
    landmarks(),
  ]
  let expected : Array[String] = []
  for index, y in positions {
    expected.push(
      @debug.to_string(
        full.update(index.to_int64() * 100000L, reports[index], [pixel(1, y)]),
      ),
    )
  }
  let final_state = @debug.to_string(full.checkpoint())
  for cut in 0..<=positions.length() {
    let prefix = guarded_transit()
    for index in 0..<cut {
      ignore(
        prefix.update(index.to_int64() * 100000L, reports[index], [
          pixel(1, positions[index]),
        ]),
      )
    }
    let restored = @guarded.EvidenceGuardedTransitSession::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<positions.length() {
      assert_eq(
        @debug.to_string(
          restored.update(index.to_int64() * 100000L, reports[index], [
            pixel(1, positions[index]),
          ]),
        ),
        expected[index],
      )
    }
    assert_eq(@debug.to_string(restored.checkpoint()), final_state)
  }
}

///|
test "newly Healthy normal overflow rolls back landmark confirmation motion IDs and evidence transit state" {
  let session = guarded_transit(
    config=@health.HealthConfig::new(
      confirmation_us=200000L,
      min_observations=3,
    ),
    multiplier=1.0e308,
  )
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), []))
  let before = @debug.to_string(session.checkpoint())
  let overflow = @moonground.PixelObservation::new(
    1,
    { x: 0.0, y: -1.0, },
    @types.Covariance2::isotropic(10.0),
  )
  invalid(() => ignore(session.update(200000L, landmarks(), [overflow])))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(session.checkpoint().health.streak.unwrap().observations, 2)
  assert_eq(session.checkpoint().health.last_timestamp_us, Some(100000L))
  assert_eq(
    guarded_transit_pixel(session.checkpoint()).motion.next_segment_id,
    1L,
  )
  let retry = session.update(200000L, landmarks(), [pixel(1, -1.0)])
  assert_eq(retry.health.status, @health.Healthy)
  assert_eq(retry.health.streak_observations, 3)
  assert_eq(retry.analysis.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(retry.analysis.transit.counting.evidence[0].side, 0)
}

///|
test "exit gate exhaustion preserves pending entry and health time before corrected same-time object retry" {
  let original = guarded_transit_immediate()
  ignore(original.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(original.update(100000L, landmarks(), [pixel(1, 1.0)]))
  let saved = original.checkpoint()
  let gate = saved.analysis.transit.counting
  let session = @guarded.EvidenceGuardedTransitSession::from_checkpoint({
    ..saved,
    analysis: {
      ..saved.analysis,
      transit: {
        ..saved.analysis.transit,
        counting: {
          ..gate,
          counts: [
            gate.counts[0],
            { ..gate.counts[1], negative_to_positive: 9223372036854775807L, },
          ],
        },
      },
    },
  })
  let before = @debug.to_string(session.checkpoint())
  invalid(() => {
    ignore(
      session.update(200000L, landmarks(), [pixel(1, 3.0), pixel(2, -1.0)]),
    )
  })
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let retry = session.update(200000L, landmarks(), [
    pixel(1, 1.0),
    pixel(2, -1.0),
  ])
  assert_eq(retry.analysis.transit.pending_count, 1)
  assert_eq(retry.analysis.measurement.motion.tracks[1].segment_id, "2")
  assert_eq(session.checkpoint().health.last_timestamp_us, Some(200000L))
}

///|
test "blocked raw observations remain structural only even when projection and normal evidence would fail" {
  let session = guarded_transit(multiplier=1.0e308)
  let suppressed = @moonground.PixelObservation::new(
    3,
    { x: 100.0, y: 100.0, },
    @types.Covariance2::new(1.0, -0.9999999999999999, 1.0),
  )
  let frame = session.update(0L, landmarks(), [suppressed, pixel(1, 0.0)])
  assert_eq(frame.decision, @guarded.Blocked)
  assert_eq(frame.suppressed_track_ids, [1, 3])
  assert_eq(frame.analysis.measurement.projection_failures.length(), 0)
  assert_eq(frame.analysis.transit.counting.evidence.length(), 0)
  let before = @debug.to_string(session.checkpoint())
  for
    objects in [
      [
        @moonground.PixelObservation::{
          track_id: 1,
          position: { x: 0.0, y: 0.0, },
          covariance: { xx: 1.0, xy: 2.0, yy: 1.0, },
        },
      ],
      [pixel(1, 0.0), pixel(1, 1.0)],
      [
        @moonground.PixelObservation::{
          track_id: 1,
          position: { x: 1.0 / 0.0, y: 0.0, },
          covariance: @types.Covariance2::isotropic(0.1),
        },
      ],
    ] {
    invalid(() => ignore(session.update(1L, [], objects)))
  }
  invalid(() => ignore(session.update(1L, [], [], lost=[1], removed=[1])))
  invalid(() => ignore(session.update(1L, [], [pixel(1, 0.0)], lost=[1])))
  assert_eq(@debug.to_string(session.checkpoint()), before)
}

///|
test "first nonhealthy sample cancels real pending entries and closes hidden motion without waiting for confirmed drift" {
  let session = guarded_transit()
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0), pixel(2, -1.0)]))
  ignore(session.update(200000L, landmarks(), [pixel(1, 1.0), pixel(2, 1.0)]))
  ignore(session.update(225000L, landmarks(), [pixel(1, 1.0)]))
  let frame = session.update(250000L, landmarks(shift=0.5), [pixel(1, 3.0)])
  assert_eq(frame.health.status, @health.Pending)
  assert_eq(frame.decision, @guarded.Blocked)
  assert_eq(frame.analysis.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(frame.analysis.transit.cancellations.length(), 1)
  assert_eq(
    frame.analysis.transit.cancellations[0].reason,
    @transit.Discontinuity,
  )
  assert_eq(
    frame.analysis.transit.counting.counting.counts[0].negative_to_positive,
    2L,
  )
  assert_eq(frame.analysis.transit.pending_count, 0)
  ignore(session.update(300000L, landmarks(), [pixel(1, 3.0)]))
  let recovered = session.update(400000L, landmarks(), [pixel(1, 3.0)])
  assert_eq(recovered.analysis.measurement.motion.tracks[0].segment_id, "3")
  assert_eq(recovered.analysis.measurement.motion.tracks[0].accepted_count, 1)
  assert_eq(recovered.analysis.transit.passages.length(), 0)
}

///|
test "landmark identity covariance and time errors preserve all guarded transit stages" {
  let session = guarded_transit_immediate()
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  let before = @debug.to_string(session.checkpoint())
  for
    bad in [
      [
        @health.LandmarkObservation::new(
          "unknown",
          { x: 0.0, y: 0.0, },
          @types.Covariance2::isotropic(0.01),
        ),
      ],
      [landmarks()[0], landmarks()[0]],
      [
        @health.LandmarkObservation::{
          landmark_id: "a",
          pixel: { x: 0.0, y: 0.0, },
          covariance: { xx: 1.0, xy: 2.0, yy: 1.0, },
        },
      ],
    ] {
    invalid(() => ignore(session.update(100000L, bad, [pixel(1, 1.0)])))
  }
  invalid(() => ignore(session.update(0L, landmarks(), [pixel(1, 1.0)])))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(
    session.update(100000L, landmarks(), [pixel(1, 1.0)]).analysis.transit.pending_count,
    1,
  )
}

///|
test "guarded transit requires pixel mode exact projection camera watermark and sufficient interrupt capacity" {
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitSession::new(
        guarded_transit_analysis(max_tracks=2, gate_tracks=1),
        monitor(),
      ),
    )
  })
  let snapshot = guarded_transit_analysis().checkpoint()
  guard snapshot.measurement is Pixel(pixel_state) else {
    fail("missing pixel")
  }
  let metric = @analysis.EvidenceTransitSession::from_ground(
    @moonground.MotionEstimator::from_checkpoint(pixel_state.motion),
    @transit.EvidenceTransitCounter::from_checkpoint(snapshot.transit),
  )
  invalid(() => {
    ignore(@guarded.EvidenceGuardedTransitSession::new(metric, monitor()))
  })
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitSession::new(
        guarded_transit_analysis(),
        monitor(projection=replacement()),
      ),
    )
  })
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitSession::new(
        guarded_transit_analysis(),
        monitor(
          camera=@moonground.CameraModel::new(fx=30.0, fy=40.0, cx=0.0, cy=0.0),
        ),
      ),
    )
  })
  let health = monitor()
  ignore(health.update(0L, landmarks()))
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitSession::new(
        guarded_transit_analysis(),
        health,
      ),
    )
  })
}

///|
test "joint checkpoint rejects nonhealthy active or pending states and hidden segments before health confirmation" {
  let session = guarded_transit_immediate()
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0), pixel(2, -1.0)]))
  ignore(session.update(100000L, landmarks(), [pixel(1, 1.0)]))
  let saved = session.checkpoint()
  for
    health in [
      { ..saved.health, streak: None, },
      {
        ..saved.health,
        streak: Some({
          ..saved.health.streak.unwrap(),
          evidence: @health.BeyondTolerance,
        }),
      },
      {
        ..saved.health,
        streak: Some({ ..saved.health.streak.unwrap(), since_us: 100000L, }),
      },
    ] {
    ignore(@health.CalibrationMonitor::from_checkpoint(health))
    invalid(() => {
      ignore(
        @guarded.EvidenceGuardedTransitSession::from_checkpoint({
          ..saved,
          health,
        }),
      )
    })
  }
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitSession::from_checkpoint({
        ..saved,
        version: 2,
      }),
    )
  })
}

///|
test "guarded transit restore inherits sparse historical witness covariance consistency" {
  let session = guarded_transit_immediate()
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(session.update(100000L, landmarks(), [pixel(1, 1.0)]))
  let saved = session.checkpoint()
  let pixel_state = guarded_transit_pixel(saved)
  let motion = pixel_state.motion
  let changed = {
    ..motion,
    tracks: [{ ..motion.tracks[0], first_timestamp_us: 1L, }],
  }
  ignore(@moonground.MotionEstimator::from_checkpoint(changed))
  ignore(
    @transit.EvidenceTransitCounter::from_checkpoint(saved.analysis.transit),
  )
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitSession::from_checkpoint({
        ..saved,
        analysis: {
          ..saved.analysis,
          measurement: Pixel({ ..pixel_state, motion: changed, }),
        },
      }),
    )
  })
}

///|
test "warm Brown reframing preserves health streak pending witnesses and exact transformed checkpoint continuation" {
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let original = guarded_transit(camera~)
  ignore(original.update(0L, landmarks(), []))
  ignore(original.update(100000L, landmarks(), [pixel(1, -1.0)]))
  ignore(original.update(200000L, landmarks(), [pixel(1, 1.0)]))
  let before = original.checkpoint()
  let transform = @types.PixelTransform::new(
    scale_x=2.0,
    scale_y=0.5,
    offset_x=4.0,
    offset_y=-2.0,
  )
  let adapted = original.reframed(transform)
  assert_eq(
    @debug.to_string(adapted.checkpoint().analysis.transit),
    @debug.to_string(before.analysis.transit),
  )
  assert_eq(
    @debug.to_string(adapted.checkpoint().health.streak),
    @debug.to_string(before.health.streak),
  )
  assert_eq(
    @debug.to_string(guarded_transit_pixel(adapted.checkpoint()).motion),
    @debug.to_string(guarded_transit_pixel(before).motion),
  )
  let restored = @guarded.EvidenceGuardedTransitSession::from_checkpoint(
    adapted.checkpoint(),
  )
  for index, y in [3.0, 1.0, -1.0, 1.0, 3.0] {
    let time = (index + 3).to_int64() * 100000L
    let refs = landmarks().map(item => item.reframed(transform))
    let observation = pixel(1, y).reframed(transform)
    let actual = adapted.update(time, refs, [observation])
    let expected = original.update(time, landmarks(), [pixel(1, y)])
    assert_eq(
      @debug.to_string(actual),
      @debug.to_string(restored.update(time, refs, [observation])),
    )
    assert_eq(
      actual.analysis.transit.counts[0].completed,
      expected.analysis.transit.counts[0].completed,
    )
    let a = actual.analysis.measurement.motion.tracks[0].filtered_state.unwrap()
    let b = expected.analysis.measurement.motion.tracks[0].filtered_state.unwrap()
    for i in 0..<4 {
      assert_true((a[i] - b[i]).abs() < 1.0e-9)
    }
  }
}

///|
test "projection replacement barrier cancels pending entries closes hidden filters and preserves all historical totals and policies" {
  let session = guarded_transit_immediate(multiplier=3.0)
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(session.update(100000L, landmarks(), [pixel(1, 1.0)]))
  ignore(session.update(200000L, landmarks(), [pixel(1, 3.0)]))
  ignore(session.update(300000L, landmarks(), [pixel(1, -1.0), pixel(2, -1.0)]))
  ignore(session.update(400000L, landmarks(), [pixel(1, 1.0)]))
  let saved = session.checkpoint()
  let frame = session.replace_projection(450000L, replacement(), camera=None)
  assert_eq(frame.decision, @guarded.Blocked)
  assert_eq(frame.health.status, @health.Insufficient)
  assert_eq(frame.suppressed_track_ids, [])
  assert_eq(frame.analysis.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(
    frame.analysis.transit.cancellations[0].reason,
    @transit.Discontinuity,
  )
  let cp = session.checkpoint()
  assert_eq(cp.analysis.transit.pending.length(), 0)
  assert_eq(cp.analysis.transit.counting.sigma_multiplier, 3.0)
  assert_eq(
    @debug.to_string(cp.analysis.transit.counting.counts),
    @debug.to_string(saved.analysis.transit.counting.counts),
  )
  assert_eq(
    @debug.to_string(cp.analysis.transit.counts),
    @debug.to_string(saved.analysis.transit.counts),
  )
  assert_eq(
    @debug.to_string(cp.analysis.transit.sections),
    @debug.to_string(saved.analysis.transit.sections),
  )
  assert_eq(
    cp.analysis.transit.max_duration_us,
    saved.analysis.transit.max_duration_us,
  )
  assert_eq(guarded_transit_pixel(cp).motion.next_segment_id, 3L)
  assert_true(cp.health.streak is None)
  assert_eq(
    @debug.to_string(cp.health.landmarks),
    @debug.to_string(saved.health.landmarks),
  )
  assert_eq(
    @debug.to_string(cp.health.config),
    @debug.to_string(saved.health.config),
  )
  let resumed = @guarded.EvidenceGuardedTransitSession::from_checkpoint(cp)
  let next = resumed.update(500000L, scaled_landmarks(2.0), [pixel(1, 1.5)])
  assert_eq(next.analysis.measurement.motion.tracks[0].segment_id, "3")
  assert_eq(next.analysis.transit.passages.length(), 0)
}

///|
test "replacement starts a cold landmark confirmation period even for an equal projection" {
  let session = guarded_transit()
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0)]))
  ignore(session.update(200000L, landmarks(), [pixel(1, 1.0)]))
  let barrier = session.replace_projection(250000L, calibration(), camera=None)
  assert_eq(barrier.analysis.transit.pending_count, 0)
  let pending = session.update(300000L, landmarks(), [pixel(1, 3.0)])
  assert_eq(pending.health.status, @health.Pending)
  assert_eq(pending.decision, @guarded.Blocked)
  let allowed = session.update(400000L, landmarks(), [pixel(1, 3.0)])
  assert_eq(allowed.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(allowed.analysis.transit.passages.length(), 0)
}

///|
test "replacement can install and remove Brown calibration while original landmark truths and full checkpoints continue" {
  let session = guarded_transit()
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0)]))
  ignore(
    session.replace_projection(
      200000L,
      brown_calibration(),
      camera=Some(brown_model()),
    ),
  )
  ignore(session.update(250000L, brown_landmarks(), []))
  assert_eq(
    session.update(350000L, brown_landmarks(), []).decision,
    @guarded.Allowed,
  )
  let restored = @guarded.EvidenceGuardedTransitSession::from_checkpoint(
    session.checkpoint(),
  )
  let barrier = restored.replace_projection(400000L, calibration(), camera=None)
  assert_eq(barrier.health.status, @health.Insufficient)
  assert_true(guarded_transit_pixel(restored.checkpoint()).camera is None)
  ignore(restored.update(450000L, landmarks(), []))
  assert_eq(
    restored.update(550000L, landmarks(), [pixel(1, -1.0)]).decision,
    @guarded.Allowed,
  )
}

///|
test "invalid replacement time and maximum timestamp exhaustion preserve the full original owner" {
  let session = guarded_transit_immediate()
  ignore(session.update(100L, landmarks(), [pixel(1, -1.0)]))
  let before = @debug.to_string(session.checkpoint())
  invalid(() => {
    ignore(session.replace_projection(100L, replacement(), camera=None))
  })
  invalid(() => {
    ignore(session.replace_projection(99L, replacement(), camera=None))
  })
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let fresh = guarded_transit_immediate()
  let initial = @debug.to_string(fresh.checkpoint())
  invalid(() => {
    ignore(fresh.replace_projection(-1L, calibration(), camera=None))
  })
  assert_eq(@debug.to_string(fresh.checkpoint()), initial)
  let at_end = guarded_transit_immediate()
  ignore(at_end.update(9223372036854775806L, landmarks(), [pixel(1, -1.0)]))
  let barrier = at_end.replace_projection(
    9223372036854775807L,
    calibration(),
    camera=None,
  )
  assert_eq(barrier.analysis.measurement.motion.closed_segment_ids, ["1"])
  let saved = @debug.to_string(at_end.checkpoint())
  invalid(() => ignore(at_end.update(9223372036854775807L, landmarks(), [])))
  invalid(() => {
    ignore(
      at_end.replace_projection(
        9223372036854775807L,
        calibration(),
        camera=None,
      ),
    )
  })
  assert_eq(@debug.to_string(at_end.checkpoint()), saved)
}

///|
test "constructor exports and forks keep health motion pending arrays and original witnesses independent" {
  let analysis = guarded_transit_analysis()
  let health = monitor(
    config=@health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  let session = @guarded.EvidenceGuardedTransitSession::new(analysis, health)
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(session.update(100000L, landmarks(), [pixel(1, 1.0)]))
  let saved = session.checkpoint()
  let branch = session.fork()
  let restored = @guarded.EvidenceGuardedTransitSession::from_checkpoint(saved)
  let before = @debug.to_string(session.checkpoint())
  saved.analysis.transit.pending.clear()
  saved.analysis.transit.counting.tracks[0].anchors.clear()
  saved.analysis.transit.sections.clear()
  saved.health.landmarks.clear()
  guarded_transit_pixel(saved).motion.tracks[0].covariance[0] = 999.0
  ignore(analysis.update_pixel(0L, [pixel(3, -1.0)]))
  ignore(health.update(0L, []))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(@debug.to_string(restored.checkpoint()), before)
  let actual = branch.update(200000L, landmarks(), [pixel(1, 3.0)])
  let expected = restored.update(200000L, landmarks(), [pixel(1, 3.0)])
  assert_eq(@debug.to_string(actual), @debug.to_string(expected))
  actual.analysis.transit.passages.clear()
  actual.analysis.transit.counts.clear()
  actual.health.landmarks.clear()
  assert_eq(
    @debug.to_string(branch.checkpoint()),
    @debug.to_string(restored.checkpoint()),
  )
}
