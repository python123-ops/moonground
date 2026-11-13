///|
fn transit_config(
  max_tracks~ : Int32 = 10,
) -> @motion.MotionConfig raise @types.GroundError {
  @motion.MotionConfig::new(max_tracks~, q=1.0e6, gate=1.0e12)
}

///|
fn session_transit_counter(
  max_tracks~ : Int32 = 10,
  multiplier~ : Double = 2.0,
  limit? : Double,
  gates? : Array[@events.LineGate],
  sections? : Array[@transit.Section],
  ttl~ : Int64 = 300000000L,
) -> @transit.EvidenceTransitCounter raise @types.GroundError {
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
        @events.LineGate::new(
          "exit",
          { x: -5.0, y: 2.0, },
          { x: 5.0, y: 2.0, },
          deadband_m=0.1,
        ),
      ]
  }
  let sections = match sections {
    Some(sections) => sections
    None =>
      [
        @transit.Section::new(
          "aisle",
          "entry",
          @events.NegativeToPositive,
          "exit",
          @events.NegativeToPositive,
        ),
      ]
  }
  @transit.EvidenceTransitCounter::new(
    evidence_counter(max_tracks~, multiplier~, limit?, gates~),
    sections,
    max_duration_us=ttl,
  )
}

///|
fn transit_ground(
  max_tracks~ : Int32 = 10,
  counter_tracks~ : Int32 = 10,
  multiplier~ : Double = 2.0,
  limit? : Double,
  ttl~ : Int64 = 300000000L,
) -> @analysis.EvidenceTransitSession raise @types.GroundError {
  @analysis.EvidenceTransitSession::from_ground(
    @motion.MotionEstimator::new("analysis", transit_config(max_tracks~)),
    session_transit_counter(
      max_tracks=counter_tracks,
      multiplier~,
      limit?,
      ttl~,
    ),
  )
}

///|
fn transit_motion(
  checkpoint : @analysis.EvidenceTransitSessionCheckpoint,
) -> @motion.MotionCheckpoint {
  match checkpoint.measurement {
    @analysis.Pixel(pixel) => pixel.motion
    @analysis.Ground(motion) => motion
  }
}

///|
fn pending_transit() -> @analysis.EvidenceTransitSession raise @types.GroundError {
  let session = transit_ground()
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(100000L, [ground(0.0, 1.0)]))
  session
}

///|
test "transit session metric frames and full states equal a single independent downstream chain" {
  let measurement = @motion.MotionEstimator::new("analysis", transit_config())
  let downstream = session_transit_counter()
  let session = @analysis.EvidenceTransitSession::from_ground(
    measurement, downstream,
  )
  for index, y in [-1.0, 1.0, 3.0, 1.0, -1.0, 1.0, 3.0] {
    let time = index.to_int64() * 60000L
    let observations = [
      evidence_observation(0.0, y, @types.Covariance2::new(0.04, 0.009, 0.01)),
    ]
    let frame = measurement.update(time, observations)
    let result = session.update_ground(time, observations)
    assert_eq(
      @debug.to_string(result.measurement.motion),
      @debug.to_string(frame),
    )
    assert_eq(
      @debug.to_string(result.transit),
      @debug.to_string(downstream.update(frame)),
    )
    assert_eq(
      @debug.to_string(transit_motion(session.checkpoint())),
      @debug.to_string(measurement.checkpoint()),
    )
    assert_eq(
      @debug.to_string(session.checkpoint().transit),
      @debug.to_string(downstream.checkpoint()),
    )
  }
  assert_eq(session.checkpoint().transit.counts[0].completed, 2L)
}

