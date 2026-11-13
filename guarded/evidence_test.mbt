///|
fn evidence_analysis(
  max_tracks~ : Int32 = 10,
  gate_tracks~ : Int32 = 10,
  camera? : @moonground.CameraModel,
  projection~ : @moonground.GroundCalibration = calibration(),
  multiplier~ : Double = 2.0,
) -> @analysis.EvidenceAnalysisSession raise @types.GroundError {
  let definition = analysis(max_tracks~, gate_tracks~, camera?, projection~).checkpoint()
  guard definition.measurement is Pixel(pixel) else {
    raise @types.InvalidInput("missing test pixel calibration")
  }
  @analysis.EvidenceAnalysisSession::from_pixel(
    @moonground.MeasurementSession::from_checkpoint(pixel),
    @events.EvidenceGateCounter::new(
      definition.counting.session_id,
      definition.counting.gates,
      definition.counting.config,
      sigma_multiplier=multiplier,
    ),
  )
}

///|
fn evidence_fresh(
  config~ : @health.HealthConfig = @health.HealthConfig::new(
    confirmation_us=100000L,
    min_observations=2,
  ),
  camera? : @moonground.CameraModel,
  projection~ : @moonground.GroundCalibration = calibration(),
  multiplier~ : Double = 2.0,
) -> @guarded.EvidenceGuardedSession raise @types.GroundError {
  @guarded.EvidenceGuardedSession::new(
    evidence_analysis(camera?, projection~, multiplier~),
    monitor(config~, camera?, projection~),
  )
}

///|
fn evidence_immediate(
  multiplier~ : Double = 2.0,
) -> @guarded.EvidenceGuardedSession raise @types.GroundError {
  evidence_fresh(
    config=@health.HealthConfig::new(confirmation_us=0L, min_observations=1),
    multiplier~,
  )
}

///|
fn evidence_pixel_checkpoint(
  checkpoint : @guarded.EvidenceGuardedCheckpoint,
) -> @moonground.MeasurementCheckpoint raise {
  guard checkpoint.analysis.measurement is Pixel(pixel) else {
    fail("pixel checkpoint missing")
  }
  pixel
}

///|
test "evidence guard permits only current confirmed health and reports sorted suppressed identities" {
  let session = evidence_fresh()
  let first = session.update(0L, landmarks(), [pixel(3, -1.0), pixel(1, -1.0)])
  assert_eq(first.decision, @guarded.Blocked)
  assert_eq(first.suppressed_track_ids, [1, 3])
  assert_eq(first.analysis.counting.evidence.length(), 0)
  assert_eq(
    evidence_pixel_checkpoint(session.checkpoint()).motion.next_segment_id,
    1L,
  )
  let next = session.update(100000L, landmarks(), [pixel(1, -1.0)])
  assert_eq(next.decision, @guarded.Allowed)
  assert_eq(next.health.status, @health.Healthy)
  assert_eq(next.suppressed_track_ids, [])
  assert_eq(next.analysis.counting.evidence[0].side, -1)
  assert_eq(next.analysis.measurement.motion.tracks[0].accepted_count, 1)
}

///|
test "pending beyond-tolerance evidence immediately closes hidden active filters and covariance anchors" {
  let session = evidence_fresh()
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0), pixel(2, -1.0)]))
  let crossed = session.update(200000L, landmarks(), [pixel(1, 1.0)])
  assert_eq(
    crossed.analysis.counting.counting.counts[0].negative_to_positive,
    1L,
  )
  let blocked = session.update(250000L, landmarks(shift=0.5), [pixel(1, -1.0)])
  assert_eq(blocked.health.status, @health.Pending)
  assert_eq(blocked.decision, @guarded.Blocked)
  assert_eq(blocked.analysis.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(blocked.analysis.counting.evidence.length(), 0)
  assert_eq(blocked.analysis.counting.counting.crossings.length(), 0)
  assert_eq(session.checkpoint().analysis.counting.tracks.length(), 0)
  assert_eq(
    evidence_pixel_checkpoint(session.checkpoint()).motion.next_segment_id,
    3L,
  )
  ignore(session.update(300000L, landmarks(), []))
  let allowed = session.update(400000L, landmarks(), [pixel(1, 1.0)])
  assert_eq(allowed.analysis.measurement.motion.tracks[0].segment_id, "3")
  assert_eq(
    allowed.analysis.measurement.motion.tracks[0].observed_path_length_m,
    0.0,
  )
  assert_eq(allowed.analysis.counting.counting.crossings.length(), 0)
  assert_eq(
    allowed.analysis.counting.counting.counts[0].negative_to_positive,
    1L,
  )
}

