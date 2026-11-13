///|
fn consumer_evidence_transit(
  source : @events.EvidenceGateCheckpoint,
) -> @transit.EvidenceTransitCounter raise @moonground.GroundError {
  @transit.EvidenceTransitCounter::new(
    @events.EvidenceGateCounter::from_checkpoint(source),
    [
      @transit.Section::new(
        "aisle",
        "entry",
        @events.PositiveToNegative,
        "exit",
        @events.PositiveToNegative,
      ),
    ],
  )
}

///|
test "packaged evidence transit stores original covariance witnesses across recovery and fork" {
  let motion = @motion.MotionEstimator::new(
    "consumer-evidence-transit",
    @moonground.MotionConfig::new(q=1000000.0, gate=1.0e12, max_tracks=10),
  )
  let counter = @transit.EvidenceTransitCounter::new(
    @events.EvidenceGateCounter::new(
      "consumer-evidence-transit",
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
  let observe = (y : Double, covariance : @moonground.Covariance2) => {
    @moonground.GroundObservation::new(7, { x: 5.0, y, }, covariance)
  }
  let before = motion.update(0L, [
    observe(-1.0, @moonground.Covariance2::new(0.04, 0.01, 0.01)),
  ])
  ignore(counter.update(before))
  let entry = motion.update(100000L, [
    observe(1.0, @moonground.Covariance2::new(0.01, -0.002, 0.04)),
  ])
  assert_eq(counter.update(entry).pending_count, 1)
  let saved = counter.checkpoint()
  assert_eq(saved.counting.sigma_multiplier, 2.5)
  assert_eq(
    @debug.to_string(saved.pending[0].from_covariance),
    @debug.to_string(before.tracks[0].position_covariance.unwrap()),
  )
  assert_eq(
    @debug.to_string(saved.pending[0].to_covariance),
    @debug.to_string(entry.tracks[0].position_covariance.unwrap()),
  )
  let resumed = @transit.EvidenceTransitCounter::from_checkpoint(saved)
  let forked = resumed.fork()
  saved.pending.clear()
  assert_eq(resumed.checkpoint().pending.length(), 1)
  let exit = motion.update(200000L, [
    observe(3.0, @moonground.Covariance2::isotropic(0.01)),
  ])
  let actual = resumed.update(exit)
  assert_eq(actual.passages.length(), 1)
  assert_eq(actual.counts[0].completed, 1L)
  assert_eq(actual.passages[0].elapsed_upper_us, 200000L)
  assert_eq(actual.pending_count, 0)
  assert_eq(@debug.to_string(actual), @debug.to_string(forked.update(exit)))
  assert_eq(counter.checkpoint().pending.length(), 1)
}

///|
test "packaged Brown evidence guard blockage cancels restored evidence transit pending" {
  let (session, landmarks, left, middle, right) = consumer_evidence_guarded(
    @health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  let downstream = consumer_evidence_transit(
    session.checkpoint().analysis.counting,
  )
  ignore(
    downstream.update(
      session.update(0L, landmarks, [left]).analysis.measurement.motion,
    ),
  )
  assert_eq(
    downstream.update(
      session.update(100000L, landmarks, [middle]).analysis.measurement.motion,
    ).pending_count,
    1,
  )
  let resumed = @transit.EvidenceTransitCounter::from_checkpoint(
    downstream.checkpoint(),
  )
  let blocked = session.update(200000L, [], [right])
  assert_eq(blocked.decision, @guarded.Blocked)
  let cancelled = resumed.update(blocked.analysis.measurement.motion)
  assert_eq(cancelled.cancellations[0].reason, @transit.Discontinuity)
  assert_eq(cancelled.pending_count, 0)
  let reactivated = session.update(300000L, landmarks, [right])
  assert_eq(reactivated.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(
    resumed.update(reactivated.analysis.measurement.motion).passages.length(),
    0,
  )
  assert_eq(resumed.checkpoint().counting.sigma_multiplier, 3.0)
  assert_eq(downstream.checkpoint().pending.length(), 1)
}

///|
test "packaged projection replacement barrier clears evidence transit before new coordinates" {
  let (session, landmarks, left, middle, _) = consumer_evidence_guarded(
    @health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  let downstream = consumer_evidence_transit(
    session.checkpoint().analysis.counting,
  )
  ignore(
    downstream.update(
      session.update(0L, landmarks, [left]).analysis.measurement.motion,
    ),
  )
  assert_eq(
    downstream.update(
      session.update(100000L, landmarks, [middle]).analysis.measurement.motion,
    ).pending_count,
    1,
  )
  let saved = downstream.checkpoint()
  let resumed = @transit.EvidenceTransitCounter::from_checkpoint(saved)
  let replacement = @moonground.GroundCalibration::from_homography(
    [0.025, 0.0, 0.0, 0.0, 0.025, 0.0, 0.0, 0.0, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 640.0, y: 0.0, },
      { x: 640.0, y: 480.0, },
      { x: 0.0, y: 480.0, },
    ],
    ground_noise_floor_m=0.015,
  )
  let barrier = session.replace_projection(150000L, replacement, camera=None)
  assert_eq(barrier.analysis.measurement.motion.closed_segment_ids, ["1"])
  let result = resumed.update(barrier.analysis.measurement.motion)
  assert_eq(result.cancellations[0].reason, @transit.Discontinuity)
  assert_eq(result.pending_count, 0)
  assert_eq(result.counts[0].completed, 0L)
  assert_eq(resumed.checkpoint().counting.sigma_multiplier, 3.0)
  assert_eq(saved.pending.length(), 1)
  assert_eq(resumed.checkpoint().counting.last_timestamp_us, Some(150000L))
  assert_eq(
    @debug.to_string(
      @transit.EvidenceTransitCounter::from_checkpoint(resumed.checkpoint()).checkpoint(),
    ),
    @debug.to_string(resumed.checkpoint()),
  )
}