///|
test "transit session Brown pixel measurement matches independent projection covariance evidence and pairing" {
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let measurement = pixel_session(camera~)
  let downstream = session_transit_counter()
  let session = @analysis.EvidenceTransitSession::from_pixel(
    measurement, downstream,
  )
  for index, y in [-1.0, 1.0, 3.0] {
    let time = index.to_int64() * 100000L
    let frame = measurement.update(time, [pixel(0.0, y)])
    let result = session.update_pixel(time, [pixel(0.0, y)])
    assert_eq(@debug.to_string(result.measurement), @debug.to_string(frame))
    assert_eq(
      @debug.to_string(result.transit),
      @debug.to_string(downstream.update(frame.motion)),
    )
  }
  assert_eq(session.checkpoint().transit.counts[0].completed, 1L)
}

///|
test "complete transit session checkpoints continue every pending missing lost removed and exact gap cut" {
  let inputs = [
    [ground(0.0, -1.0)],
    [ground(0.0, 1.0)],
    [ground(0.0, 3.0)],
    [ground(0.0, -1.0)],
    [ground(0.0, 1.0)],
    [],
    [ground(0.0, 3.0)],
    [],
    [ground(0.0, -1.0)],
    [ground(0.0, 1.0)],
    [ground(0.0, 3.0)],
  ]
  let times = [
    0L, 100000L, 200000L, 300000L, 400000L, 500000L, 600000L, 700000L, 800000L, 900000L,
    1400000L,
  ]
  let full = transit_ground()
  let expected : Array[String] = []
  for index, observations in inputs {
    expected.push(
      @debug.to_string(
        full.update_ground(
          times[index],
          observations,
          lost=if index == 5 { [1] } else { [] },
          removed=if index == 7 { [1] } else { [] },
        ),
      ),
    )
  }
  let final_state = @debug.to_string(full.checkpoint())
  for cut in 0..<=inputs.length() {
    let prefix = transit_ground()
    for index in 0..<cut {
      ignore(
        prefix.update_ground(
          times[index],
          inputs[index],
          lost=if index == 5 { [1] } else { [] },
          removed=if index == 7 { [1] } else { [] },
        ),
      )
    }
    let restored = @analysis.EvidenceTransitSession::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<inputs.length() {
      assert_eq(
        @debug.to_string(
          restored.update_ground(
            times[index],
            inputs[index],
            lost=if index == 5 { [1] } else { [] },
            removed=if index == 7 { [1] } else { [] },
          ),
        ),
        expected[index],
      )
    }
    assert_eq(@debug.to_string(restored.checkpoint()), final_state)
  }
}

///|
test "started transit and measurement inputs retain pending entries without reconstructing historical totals" {
  let measurement = @motion.MotionEstimator::new("analysis", transit_config())
  let gates = evidence_counter(
    gates=session_transit_counter().checkpoint().counting.gates,
  )
  ignore(gates.update(measurement.update(0L, [ground(0.0, -1.0)])))
  ignore(gates.update(measurement.update(100000L, [ground(0.0, 1.0)])))
  let counter = @transit.EvidenceTransitCounter::new(
    gates,
    session_transit_counter().checkpoint().sections,
  )
  let without_entry = @analysis.EvidenceTransitSession::from_ground(
    measurement, counter,
  )
  assert_eq(without_entry.checkpoint().transit.pending.length(), 0)
  assert_eq(
    without_entry.update_ground(200000L, [ground(0.0, 3.0)]).transit.passages.length(),
    0,
  )
  let pending = pending_transit()
  let cp = pending.checkpoint()
  let adopted = @analysis.EvidenceTransitSession::from_ground(
    @motion.MotionEstimator::from_checkpoint(transit_motion(cp)),
    @transit.EvidenceTransitCounter::from_checkpoint(cp.transit),
  )
  assert_eq(
    adopted.update_ground(200000L, [ground(0.0, 3.0)]).transit.passages.length(),
    1,
  )
}

