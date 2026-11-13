///|
fn evidence_counter(
  session_id~ : String = "analysis",
  max_tracks~ : Int32 = 10,
  limit? : Double,
  gates? : Array[@events.LineGate],
  multiplier~ : Double = 2.0,
) -> @events.EvidenceGateCounter raise @types.GroundError {
  let base = counter(session_id~, max_tracks~, limit?, gates?).checkpoint()
  @events.EvidenceGateCounter::new(
    base.session_id,
    base.gates,
    base.config,
    sigma_multiplier=multiplier,
  )
}

///|
fn evidence_ground(
  max_tracks~ : Int32 = 10,
  counter_tracks~ : Int32 = 10,
  multiplier~ : Double = 2.0,
) -> @analysis.EvidenceAnalysisSession raise @types.GroundError {
  @analysis.EvidenceAnalysisSession::from_ground(
    @motion.MotionEstimator::new("analysis", config(max_tracks~)),
    evidence_counter(max_tracks=counter_tracks, multiplier~),
  )
}

///|
fn evidence_motion(
  checkpoint : @analysis.EvidenceAnalysisCheckpoint,
) -> @motion.MotionCheckpoint {
  match checkpoint.measurement {
    @analysis.Pixel(value) => value.motion
    @analysis.Ground(value) => value
  }
}

///|
fn evidence_observation(
  x : Double,
  y : Double,
  covariance : @types.Covariance2,
  id~ : Int32 = 1,
) -> @types.GroundObservation raise @types.GroundError {
  @types.GroundObservation::new(id, { x, y, }, covariance)
}

///|
test "evidence analysis pixel output equals existing Brown measurement and evidence counting" {
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let measurement = pixel_session(camera~)
  let counting = evidence_counter()
  let combined = @analysis.EvidenceAnalysisSession::from_pixel(
    measurement, counting,
  )
  for
    index, observations in [
      [pixel(0.0, -1.0)],
      [pixel(0.0, 0.0)],
      [pixel(0.0, 1.0), pixel(100.0, 0.0, id=2)],
      [],
      [pixel(0.0, -1.0)],
    ] {
    let time = index.to_int64() * 100000L
    let frame = measurement.update(time, observations)
    let result = combined.update_pixel(time, observations)
    assert_eq(@debug.to_string(result.measurement), @debug.to_string(frame))
    assert_eq(
      @debug.to_string(result.counting),
      @debug.to_string(counting.update(frame.motion)),
    )
  }
  assert_eq(
    @debug.to_string(combined.checkpoint().counting),
    @debug.to_string(counting.checkpoint()),
  )
}

///|
test "evidence analysis metric checkpoints continue every lost removed missing and gap cut" {
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
  let full = evidence_ground()
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
  let complete = @debug.to_string(full.checkpoint())
  for cut in 0..<=observations.length() {
    let prefix = evidence_ground()
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
    let restored = @analysis.EvidenceAnalysisSession::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<observations.length() {
      assert_eq(
        @debug.to_string(
          restored.update_ground(
            times[index],
            observations[index],
            lost=if index == 5 { [1] } else { [] },
            removed=if index == 7 { [1] } else { [] },
          ),
        ),
        expected[index],
      )
    }
    assert_eq(@debug.to_string(restored.checkpoint()), complete)
  }
}