///|
test "missing landmarks confirmed drift and exact maximum evidence gaps all block" {
  let session = evidence_fresh()
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0)]))
  assert_eq(session.update(200000L, [], []).health.status, @health.Insufficient)
  assert_eq(
    session.update(300000L, landmarks(shift=0.5), []).health.status,
    @health.Pending,
  )
  assert_eq(
    session.update(400000L, landmarks(shift=0.5), [pixel(1, 1.0)]).health.status,
    @health.Drift,
  )
  ignore(session.update(500000L, landmarks(), []))
  assert_eq(session.update(600000L, landmarks(), []).decision, @guarded.Allowed)
  let gap = session.update(1100000L, landmarks(), [pixel(1, 1.0)])
  assert_eq(gap.decision, @guarded.Blocked)
  assert_eq(gap.health.status, @health.Pending)
  assert_eq(
    evidence_pixel_checkpoint(session.checkpoint()).motion.tracks.length(),
    0,
  )
}

///|
test "blocked evidence payloads require structure but never projection or normal arithmetic" {
  let session = evidence_fresh(multiplier=1.0e308)
  let huge = @moonground.PixelObservation::new(
    1,
    { x: 100.0, y: 100.0, },
    @types.Covariance2::isotropic(1000.0),
  )
  let blocked = session.update(0L, landmarks(), [huge])
  assert_eq(blocked.decision, @guarded.Blocked)
  assert_eq(blocked.analysis.measurement.projection_failures.length(), 0)
  assert_eq(blocked.analysis.counting.evidence.length(), 0)
  let before = @debug.to_string(session.checkpoint())
  for
    observations in [
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
    invalid(() => ignore(session.update(1L, [], observations)))
  }
  invalid(() => ignore(session.update(1L, [], [pixel(1, 0.0)], lost=[1])))
  invalid(() => ignore(session.update(1L, [], [], lost=[1], removed=[1])))
  invalid(() => ignore(session.update(1L, [], [], removed=[0])))
  assert_eq(@debug.to_string(session.checkpoint()), before)
}