///|
test "gate count exhaustion rolls back motion paths pending witnesses and new IDs before same-time retry" {
  let session = pending_transit()
  let saved = session.checkpoint()
  let cp = saved.transit.counting
  let exhausted = @analysis.EvidenceTransitSession::from_checkpoint({
    ..saved,
    transit: {
      ..saved.transit,
      counting: {
        ..cp,
        counts: [
          cp.counts[0],
          { ..cp.counts[1], negative_to_positive: 9223372036854775807L, },
        ],
      },
    },
  })
  let before = @debug.to_string(exhausted.checkpoint())
  invalid(() => {
    ignore(
      exhausted.update_ground(200000L, [
        ground(0.0, 3.0),
        ground(1.0, -1.0, id=2),
      ]),
    )
  })
  assert_eq(@debug.to_string(exhausted.checkpoint()), before)
  let result = exhausted.update_ground(200000L, [
    ground(0.0, 1.0),
    ground(1.0, -1.0, id=2),
  ])
  assert_eq(result.transit.pending_count, 1)
  assert_eq(result.measurement.motion.tracks[0].accepted_count, 3)
  assert_eq(result.measurement.motion.tracks[1].segment_id, "2")
  assert_eq(transit_motion(exhausted.checkpoint()).next_segment_id, 3L)
}

///|
test "late normal covariance failure leaves all three stages unchanged and permits a corrected entry at the same time" {
  let session = transit_ground()
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  let before = @debug.to_string(session.checkpoint())
  invalid(() => {
    ignore(
      session.update_ground(100000L, [
        ground(0.0, 1.0),
        evidence_observation(
          1.0,
          -1.0,
          @types.Covariance2::new(1.0, -0.9999999999999999, 1.0),
          id=2,
        ),
      ]),
    )
  })
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let retry = session.update_ground(100000L, [
    ground(0.0, 1.0),
    ground(1.0, -1.0, id=2),
  ])
  assert_eq(retry.transit.pending_count, 1)
  assert_eq(retry.transit.counting.counting.counts[0].negative_to_positive, 1L)
  assert_eq(retry.measurement.motion.tracks[1].segment_id, "2")
}

///|
test "independent downstream capacity may atomically reject updates and interruption of hidden tracks" {
  let session = transit_ground(max_tracks=2, counter_tracks=1)
  let initial = @debug.to_string(session.checkpoint())
  invalid(() => {
    ignore(
      session.update_ground(0L, [ground(0.0, -1.0), ground(1.0, -1.0, id=2)]),
    )
  })
  assert_eq(@debug.to_string(session.checkpoint()), initial)
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(1L, [ground(1.0, -1.0, id=2)]))
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.interrupt(2L)))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  ignore(session.update_ground(2L, [], removed=[1]))
  assert_eq(session.interrupt(3L).measurement.motion.closed_segment_ids, ["2"])
}

///|
test "invalid modes timestamps observation covariance and identity sets preserve a transit session" {
  let session = transit_ground()
  let pixels = @analysis.EvidenceTransitSession::from_pixel(
    pixel_session(),
    session_transit_counter(),
  )
  invalid(() => ignore(session.update_pixel(0L, [pixel(0.0, 0.0)])))
  invalid(() => ignore(pixels.update_ground(0L, [ground(0.0, 0.0)])))
  invalid(() => ignore(session.reframed(@types.PixelTransform::new())))
  invalid(() => ignore(session.update_ground(-1L, [])))
  invalid(() => {
    ignore(session.update_ground(0L, [ground(0.0, -1.0), ground(1.0, 1.0)]))
  })
  invalid(() => {
    ignore(session.update_ground(0L, [ground(0.0, -1.0)], removed=[1]))
  })
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
  assert_eq(@debug.to_string(session.checkpoint()), before)
}