///|
test "evidence counter exhaustion rolls back complete measured motion before same-time retry" {
  let session = evidence_ground()
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  let saved = session.checkpoint()
  let exhausted = @analysis.EvidenceAnalysisSession::from_checkpoint({
    ..saved,
    counting: {
      ..saved.counting,
      counts: [
        {
          ..saved.counting.counts[0],
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
test "late evidence precision failure rolls back earlier crossings and new segment allocation" {
  let session = evidence_ground()
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  let before = @debug.to_string(session.checkpoint())
  let unsupported = evidence_observation(
    1.0,
    -1.0,
    @types.Covariance2::new(1.0, -0.9999999999999999, 1.0),
    id=2,
  )
  invalid(() => {
    ignore(session.update_ground(100000L, [ground(0.0, 1.0), unsupported]))
  })
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let retry = session.update_ground(100000L, [
    ground(0.0, 1.0),
    ground(1.0, -1.0, id=2),
  ])
  assert_eq(retry.counting.counting.counts[0].negative_to_positive, 1L)
  assert_eq(retry.measurement.motion.tracks[1].segment_id, "2")
  assert_eq(evidence_motion(session.checkpoint()).next_segment_id, 3L)
}

///|
test "evidence geometry and capacity failures preserve unstarted measurement identities" {
  let huge = @events.LineGate::new("huge", { x: -1.0e308, y: 0.0, }, {
    x: -9.0e307,
    y: 0.0,
  })
  let session = @analysis.EvidenceAnalysisSession::from_ground(
    @motion.MotionEstimator::new("analysis", config()),
    evidence_counter(gates=[huge]),
  )
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.update_ground(0L, [ground(1.0e308, 1.0)])))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(
    session.update_ground(0L, [ground(0.0, 1.0)]).measurement.motion.tracks[0].segment_id,
    "1",
  )
  let bounded = evidence_ground(max_tracks=2, counter_tracks=1)
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
test "evidence analysis rejects mode malformed and conflicting frames without advancing" {
  let session = evidence_ground()
  let pixel_session = @analysis.EvidenceAnalysisSession::from_pixel(
    pixel_session(),
    evidence_counter(),
  )
  invalid(() => ignore(session.update_pixel(0L, [pixel(0.0, -1.0)])))
  invalid(() => ignore(pixel_session.update_ground(0L, [ground(0.0, -1.0)])))
  invalid(() => ignore(session.update_ground(-1L, [])))
  invalid(() => {
    ignore(session.update_ground(0L, [ground(0.0, -1.0), ground(1.0, 1.0)]))
  })
  invalid(() => ignore(session.update_ground(0L, [ground(0.0, -1.0)], lost=[1])))
  invalid(() => ignore(session.update_ground(0L, [], lost=[1], removed=[1])))
  invalid(() => {
    ignore(
      session.update_ground(0L, [
        {
          track_id: 1,
          position: { x: 0.0, y: -1.0, },
          covariance: { xx: 1.0, xy: 2.0, yy: 1.0, },
        },
      ]),
    )
  })
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.update_ground(0L, [])))
  invalid(() => ignore(session.reframed(@types.PixelTransform::new())))
  assert_eq(@debug.to_string(session.checkpoint()), before)
}

///|
test "evidence pair rejects wrong version session watermark missing identities and segments" {
  let session = evidence_ground()
  ignore(session.update_ground(100000L, [ground(0.0, -1.0)]))
  let saved = session.checkpoint()
  for
    bad in [
      { ..saved, version: 2, },
      { ..saved, counting: { ..saved.counting, session_id: "other", }, },
      {
        ..saved,
        counting: { ..saved.counting, last_timestamp_us: Some(100001L), },
      },
      { ..saved, counting: { ..saved.counting, tracks: [], }, },
      {
        ..saved,
        counting: {
          ..saved.counting,
          tracks: [{ ..saved.counting.tracks[0], track_id: 2, }],
        },
      },
      {
        ..saved,
        counting: {
          ..saved.counting,
          tracks: [{ ..saved.counting.tracks[0], segment_id: "2", }],
        },
      },
    ] {
    invalid(() => {
      ignore(@analysis.EvidenceAnalysisSession::from_checkpoint(bad))
    })
  }
  let motion = @motion.MotionEstimator::new("analysis", config())
  ignore(motion.update(100000L, [ground(0.0, -1.0)]))
  invalid(() => {
    ignore(
      @analysis.EvidenceAnalysisSession::from_ground(motion, evidence_counter()),
    )
  })
}

///|
test "confirmed current evidence anchor binds exact filtered point covariance and timestamp" {
  let session = evidence_ground()
  ignore(session.update_ground(100000L, [ground(0.0, -1.0)]))
  let first = session.checkpoint().counting.tracks[0].anchors[0].unwrap()
  ignore(session.update_ground(200000L, [ground(0.0, -2.0)]))
  let saved = session.checkpoint()
  let track = saved.counting.tracks[0]
  let current = track.anchors[0].unwrap()
  for
    anchor in [
      None,
      Some(first),
      Some({ ..current, point_m: { x: 1.0, y: current.point_m.y, }, }),
      Some({ ..current, covariance: @types.Covariance2::isotropic(0.02), }),
    ] {
    invalid(() => {
      ignore(
        @analysis.EvidenceAnalysisSession::from_checkpoint({
          ..saved,
          counting: {
            ..saved.counting,
            tracks: [{ ..track, anchors: [anchor], }],
          },
        }),
      )
    })
  }
}

///|
test "unconfirmed current evidence retains only an in-segment historical first-point anchor" {
  let session = evidence_ground()
  ignore(session.update_ground(100000L, [ground(0.0, -1.0)]))
  let current = session.update_ground(200000L, [ground(0.0, 0.0)])
  assert_eq(current.counting.evidence[0].side, 0)
  let saved = session.checkpoint()
  ignore(@analysis.EvidenceAnalysisSession::from_checkpoint(saved))
  let track = saved.counting.tracks[0]
  let anchor = track.anchors[0].unwrap()
  assert_eq(anchor.timestamp_us, 100000L)
  for
    bad in [
      { ..anchor, timestamp_us: 99999L, },
      { ..anchor, point_m: { x: 1.0, y: anchor.point_m.y, }, },
    ] {
    invalid(() => {
      ignore(
        @analysis.EvidenceAnalysisSession::from_checkpoint({
          ..saved,
          counting: {
            ..saved.counting,
            tracks: [{ ..track, anchors: [Some(bad)], }],
          },
        }),
      )
    })
  }
}

///|
test "unconfirmed current covariance cannot borrow a stable current anchor with a different covariance" {
  let session = evidence_ground()
  let result = session.update_ground(0L, [ground(0.0, 0.15, std=1.0)])
  assert_eq(result.counting.evidence[0].side, 0)
  let saved = session.checkpoint()
  let track = saved.counting.tracks[0]
  let counting = {
    ..saved.counting,
    tracks: [
      {
        ..track,
        anchors: [
          Some({
            timestamp_us: 0L,
            point_m: { x: 0.0, y: 0.15, },
            covariance: @types.Covariance2::isotropic(0.001),
          }),
        ],
      },
    ],
  }
  ignore(@events.EvidenceGateCounter::from_checkpoint(counting))
  invalid(() => {
    ignore(
      @analysis.EvidenceAnalysisSession::from_checkpoint({ ..saved, counting, }),
    )
  })
}

///|
test "evidence restore preserves the exact upper position block despite allowed lower-block roundoff" {
  let session = evidence_ground()
  let covariance = @types.Covariance2::new(0.04, 0.009, 0.01)
  ignore(
    session.update_ground(0L, [evidence_observation(0.0, -1.0, covariance)]),
  )
  ignore(
    session.update_ground(100000L, [evidence_observation(0.0, -2.0, covariance)]),
  )
  let saved = session.checkpoint()
  let original = evidence_motion(saved)
  let changed = original.tracks[0].covariance.copy()
  changed[4] = changed[1] * (1.0 + 1.0e-12)
  let motion = {
    ..original,
    tracks: [{ ..original.tracks[0], covariance: changed, }],
  }
  ignore(
    @analysis.EvidenceAnalysisSession::from_checkpoint({
      ..saved,
      measurement: Ground(motion),
    }),
  )
  changed[1] = changed[1] * (1.0 + 1.0e-12)
  ignore(@motion.MotionEstimator::from_checkpoint(motion))
  invalid(() => {
    ignore(
      @analysis.EvidenceAnalysisSession::from_checkpoint({
        ..saved,
        measurement: Ground(motion),
      }),
    )
  })
}

///|
test "scalar quality uses the exact boundary and skips unsupported normal covariance before classification" {
  let measurement = @motion.MotionEstimator::new("analysis", config())
  let frame = measurement.update(0L, [
    evidence_observation(0.0, -1.0, @types.Covariance2::new(0.04, 0.009, 0.01)),
  ])
  let limit = frame.tracks[0].position_std_m.unwrap()
  let exact = evidence_counter(limit~)
  ignore(exact.update(frame))
  ignore(@analysis.EvidenceAnalysisSession::from_ground(measurement, exact))
  let skipped = evidence_counter(limit=limit * 0.999999)
  ignore(skipped.update(frame))
  assert_eq(skipped.checkpoint().tracks.length(), 0)
  ignore(@analysis.EvidenceAnalysisSession::from_ground(measurement, skipped))
  let session = @analysis.EvidenceAnalysisSession::from_ground(
    @motion.MotionEstimator::new("analysis", config()),
    evidence_counter(limit=0.1),
  )
  let result = session.update_ground(0L, [
    evidence_observation(
      0.0,
      -1.0,
      @types.Covariance2::new(1.0, -0.9999999999999999, 1.0),
    ),
  ])
  assert_eq(result.counting.evidence.length(), 0)
  ignore(
    @analysis.EvidenceAnalysisSession::from_checkpoint(session.checkpoint()),
  )
}

///|
test "unconfirmed evidence restore still rejects an unsupported current motion covariance" {
  let session = evidence_ground()
  ignore(session.update_ground(0L, [ground(0.0, 0.0)]))
  let saved = session.checkpoint()
  let original = evidence_motion(saved)
  let covariance = original.tracks[0].covariance.copy()
  covariance[0] = 1.0
  covariance[1] = -0.9999999999999999
  covariance[4] = covariance[1]
  covariance[5] = 1.0
  let motion = { ..original, tracks: [{ ..original.tracks[0], covariance, }], }
  // Both component checkpoints are individually valid. The current point has
  // no anchor, so only the joined relation can require this numerical check.
  ignore(@motion.MotionEstimator::from_checkpoint(motion))
  ignore(@events.EvidenceGateCounter::from_checkpoint(saved.counting))
  invalid(() => {
    ignore(
      @analysis.EvidenceAnalysisSession::from_checkpoint({
        ..saved,
        measurement: Ground(motion),
      }),
    )
  })
}

///|
test "rejected projection innovation and numerical failures commit frames without stale evidence" {
  let pixel = @analysis.EvidenceAnalysisSession::from_pixel(
    pixel_session(),
    evidence_counter(),
  )
  ignore(
    pixel.update_pixel(0L, [
      @moonground.PixelObservation::new(
        1,
        { x: 0.0, y: -1.0, },
        @types.Covariance2::isotropic(0.01),
      ),
    ]),
  )
  let rejected = pixel.update_pixel(100000L, [
    @moonground.PixelObservation::new(
      1,
      { x: 100.0, y: 0.0, },
      @types.Covariance2::isotropic(0.01),
    ),
  ])
  assert_eq(rejected.measurement.projection_failures.length(), 1)
  assert_eq(rejected.counting.evidence.length(), 0)
  ignore(@analysis.EvidenceAnalysisSession::from_checkpoint(pixel.checkpoint()))
  let metric = @analysis.EvidenceAnalysisSession::from_ground(
    @motion.MotionEstimator::new(
      "analysis",
      @motion.MotionConfig::new(gate=0.01),
    ),
    evidence_counter(),
  )
  ignore(metric.update_ground(0L, [ground(0.0, -1.0)]))
  assert_eq(
    metric.update_ground(100000L, [ground(0.0, 1000.0)]).measurement.motion.tracks[0].status,
    @motion.RejectedInnovation,
  )
  let restored = @analysis.EvidenceAnalysisSession::from_checkpoint(
    metric.checkpoint(),
  )
  let failed = metric.update_ground(200000L, [ground(1.0e308, 1.0e308)])
  assert_eq(
    failed.measurement.motion.tracks[0].status,
    @motion.NumericalFailure,
  )
  assert_eq(
    @debug.to_string(failed),
    @debug.to_string(
      restored.update_ground(200000L, [ground(1.0e308, 1.0e308)]),
    ),
  )
  ignore(
    @analysis.EvidenceAnalysisSession::from_checkpoint(metric.checkpoint()),
  )
}

///|
test "evidence forks constructor inputs checkpoints and output arrays are independent" {
  let measurement = pixel_session()
  let counting = evidence_counter()
  let session = @analysis.EvidenceAnalysisSession::from_pixel(
    measurement, counting,
  )
  ignore(session.update_pixel(0L, [pixel(0.0, -1.0)]))
  let branch = session.fork()
  let saved = session.checkpoint()
  let restored = @analysis.EvidenceAnalysisSession::from_checkpoint(saved)
  let before = @debug.to_string(session.checkpoint())
  saved.counting.tracks[0].anchors[0] = None
  saved.counting.counts.clear()
  match saved.measurement {
    Pixel(pixel) => {
      pixel.motion.tracks[0].state[0] = 999.0
      pixel.motion.tracks.clear()
    }
    Ground(_) => fail("expected pixel")
  }
  ignore(counting.update(measurement.update(0L, [pixel(5.0, 5.0)]).motion))
  let branch_frame = branch.update_pixel(100000L, [pixel(0.0, 1.0)])
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(@debug.to_string(restored.checkpoint()), before)
  let expected = restored.update_pixel(100000L, [pixel(0.0, 1.0)])
  assert_eq(@debug.to_string(branch_frame), @debug.to_string(expected))
  expected.counting.evidence.clear()
  expected.counting.counting.counts.clear()
  expected.measurement.motion.tracks.clear()
  assert_eq(
    @debug.to_string(branch.checkpoint()),
    @debug.to_string(restored.checkpoint()),
  )
}

///|
test "warm Brown evidence analysis reframes and restores without changing committed metric state" {
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let session = @analysis.EvidenceAnalysisSession::from_pixel(
    pixel_session(camera~),
    evidence_counter(),
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
    @debug.to_string(evidence_motion(adapted.checkpoint())),
    @debug.to_string(evidence_motion(session.checkpoint())),
  )
  let restored = @analysis.EvidenceAnalysisSession::from_checkpoint(
    adapted.checkpoint(),
  )
  for index in 1..<=4 {
    let observation = pixel(0.0, index.to_double() - 1.0)
    let time = index.to_int64() * 100000L
    let original = session.update_pixel(time, [observation])
    let actual = adapted.update_pixel(time, [observation.reframed(transform)])
    assert_eq(
      @debug.to_string(actual),
      @debug.to_string(
        restored.update_pixel(time, [observation.reframed(transform)]),
      ),
    )
    assert_eq(
      actual.counting.counting.counts[0].negative_to_positive,
      original.counting.counting.counts[0].negative_to_positive,
    )
    let a = actual.measurement.motion.tracks[0].filtered_state.unwrap()
    let b = original.measurement.motion.tracks[0].filtered_state.unwrap()
    for index in 0..<4 {
      assert_true((a[index] - b[index]).abs() < 1.0e-9)
    }
  }
}

///|
test "evidence interruption closes hidden metric and pixel segments and retains counts and next identity" {
  let session = evidence_ground()
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(100000L, [ground(0.0, 1.0)]))
  ignore(session.update_ground(150000L, []))
  assert_eq(evidence_motion(session.checkpoint()).tracks.length(), 1)
  let closed = session.interrupt(200000L)
  assert_eq(closed.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(closed.counting.counting.counts[0].negative_to_positive, 1L)
  assert_eq(closed.counting.evidence.length(), 0)
  assert_eq(evidence_motion(session.checkpoint()).next_segment_id, 2L)
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.interrupt(200000L)))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(
    session.update_ground(300000L, [ground(0.0, -1.0)]).measurement.motion.tracks[0].segment_id,
    "2",
  )
  let pixel = @analysis.EvidenceAnalysisSession::from_pixel(
    pixel_session(),
    evidence_counter(),
  )
  ignore(
    pixel.update_pixel(0L, [
      @moonground.PixelObservation::new(
        1,
        { x: 0.0, y: -1.0, },
        @types.Covariance2::isotropic(0.01),
      ),
    ]),
  )
  assert_eq(pixel.interrupt(1L).measurement.motion.closed_segment_ids, ["1"])
  assert_eq(pixel.interrupt(2L).measurement.motion.closed_segment_ids, [])
}

///|
test "evidence interrupt with a tighter counting capacity rolls back both engines" {
  let session = evidence_ground(max_tracks=2, counter_tracks=1)
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(1L, [ground(1.0, -1.0, id=2)]))
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.interrupt(2L)))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  ignore(session.update_ground(2L, [], removed=[1]))
  assert_eq(session.interrupt(3L).measurement.motion.closed_segment_ids, ["2"])
}