///|
test "health identity covariance and time failures preserve all evidence guarded state" {
  let session = evidence_immediate()
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  let before = @debug.to_string(session.checkpoint())
  for
    bad in [
      [
        @health.LandmarkObservation::new(
          "unknown",
          { x: 0.0, y: 0.0, },
          @types.Covariance2::isotropic(0.1),
        ),
      ],
      [landmarks()[0], landmarks()[0]],
      [
        {
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
    session.update(100000L, landmarks(), [pixel(1, 1.0)]).analysis.counting.counting.counts[0].negative_to_positive,
    1L,
  )
}

///|
test "late normal overflow rolls back the very sample which would newly confirm healthy" {
  let session = evidence_fresh(
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
    evidence_pixel_checkpoint(session.checkpoint()).motion.next_segment_id,
    1L,
  )
  let retry = session.update(200000L, landmarks(), [pixel(1, -1.0)])
  assert_eq(retry.health.status, @health.Healthy)
  assert_eq(retry.health.streak_observations, 3)
  assert_eq(retry.analysis.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(retry.analysis.counting.evidence[0].side, 0)
  ignore(@guarded.EvidenceGuardedSession::from_checkpoint(session.checkpoint()))
}

///|
test "count exhaustion rolls back health time paths covariance and new segment allocation" {
  let original = evidence_immediate()
  ignore(original.update(0L, landmarks(), [pixel(1, -1.0)]))
  let saved = original.checkpoint()
  saved.analysis.counting.counts[0] = {
    ..saved.analysis.counting.counts[0],
    negative_to_positive: 9223372036854775807L,
  }
  let session = @guarded.EvidenceGuardedSession::from_checkpoint(saved)
  let before = @debug.to_string(session.checkpoint())
  invalid(() => {
    ignore(
      session.update(100000L, landmarks(), [pixel(1, 1.0), pixel(2, -1.0)]),
    )
  })
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let retry = session.update(100000L, landmarks(), [
    pixel(1, -2.0),
    pixel(2, -1.0),
  ])
  assert_eq(retry.analysis.measurement.motion.tracks[0].accepted_count, 2)
  assert_eq(retry.analysis.measurement.motion.tracks[1].segment_id, "2")
  assert_eq(session.checkpoint().health.last_timestamp_us, Some(100000L))
}

///|
test "blocked and allowed object capacity failures share the same validation and atomicity" {
  let session = @guarded.EvidenceGuardedSession::new(
    evidence_analysis(max_tracks=1, gate_tracks=1),
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
test "construction binds pixel mode full projection policy camera watermark and sufficient capacity" {
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedSession::new(
        evidence_analysis(max_tracks=2, gate_tracks=1),
        monitor(),
      ),
    )
  })
  let metric = @analysis.EvidenceAnalysisSession::from_ground(
    @moonground.MotionEstimator::new(
      "guarded",
      @moonground.MotionConfig::new(max_tracks=10),
    ),
    @events.EvidenceGateCounter::new(
      "guarded",
      [@events.LineGate::new("door", { x: -5.0, y: 0.0, }, { x: 5.0, y: 0.0, })],
      @events.GateConfig::new(max_tracks=10),
    ),
  )
  invalid(() => ignore(@guarded.EvidenceGuardedSession::new(metric, monitor())))
  let warm_monitor = monitor()
  ignore(warm_monitor.update(0L, landmarks()))
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedSession::new(evidence_analysis(), warm_monitor),
    )
  })
  let base = calibration()
  let altered_noise = @moonground.GroundCalibration::from_homography(
    [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    [
      { x: -10.0, y: -10.0, },
      { x: 10.0, y: -10.0, },
      { x: 10.0, y: 10.0, },
      { x: -10.0, y: 10.0, },
    ],
    max_meters_per_pixel=2.0,
    ground_noise_floor_m=0.1,
  )
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedSession::new(
        evidence_analysis(projection=altered_noise),
        monitor(projection=base),
      ),
    )
  })
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedSession::new(
        evidence_analysis(projection=replacement()),
        monitor(),
      ),
    )
  })
  let camera = @moonground.CameraModel::new(fx=30.0, fy=40.0, cx=0.0, cy=0.0)
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedSession::new(
        evidence_analysis(camera~),
        monitor(),
      ),
    )
  })
  let other = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    max_normalized_radius=0.5,
  )
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedSession::new(
        evidence_analysis(camera~),
        monitor(camera=other),
      ),
    )
  })
}

///|
test "nonhealthy imports reject active paths and healthy confirmation bounds include hidden tracks" {
  let analysis = evidence_analysis()
  ignore(analysis.update_pixel(0L, [pixel(1, -1.0)]))
  let health = monitor()
  ignore(health.update(0L, landmarks()))
  invalid(() => ignore(@guarded.EvidenceGuardedSession::new(analysis, health)))
  ignore(analysis.update_pixel(100000L, []))
  ignore(health.update(100000L, landmarks()))
  assert_eq(analysis.checkpoint().counting.tracks.length(), 0)
  invalid(() => ignore(@guarded.EvidenceGuardedSession::new(analysis, health)))
  let immediate = monitor(
    config=@health.HealthConfig::new(confirmation_us=0L, min_observations=2),
  )
  let earlier = evidence_analysis()
  ignore(earlier.update_pixel(0L, [pixel(1, -1.0)]))
  ignore(earlier.update_pixel(1L, []))
  ignore(immediate.update(0L, landmarks()))
  ignore(immediate.update(1L, landmarks()))
  invalid(() => ignore(@guarded.EvidenceGuardedSession::new(earlier, immediate)))
}