///|
test "projection innovation and scalar quality skips commit cancellations without stale interval evidence" {
  let pixels = @analysis.EvidenceTransitSession::from_pixel(
    pixel_session(),
    session_transit_counter(),
  )
  ignore(pixels.update_pixel(0L, [pixel(0.0, -1.0)]))
  ignore(pixels.update_pixel(100000L, [pixel(0.0, 1.0)]))
  let rejected = pixels.update_pixel(200000L, [pixel(100.0, 3.0)])
  assert_eq(rejected.measurement.projection_failures.length(), 1)
  assert_eq(rejected.transit.cancellations[0].reason, @transit.Discontinuity)
  assert_eq(rejected.transit.counting.evidence.length(), 0)
  ignore(@analysis.EvidenceTransitSession::from_checkpoint(pixels.checkpoint()))
  let quality = transit_ground(limit=0.1)
  let skipped = quality.update_ground(0L, [
    evidence_observation(
      0.0,
      -1.0,
      @types.Covariance2::new(1.0, -0.9999999999999999, 1.0),
    ),
  ])
  assert_eq(skipped.transit.counting.evidence.length(), 0)
  ignore(
    @analysis.EvidenceTransitSession::from_checkpoint(quality.checkpoint()),
  )
}

///|
test "innovation and numerical measurement rejections cancel pending entries without becoming fatal frame errors" {
  let saved = pending_transit().checkpoint()
  let motion = transit_motion(saved)
  let session = @analysis.EvidenceTransitSession::from_checkpoint({
    ..saved,
    measurement: Ground({
      ..motion,
      config: @motion.MotionConfig::new(q=1.0e6, gate=0.01, max_tracks=10),
    }),
  })
  let rejected = session.update_ground(200000L, [ground(0.0, 1000.0)])
  assert_eq(
    rejected.measurement.motion.tracks[0].status,
    @motion.RejectedInnovation,
  )
  assert_eq(rejected.transit.cancellations[0].reason, @transit.Discontinuity)
  assert_eq(rejected.transit.pending_count, 0)
  assert_eq(rejected.transit.counting.evidence.length(), 0)
  let failed = session.update_ground(300000L, [ground(1.0e308, 1.0e308)])
  assert_eq(
    failed.measurement.motion.tracks[0].status,
    @motion.NumericalFailure,
  )
  assert_eq(failed.transit.counting.evidence.length(), 0)
  assert_eq(
    session.checkpoint().transit.counting.last_timestamp_us,
    Some(300000L),
  )
  ignore(
    @analysis.EvidenceTransitSession::from_checkpoint(session.checkpoint()),
  )
}

///|
test "transit session restore rejects individually valid mismatched component clocks identities and current covariances" {
  let session = pending_transit()
  let saved = session.checkpoint()
  let gate = saved.transit.counting
  let track = gate.tracks[0]
  let anchor = track.anchors[0].unwrap()
  for
    cp in [
      { ..saved, version: 2, },
      {
        ..saved,
        transit: {
          ..saved.transit,
          counting: { ..gate, session_id: "other", },
        },
      },
      {
        ..saved,
        transit: {
          ..saved.transit,
          counting: { ..gate, last_timestamp_us: Some(100001L), },
        },
      },
      {
        ..saved,
        transit: {
          ..saved.transit,
          pending: [],
          counting: { ..gate, tracks: [], },
        },
      },
      {
        ..saved,
        transit: {
          ..saved.transit,
          pending: [],
          counting: {
            ..gate,
            tracks: [
              {
                ..track,
                anchors: [
                  Some({
                    ..anchor,
                    covariance: @types.Covariance2::isotropic(0.02),
                  }),
                  track.anchors[1],
                ],
              },
            ],
          },
        },
      },
    ] {
    invalid(() => ignore(@analysis.EvidenceTransitSession::from_checkpoint(cp)))
  }
  invalid(() => {
    ignore(
      @analysis.EvidenceTransitSession::from_ground(
        @motion.MotionEstimator::new("analysis", transit_config()),
        @transit.EvidenceTransitCounter::from_checkpoint(saved.transit),
      ),
    )
  })
}