///|
test "evidence atomic streams retain exact maximum clock and exhausted segment allocation" {
  let session = evidence_ground()
  ignore(session.update_ground(9223372036854775806L, [ground(0.0, -1.0)]))
  let final_frame = session.update_ground(9223372036854775807L, [
    ground(0.0, -1.0),
  ])
  assert_eq(final_frame.counting.counting.timestamp_us, 9223372036854775807L)
  ignore(
    @analysis.EvidenceAnalysisSession::from_checkpoint(session.checkpoint()),
  )
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.interrupt(9223372036854775807L)))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let fresh = evidence_ground()
  ignore(fresh.update_ground(0L, []))
  let saved = fresh.checkpoint()
  let motion = evidence_motion(saved)
  let exhausted = @analysis.EvidenceAnalysisSession::from_checkpoint({
    ..saved,
    measurement: Ground({ ..motion, next_segment_id: 9223372036854775807L, }),
  })
  let initial = @debug.to_string(exhausted.checkpoint())
  invalid(() => ignore(exhausted.update_ground(1L, [ground(0.0, -1.0)])))
  assert_eq(@debug.to_string(exhausted.checkpoint()), initial)
  ignore(exhausted.update_ground(1L, []))
}

///|
test "zero multiplier evidence analysis preserves legacy analysis counting on supported covariance" {
  let legacy = fresh_ground()
  let evidence = evidence_ground(multiplier=0.0)
  for index, y in [-1.0, 0.0, 1.0, -1.0] {
    let time = index.to_int64() * 100000L
    let original = legacy.update_ground(time, [ground(0.0, y)])
    let result = evidence.update_ground(time, [ground(0.0, y)])
    assert_eq(
      @debug.to_string(result.measurement),
      @debug.to_string(original.measurement),
    )
    assert_eq(
      @debug.to_string(result.counting.counting),
      @debug.to_string(original.counting),
    )
    assert_eq(
      result.counting.evidence[0].lower_m,
      result.counting.evidence[0].distance_m,
    )
    assert_true(result.counting.evidence[0].normal_std_m > 0.0)
  }
}