///|
test "new guarded checkpoint delegates current covariance and historical evidence binding to analysis" {
  let session = evidence_immediate()
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  let saved = session.checkpoint()
  let counting = saved.analysis.counting
  let track = counting.tracks[0]
  let anchor = track.anchors[0].unwrap()
  let changed = {
    ..counting,
    tracks: [
      {
        ..track,
        anchors: [
          Some({ ..anchor, covariance: @types.Covariance2::isotropic(0.02), }),
        ],
      },
    ],
  }
  ignore(@events.EvidenceGateCounter::from_checkpoint(changed))
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedSession::from_checkpoint({
        ..saved,
        analysis: { ..saved.analysis, counting: changed, },
      }),
    )
  })
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedSession::from_checkpoint({ ..saved, version: 2, }),
    )
  })
}

///|
test "per-target projection rejection commits health and removes current covariance evidence" {
  let session = evidence_immediate()
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  let rejected = session.update(100000L, landmarks(), [pixel(1, 0.0, x=100.0)])
  assert_eq(rejected.decision, @guarded.Allowed)
  assert_eq(rejected.analysis.measurement.projection_failures.length(), 1)
  assert_eq(rejected.analysis.counting.evidence.length(), 0)
  assert_eq(session.checkpoint().health.last_timestamp_us, Some(100000L))
  ignore(@guarded.EvidenceGuardedSession::from_checkpoint(session.checkpoint()))
}

///|
test "evidence guarded restoration continues every health policy boundary exactly" {
  let frames = [
    (0L, landmarks(), [pixel(1, -1.0)]),
    (100000L, landmarks(), [pixel(1, -1.0)]),
    (200000L, landmarks(), [pixel(1, 1.0)]),
    (250000L, landmarks(shift=0.5), [pixel(1, -1.0)]),
    (350000L, landmarks(shift=0.5), []),
    (400000L, [], []),
    (450000L, landmarks(), [pixel(1, 1.0)]),
    (550000L, landmarks(), [pixel(1, 1.0)]),
    (650000L, landmarks(), [pixel(1, -1.0)]),
  ]
  let full = evidence_fresh()
  let expected : Array[String] = []
  for (time, references, observations) in frames {
    expected.push(@debug.to_string(full.update(time, references, observations)))
  }
  for cut in 0..<=frames.length() {
    let prefix = evidence_fresh()
    for index in 0..<cut {
      let (time, references, observations) = frames[index]
      ignore(prefix.update(time, references, observations))
    }
    let resumed = @guarded.EvidenceGuardedSession::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<frames.length() {
      let (time, references, observations) = frames[index]
      assert_eq(
        @debug.to_string(resumed.update(time, references, observations)),
        expected[index],
      )
    }
    assert_eq(
      @debug.to_string(resumed.checkpoint()),
      @debug.to_string(full.checkpoint()),
    )
  }
}

///|
test "evidence guarded constructor forks checkpoints and returned arrays detach mutable state" {
  let analysis = evidence_analysis()
  let health = monitor()
  let session = @guarded.EvidenceGuardedSession::new(analysis, health)
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0)]))
  let fork = session.fork()
  let saved = session.checkpoint()
  let restored = @guarded.EvidenceGuardedSession::from_checkpoint(saved)
  let before = @debug.to_string(session.checkpoint())
  saved.health.landmarks.clear()
  saved.analysis.counting.tracks[0].anchors.clear()
  evidence_pixel_checkpoint(saved).motion.tracks[0].state[0] = 999.0
  ignore(analysis.update_pixel(0L, [pixel(1, 5.0)]))
  ignore(health.update(0L, landmarks(shift=0.5)))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(@debug.to_string(restored.checkpoint()), before)
  let result = fork.update(200000L, landmarks(), [pixel(1, 1.0)])
  assert_eq(
    @debug.to_string(result),
    @debug.to_string(restored.update(200000L, landmarks(), [pixel(1, 1.0)])),
  )
  result.health.landmarks.clear()
  result.analysis.counting.counting.counts.clear()
  result.analysis.counting.evidence.clear()
  assert_eq(
    @debug.to_string(fork.checkpoint()),
    @debug.to_string(restored.checkpoint()),
  )
}