///|
test "pending evidence entry cannot predate the joined motion segment or contradict its first filtered point" {
  let saved = pending_transit().checkpoint()
  let motion = transit_motion(saved)
  for
    track in [
      { ..motion.tracks[0], first_timestamp_us: 1L, },
      {
        ..motion.tracks[0],
        first_filtered: { x: 0.5, y: -1.0, },
        observed_path_length_m: 3.0,
      },
    ] {
    let altered = { ..motion, tracks: [track], }
    ignore(@motion.MotionEstimator::from_checkpoint(altered))
    ignore(@transit.EvidenceTransitCounter::from_checkpoint(saved.transit))
    invalid(() => {
      ignore(
        @analysis.EvidenceTransitSession::from_checkpoint({
          ..saved,
          measurement: Ground(altered),
        }),
      )
    })
  }
}

///|
test "sparse historical endpoint times cannot exceed the exact accepted observation count" {
  let session = pending_transit()
  ignore(session.update_ground(200000L, [ground(0.0, 1.5)]))
  let saved = session.checkpoint()
  let motion = transit_motion(saved)
  assert_eq(motion.tracks[0].accepted_count, 3)
  let altered = {
    ..motion,
    tracks: [{ ..motion.tracks[0], accepted_count: 2, }],
  }
  ignore(@motion.MotionEstimator::from_checkpoint(altered))
  ignore(@transit.EvidenceTransitCounter::from_checkpoint(saved.transit))
  invalid(() => {
    ignore(
      @analysis.EvidenceTransitSession::from_checkpoint({
        ..saved,
        measurement: Ground(altered),
      }),
    )
  })
}

///|
test "same historical timestamp across sections must keep one covariance while unknown first covariance is not invented" {
  let sections = [
    @transit.Section::new(
      "a",
      "entry",
      @events.NegativeToPositive,
      "exit",
      @events.NegativeToPositive,
    ),
    @transit.Section::new(
      "b",
      "entry",
      @events.NegativeToPositive,
      "exit",
      @events.NegativeToPositive,
    ),
  ]
  let session = @analysis.EvidenceTransitSession::from_ground(
    @motion.MotionEstimator::new("analysis", transit_config()),
    session_transit_counter(sections~),
  )
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(100000L, [ground(0.0, 1.0)]))
  let saved = session.checkpoint()
  assert_eq(saved.transit.pending.length(), 2)
  let changed = {
    ..saved.transit.pending[0],
    from_covariance: @types.Covariance2::isotropic(0.02),
  }
  let inconsistent = {
    ..saved.transit,
    pending: [changed, saved.transit.pending[1]],
  }
  ignore(@transit.EvidenceTransitCounter::from_checkpoint(inconsistent))
  invalid(() => {
    ignore(
      @analysis.EvidenceTransitSession::from_checkpoint({
        ..saved,
        transit: inconsistent,
      }),
    )
  })
  // The first filtered point is stored, but its original P is not. Consistent
  // historical covariance witnesses do not have to equal the current P.
  ignore(
    @analysis.EvidenceTransitSession::from_checkpoint({
      ..saved,
      transit: {
        ..saved.transit,
        pending: [
          changed,
          {
            ..saved.transit.pending[1],
            from_covariance: changed.from_covariance,
          },
        ],
      },
    }),
  )
}

///|
test "historical anchors from different gates at one accepted time cannot disagree about the point" {
  let gates = [
    @events.LineGate::new(
      "entry",
      { x: -5.0, y: 0.0, },
      { x: 5.0, y: 0.0, },
      deadband_m=0.1,
    ),
    @events.LineGate::new(
      "exit",
      { x: -5.0, y: 0.05, },
      { x: 5.0, y: 0.05, },
      deadband_m=0.1,
    ),
  ]
  let session = @analysis.EvidenceTransitSession::from_ground(
    @motion.MotionEstimator::new("analysis", transit_config()),
    session_transit_counter(gates~),
  )
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(100000L, [ground(0.0, -2.0)]))
  ignore(session.update_ground(200000L, [ground(0.0, 0.0)]))
  let saved = session.checkpoint()
  let gate = saved.transit.counting
  let track = gate.tracks[0]
  let anchor = track.anchors[1].unwrap()
  assert_eq(anchor.timestamp_us, 100000L)
  let changed = {
    ..saved.transit,
    counting: {
      ..gate,
      tracks: [
        {
          ..track,
          anchors: [
            track.anchors[0],
            Some({ ..anchor, point_m: { x: 0.5, y: anchor.point_m.y, }, }),
          ],
        },
      ],
    },
  }
  ignore(@transit.EvidenceTransitCounter::from_checkpoint(changed))
  invalid(() => {
    ignore(
      @analysis.EvidenceTransitSession::from_checkpoint({
        ..saved,
        transit: changed,
      }),
    )
  })
}

