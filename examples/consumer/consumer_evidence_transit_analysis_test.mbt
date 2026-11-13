///|
fn consumer_transit_analysis_counter(
  session_id : String,
) -> @transit.EvidenceTransitCounter raise @moonground.GroundError {
  @transit.EvidenceTransitCounter::new(
    @events.EvidenceGateCounter::new(
      session_id,
      [
        @events.LineGate::new("entry", { x: 0.0, y: 0.0, }, { x: 10.0, y: 0.0, }),
        @events.LineGate::new("exit", { x: 0.0, y: 2.0, }, { x: 10.0, y: 2.0, }),
      ],
      @events.GateConfig::new(max_tracks=10),
      sigma_multiplier=2.5,
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
  )
}

///|
fn consumer_transit_analysis_observation(
  track_id : Int32,
  y : Double,
) -> @moonground.GroundObservation raise @moonground.GroundError {
  @moonground.GroundObservation::new(
    track_id,
    { x: 5.0, y, },
    @moonground.Covariance2::isotropic(0.01),
  )
}

///|
test "packaged atomic evidence transit preserves motion covariance paths and new IDs on late overflow" {
  let session = @analysis.EvidenceTransitSession::from_ground(
    @motion.MotionEstimator::new(
      "consumer-transit-analysis-overflow",
      @moonground.MotionConfig::new(q=1000000.0, gate=1.0e12, max_tracks=10),
    ),
    consumer_transit_analysis_counter("consumer-transit-analysis-overflow"),
  )
  ignore(
    session.update_ground(0L, [consumer_transit_analysis_observation(7, -1.0)]),
  )
  let saved = session.checkpoint()
  let exhausted = @analysis.EvidenceTransitSession::from_checkpoint({
    ..saved,
    transit: {
      ..saved.transit,
      counting: {
        ..saved.transit.counting,
        counts: [
          {
            ..saved.transit.counting.counts[0],
            negative_to_positive: 9223372036854775807L,
          },
          saved.transit.counting.counts[1],
        ],
      },
    },
  })
  let before = @debug.to_string(exhausted.checkpoint())
  try
    exhausted.update_ground(100000L, [
      consumer_transit_analysis_observation(7, 1.0),
      consumer_transit_analysis_observation(9, -1.0),
    ])
  catch {
    _ => ()
  } noraise {
    _ => fail("evidence overflow must roll back measurement and transit")
  }
  assert_eq(@debug.to_string(exhausted.checkpoint()), before)
  let retry = exhausted.update_ground(100000L, [
    consumer_transit_analysis_observation(7, -2.0),
    consumer_transit_analysis_observation(9, -1.0),
  ])
  assert_eq(retry.measurement.motion.tracks[0].accepted_count, 2)
  assert_eq(retry.measurement.motion.tracks[1].segment_id, "2")
  assert_eq(
    retry.transit.counting.counting.counts[0].negative_to_positive,
    9223372036854775807L,
  )
  let restored = @analysis.EvidenceTransitSession::from_checkpoint(
    exhausted.checkpoint(),
  )
  let observations = [
    consumer_transit_analysis_observation(7, -2.0),
    consumer_transit_analysis_observation(9, -1.0),
  ]
  assert_eq(
    @debug.to_string(exhausted.update_ground(200000L, observations)),
    @debug.to_string(restored.update_ground(200000L, observations)),
  )
}

///|
test "packaged Brown atomic transit reframes a warm pending journey and restores all three states" {
  let (legacy, gates, _, left, middle, right) = consumer_brown_guarded()
  guard legacy.checkpoint().analysis.measurement is Pixel(pixel) else {
    fail("pixel fixture missing")
  }
  let definition = gates.checkpoint()
  let session = @analysis.EvidenceTransitSession::from_pixel(
    @moonground.MeasurementSession::from_checkpoint(pixel),
    @transit.EvidenceTransitCounter::new(
      @events.EvidenceGateCounter::new(
        definition.session_id,
        definition.gates,
        definition.config,
        sigma_multiplier=3.0,
      ),
      [
        @transit.Section::new(
          "aisle",
          "entry",
          @events.PositiveToNegative,
          "exit",
          @events.PositiveToNegative,
        ),
      ],
    ),
  )
  ignore(session.update_pixel(0L, [left]))
  assert_eq(session.update_pixel(100000L, [middle]).transit.pending_count, 1)
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=1.25,
    offset_x=-15.0,
    offset_y=8.0,
  )
  let adapted = session.reframed(transform)
  let saved = adapted.checkpoint()
  assert_eq(
    @debug.to_string(saved.transit),
    @debug.to_string(session.checkpoint().transit),
  )
  let restored = @analysis.EvidenceTransitSession::from_checkpoint(saved)
  let expected = session.update_pixel(200000L, [right])
  let actual = adapted.update_pixel(200000L, [right.reframed(transform)])
  assert_eq(
    @debug.to_string(actual),
    @debug.to_string(
      restored.update_pixel(200000L, [right.reframed(transform)]),
    ),
  )
  assert_eq(actual.transit.passages.length(), 1)
  assert_eq(actual.transit.counts[0].completed, 1L)
  assert_eq(
    actual.transit.passages[0].elapsed_lower_us,
    expected.transit.passages[0].elapsed_lower_us,
  )
  assert_true(
    (actual.transit.passages[0].estimated_elapsed_us -
    expected.transit.passages[0].estimated_elapsed_us).abs() <
    1.0e-6,
  )
  assert_true(
    (actual.measurement.motion.tracks[0].position.unwrap().x -
    expected.measurement.motion.tracks[0].position.unwrap().x).abs() <
    1.0e-8,
  )
  assert_eq(saved.transit.pending.length(), 1)
  assert_eq(saved.transit.counting.sigma_multiplier, 3.0)
}

///|
test "packaged atomic transit interruption closes hidden motion and cancels pending without losing totals" {
  let session = @analysis.EvidenceTransitSession::from_ground(
    @motion.MotionEstimator::new(
      "consumer-transit-analysis-interrupt",
      @moonground.MotionConfig::new(q=1000000.0, gate=1.0e12, max_tracks=10),
    ),
    consumer_transit_analysis_counter("consumer-transit-analysis-interrupt"),
  )
  ignore(
    session.update_ground(0L, [
      consumer_transit_analysis_observation(1, -1.0),
      consumer_transit_analysis_observation(2, -1.0),
    ]),
  )
  assert_eq(
    session.update_ground(100000L, [
      consumer_transit_analysis_observation(1, 1.0),
    ]).transit.pending_count,
    1,
  )
  let branch = session.fork()
  let interrupted = session.interrupt(150000L)
  assert_eq(interrupted.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(interrupted.transit.cancellations[0].reason, @transit.Discontinuity)
  assert_eq(interrupted.transit.pending_count, 0)
  assert_eq(interrupted.transit.counts[0].completed, 0L)
  assert_eq(
    session.checkpoint().transit.counting.counts[0].negative_to_positive,
    1L,
  )
  assert_eq(branch.checkpoint().transit.pending.length(), 1)
  let restored = @analysis.EvidenceTransitSession::from_checkpoint(
    session.checkpoint(),
  )
  let resumed = restored.update_ground(200000L, [
    consumer_transit_analysis_observation(1, 3.0),
  ])
  assert_eq(resumed.measurement.motion.tracks[0].segment_id, "3")
  assert_eq(resumed.measurement.motion.tracks[0].accepted_count, 1)
  assert_eq(resumed.measurement.motion.tracks[0].observed_path_length_m, 0.0)
  assert_eq(resumed.transit.passages.length(), 0)
}