///|
test "warm Brown evidence guard reframes health and motion jointly with complete continuation" {
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let session = evidence_fresh(camera~)
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0)]))
  let transform = @types.PixelTransform::new(
    scale_x=2.0,
    scale_y=0.5,
    offset_x=4.0,
    offset_y=-2.0,
  )
  let adapted = session.reframed(transform)
  assert_eq(
    @debug.to_string(adapted.checkpoint().analysis.counting),
    @debug.to_string(session.checkpoint().analysis.counting),
  )
  assert_eq(
    @debug.to_string(evidence_pixel_checkpoint(adapted.checkpoint()).motion),
    @debug.to_string(evidence_pixel_checkpoint(session.checkpoint()).motion),
  )
  let restored = @guarded.EvidenceGuardedSession::from_checkpoint(
    adapted.checkpoint(),
  )
  for index in 2..<=4 {
    let time = index.to_int64() * 100000L
    let observation = pixel(1, index.to_double() - 1.0)
    let expected = session.update(time, landmarks(), [observation])
    let references = landmarks().map(item => item.reframed(transform))
    let actual = adapted.update(time, references, [
      observation.reframed(transform),
    ])
    assert_eq(
      @debug.to_string(actual),
      @debug.to_string(
        restored.update(time, references, [observation.reframed(transform)]),
      ),
    )
    assert_eq(actual.decision, expected.decision)
    assert_eq(
      actual.analysis.counting.counting.counts[0].negative_to_positive,
      expected.analysis.counting.counting.counts[0].negative_to_positive,
    )
    assert_true(
      (actual.analysis.measurement.motion.tracks[0].position.unwrap().y -
      expected.analysis.measurement.motion.tracks[0].position.unwrap().y).abs() <
      1.0e-8,
    )
  }
}

///|
test "unstarted evidence replacement preserves multiplier and requires a later fresh health sample" {
  let session = evidence_immediate(multiplier=3.0)
  let barrier = session.replace_projection(0L, replacement(), camera=None)
  assert_eq(barrier.decision, @guarded.Blocked)
  assert_eq(barrier.health.status, @health.Insufficient)
  assert_eq(barrier.health.streak_observations, 0)
  assert_eq(barrier.suppressed_track_ids, [])
  assert_eq(session.checkpoint().analysis.counting.sigma_multiplier, 3.0)
  assert_eq(
    evidence_pixel_checkpoint(session.checkpoint()).motion.next_segment_id,
    1L,
  )
  invalid(() => {
    ignore(session.update(0L, scaled_landmarks(2.0), [pixel(1, -0.5)]))
  })
  assert_eq(
    session.update(1L, scaled_landmarks(2.0), [pixel(1, -0.5)]).decision,
    @guarded.Allowed,
  )
}

///|
test "active evidence replacement closes hidden paths and retains metric policy totals and next identity" {
  let session = evidence_fresh(multiplier=3.0)
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0), pixel(2, -1.0)]))
  ignore(session.update(200000L, landmarks(), [pixel(1, 1.0)]))
  let before = session.checkpoint()
  let barrier = session.replace_projection(
    250000L,
    brown_calibration(),
    camera=Some(brown_model()),
  )
  assert_eq(barrier.analysis.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(
    barrier.analysis.counting.counting.counts[0].negative_to_positive,
    1L,
  )
  let after = session.checkpoint()
  assert_eq(after.analysis.counting.sigma_multiplier, 3.0)
  assert_eq(
    @debug.to_string(after.analysis.counting.gates),
    @debug.to_string(before.analysis.counting.gates),
  )
  assert_eq(
    @debug.to_string(after.health.landmarks),
    @debug.to_string(before.health.landmarks),
  )
  assert_eq(evidence_pixel_checkpoint(after).motion.next_segment_id, 3L)
  assert_eq(after.analysis.counting.tracks.length(), 0)
  assert_true(evidence_pixel_checkpoint(after).camera is Some(_))
  assert_eq(
    session.update(300000L, brown_landmarks(), []).decision,
    @guarded.Blocked,
  )
  assert_eq(
    session.update(400000L, brown_landmarks(), []).decision,
    @guarded.Allowed,
  )
  ignore(@guarded.EvidenceGuardedSession::from_checkpoint(session.checkpoint()))
}