///|
test "warm Brown reframing preserves complete metric pending state and restores transformed continuation" {
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let original = @analysis.EvidenceTransitSession::from_pixel(
    pixel_session(camera~),
    session_transit_counter(),
  )
  ignore(original.update_pixel(0L, [pixel(0.0, -1.0)]))
  ignore(original.update_pixel(100000L, [pixel(0.0, 1.0)]))
  let transform = @types.PixelTransform::new(
    scale_x=2.0,
    scale_y=0.5,
    offset_x=4.0,
    offset_y=-2.0,
  )
  let adapted = original.reframed(transform)
  assert_eq(
    @debug.to_string(adapted.checkpoint().transit),
    @debug.to_string(original.checkpoint().transit),
  )
  assert_eq(
    @debug.to_string(transit_motion(adapted.checkpoint())),
    @debug.to_string(transit_motion(original.checkpoint())),
  )
  let restored = @analysis.EvidenceTransitSession::from_checkpoint(
    adapted.checkpoint(),
  )
  for index, y in [3.0, 1.0, -1.0, 1.0, 3.0] {
    let time = (index + 2).to_int64() * 100000L
    let observation = pixel(0.0, y)
    let result = adapted.update_pixel(time, [observation.reframed(transform)])
    let expected = original.update_pixel(time, [observation])
    assert_eq(
      @debug.to_string(result),
      @debug.to_string(
        restored.update_pixel(time, [observation.reframed(transform)]),
      ),
    )
    assert_eq(
      result.transit.counts[0].completed,
      expected.transit.counts[0].completed,
    )
    let a = result.measurement.motion.tracks[0].filtered_state.unwrap()
    let b = expected.measurement.motion.tracks[0].filtered_state.unwrap()
    for i in 0..<4 {
      assert_true((a[i] - b[i]).abs() < 1.0e-9)
    }
  }
}