///|
test "evidence projection replacement resumes from both sides without bridging covariance anchors" {
  let session = evidence_immediate(multiplier=3.0)
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(session.update(100000L, landmarks(), [pixel(1, 1.0)]))
  let before = @guarded.EvidenceGuardedSession::from_checkpoint(
    session.checkpoint(),
  )
  let barrier = session.replace_projection(200000L, replacement(), camera=None)
  assert_eq(
    @debug.to_string(barrier),
    @debug.to_string(
      before.replace_projection(200000L, replacement(), camera=None),
    ),
  )
  let after = @guarded.EvidenceGuardedSession::from_checkpoint(
    session.checkpoint(),
  )
  let fresh = session.update(250000L, scaled_landmarks(2.0), [pixel(1, 0.5)])
  let resumed = after.update(250000L, scaled_landmarks(2.0), [pixel(1, 0.5)])
  assert_eq(@debug.to_string(fresh), @debug.to_string(resumed))
  assert_eq(
    @debug.to_string(fresh),
    @debug.to_string(
      before.update(250000L, scaled_landmarks(2.0), [pixel(1, 0.5)]),
    ),
  )
  assert_eq(fresh.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(fresh.analysis.counting.counting.crossings.length(), 0)
  assert_eq(fresh.analysis.counting.counting.counts[0].negative_to_positive, 1L)
}

///|
test "camera removal and equal projection barriers explicitly reset evidence without mutating a fork" {
  let session = evidence_fresh(
    config=@health.HealthConfig::new(confirmation_us=0L, min_observations=1),
    camera=brown_model(),
    projection=brown_calibration(),
    multiplier=3.0,
  )
  let observation = @moonground.PixelObservation::new(
    1,
    { x: 36.953182470782224, y: 34.26313959170113, },
    @types.Covariance2::isotropic(0.1),
  )
  ignore(session.update(0L, brown_landmarks(), [observation]))
  let branch = session.fork()
  let before = @debug.to_string(branch.checkpoint())
  ignore(session.replace_projection(1L, calibration(), camera=None))
  assert_true(evidence_pixel_checkpoint(session.checkpoint()).camera is None)
  assert_eq(session.checkpoint().analysis.counting.sigma_multiplier, 3.0)
  let reset = session.replace_projection(2L, calibration(), camera=None)
  assert_eq(reset.health.status, @health.Insufficient)
  assert_eq(reset.analysis.measurement.motion.closed_segment_ids, [])
  let allowed = session.update(3L, landmarks(), [pixel(1, -1.0)])
  assert_eq(allowed.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(@debug.to_string(branch.checkpoint()), before)
}

///|
test "replacement and fresh segments preserve exact maximum clocks and exhausted identities atomically" {
  let session = evidence_immediate()
  let end = 9223372036854775807L
  ignore(session.update(end - 2L, landmarks(), [pixel(1, -1.0)]))
  let old = @debug.to_string(session.checkpoint())
  invalid(() => {
    ignore(session.replace_projection(end - 2L, replacement(), camera=None))
  })
  assert_eq(@debug.to_string(session.checkpoint()), old)
  ignore(session.replace_projection(end - 1L, calibration(), camera=None))
  assert_eq(
    session.update(end, landmarks(), [pixel(1, 1.0)]).analysis.measurement.motion.tracks[0].segment_id,
    "2",
  )
  ignore(@guarded.EvidenceGuardedSession::from_checkpoint(session.checkpoint()))
  let original = evidence_immediate()
  ignore(original.update(0L, landmarks(), []))
  let saved = original.checkpoint()
  let pixel_state = evidence_pixel_checkpoint(saved)
  let exhausted = @guarded.EvidenceGuardedSession::from_checkpoint({
    ..saved,
    analysis: {
      ..saved.analysis,
      measurement: Pixel({
        ..pixel_state,
        motion: { ..pixel_state.motion, next_segment_id: end, },
      }),
    },
  })
  ignore(exhausted.replace_projection(1L, calibration(), camera=None))
  let before = @debug.to_string(exhausted.checkpoint())
  invalid(() => ignore(exhausted.update(2L, landmarks(), [pixel(1, -1.0)])))
  assert_eq(@debug.to_string(exhausted.checkpoint()), before)
  assert_eq(exhausted.update(2L, landmarks(), []).decision, @guarded.Allowed)
}