///|
test "interrupt cancels pending intervals closes hidden segments and keeps totals and next identity" {
  let session = pending_transit()
  ignore(session.update_ground(100001L, [ground(1.0, -1.0, id=2)]))
  assert_eq(transit_motion(session.checkpoint()).tracks.length(), 2)
  let frame = session.interrupt(200000L)
  assert_eq(frame.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(frame.transit.pending_count, 0)
  assert_eq(frame.transit.counting.evidence.length(), 0)
  assert_eq(frame.transit.counting.counting.counts[0].negative_to_positive, 1L)
  assert_eq(transit_motion(session.checkpoint()).next_segment_id, 3L)
  assert_eq(
    session.update_ground(300000L, [ground(0.0, 3.0)]).measurement.motion.tracks[0].segment_id,
    "3",
  )
  assert_eq(session.checkpoint().transit.counts[0].completed, 0L)
  let pixels = @analysis.EvidenceTransitSession::from_pixel(
    pixel_session(),
    session_transit_counter(),
  )
  ignore(pixels.update_pixel(0L, [pixel(0.0, -1.0)]))
  ignore(pixels.update_pixel(100000L, [pixel(0.0, 1.0)]))
  let closed = pixels.interrupt(200000L)
  assert_eq(closed.transit.cancellations[0].reason, @transit.Discontinuity)
  assert_eq(closed.measurement.motion.closed_segment_ids, ["1"])
}

///|
test "constructor checkpoints output arrays and forks are detached across all transit state containers" {
  let measurement = @motion.MotionEstimator::new("analysis", transit_config())
  let counter = session_transit_counter()
  let session = @analysis.EvidenceTransitSession::from_ground(
    measurement, counter,
  )
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(100000L, [ground(0.0, 1.0)]))
  let saved = session.checkpoint()
  let branch = session.fork()
  let restored = @analysis.EvidenceTransitSession::from_checkpoint(saved)
  let before = @debug.to_string(session.checkpoint())
  saved.transit.counting.tracks[0].anchors.clear()
  saved.transit.pending.clear()
  saved.transit.sections.clear()
  saved.transit.counts.clear()
  transit_motion(saved).tracks[0].state[0] = 999.0
  ignore(counter.update(measurement.update(0L, [ground(2.0, -1.0)])))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(@debug.to_string(restored.checkpoint()), before)
  let frame = branch.update_ground(200000L, [ground(0.0, 3.0)])
  let expected = restored.update_ground(200000L, [ground(0.0, 3.0)])
  assert_eq(@debug.to_string(frame), @debug.to_string(expected))
  frame.transit.passages.clear()
  frame.transit.counts.clear()
  frame.transit.counting.counting.counts.clear()
  frame.measurement.motion.tracks.clear()
  assert_eq(
    @debug.to_string(branch.checkpoint()),
    @debug.to_string(restored.checkpoint()),
  )
}

///|
test "exact maximum clocks and exhausted next segment allocation keep full checkpoints retryable" {
  let session = @analysis.EvidenceTransitSession::from_ground(
    @motion.MotionEstimator::new(
      "analysis",
      @motion.MotionConfig::new(q=1.0e20, gate=1.0e12),
    ),
    session_transit_counter(),
  )
  ignore(session.update_ground(9223372036854775805L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(9223372036854775806L, [ground(0.0, 1.0)]))
  let result = session.update_ground(9223372036854775807L, [ground(0.0, 3.0)])
  assert_eq(result.transit.passages[0].elapsed_upper_us, 2L)
  assert_true(result.transit.passages[0].estimated_elapsed_us > 0.0)
  ignore(
    @analysis.EvidenceTransitSession::from_checkpoint(session.checkpoint()),
  )
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.interrupt(9223372036854775807L)))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let fresh = transit_ground()
  ignore(fresh.update_ground(0L, []))
  let saved = fresh.checkpoint()
  let exhausted = @analysis.EvidenceTransitSession::from_checkpoint({
    ..saved,
    measurement: Ground({
      ..transit_motion(saved),
      next_segment_id: 9223372036854775807L,
    }),
  })
  let empty = @debug.to_string(exhausted.checkpoint())
  invalid(() => ignore(exhausted.update_ground(1L, [ground(0.0, -1.0)])))
  assert_eq(@debug.to_string(exhausted.checkpoint()), empty)
  ignore(exhausted.update_ground(1L, []))
}

///|
test "pending confirmation expiry uses the original timestamp through uncertain frames" {
  let session = transit_ground(ttl=200000L)
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(100000L, [ground(0.0, 1.0)]))
  let saved = session.checkpoint()
  let retained = session.update_ground(200000L, [ground(0.0, 0.0)])
  assert_eq(retained.transit.pending_count, 1)
  assert_eq(retained.transit.counting.evidence[0].side, 0)
  assert_eq(
    session.checkpoint().transit.pending[0].entry.to_timestamp_us,
    100000L,
  )
  let restored = @analysis.EvidenceTransitSession::from_checkpoint(
    session.checkpoint(),
  )
  let expired = restored.update_ground(300000L, [ground(0.0, 0.0)])
  assert_eq(expired.transit.cancellations[0].reason, @transit.Expired)
  assert_eq(expired.transit.pending_count, 0)
  assert_eq(saved.transit.pending.length(), 1)
}
