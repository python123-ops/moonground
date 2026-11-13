///|
fn consumer_guarded_transit(
  config : @health.HealthConfig,
  multiplier~ : Double = 3.0,
) -> (
  @guarded.EvidenceGuardedTransitSession,
  Array[@health.LandmarkObservation],
  @moonground.PixelObservation,
  @moonground.PixelObservation,
  @moonground.PixelObservation,
) raise @moonground.GroundError {
  let (legacy, gates, landmarks, left, middle, right) = consumer_brown_guarded()
  let source = legacy.checkpoint()
  guard source.analysis.measurement is Pixel(pixel) else {
    raise @moonground.GroundError::InvalidInput("pixel fixture missing")
  }
  let definition = gates.checkpoint()
  let analysis = @analysis.EvidenceTransitSession::from_pixel(
    @moonground.MeasurementSession::from_checkpoint(pixel),
    @transit.EvidenceTransitCounter::new(
      @events.EvidenceGateCounter::new(
        definition.session_id,
        definition.gates,
        definition.config,
        sigma_multiplier=multiplier,
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
  let health = @health.CalibrationMonitor::new(
    pixel.calibration,
    source.health.landmarks,
    config,
    camera?=pixel.camera,
  )
  (
    @guarded.EvidenceGuardedTransitSession::new(analysis, health),
    landmarks,
    left,
    middle,
    right,
  )
}

///|
test "packaged guarded transit rolls back the sample first confirming healthy after late evidence failure" {
  let (session, landmarks, left, _, _) = consumer_guarded_transit(
    @health.HealthConfig::new(confirmation_us=300000L, min_observations=3),
    multiplier=1.0e308,
  )
  assert_eq(session.update(0L, landmarks, [left]).decision, @guarded.Blocked)
  assert_eq(
    session.update(150000L, landmarks, [left]).health.streak_observations,
    2,
  )
  let before = @debug.to_string(session.checkpoint())
  let large = {
    ..left,
    covariance: @moonground.Covariance2::isotropic(1000.0),
  }
  try session.update(300000L, landmarks, [large]) catch {
    _ => ()
  } noraise {
    _ =>
      fail(
        "normal overflow must discard health confirmation and all downstream state",
      )
  }
  assert_eq(@debug.to_string(session.checkpoint()), before)
  assert_eq(session.checkpoint().health.last_timestamp_us, Some(150000L))
  assert_eq(session.checkpoint().health.streak.unwrap().observations, 2)
  let retry = session.update(300000L, landmarks, [left])
  assert_eq(retry.decision, @guarded.Allowed)
  assert_eq(retry.health.streak_observations, 3)
  assert_eq(retry.analysis.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(retry.analysis.transit.pending_count, 0)
  let restored = @guarded.EvidenceGuardedTransitSession::from_checkpoint(
    session.checkpoint(),
  )
  assert_eq(
    @debug.to_string(restored.checkpoint()),
    @debug.to_string(session.checkpoint()),
  )
}

///|
test "packaged Brown guarded transit warm reframe preserves pending and late count overflow preserves health" {
  let (session, landmarks, left, middle, right) = consumer_guarded_transit(
    @health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  ignore(session.update(0L, landmarks, [left]))
  assert_eq(
    session.update(100000L, landmarks, [middle]).analysis.transit.pending_count,
    1,
  )
  let saved = session.checkpoint()
  let exhausted = @guarded.EvidenceGuardedTransitSession::from_checkpoint({
    ..saved,
    analysis: {
      ..saved.analysis,
      transit: {
        ..saved.analysis.transit,
        counting: {
          ..saved.analysis.transit.counting,
          counts: saved.analysis.transit.counting.counts.map(count => {
            ..count,
            negative_to_positive: 9223372036854775807L,
            positive_to_negative: 9223372036854775807L,
          }),
        },
      },
    },
  })
  let before = @debug.to_string(exhausted.checkpoint())
  try exhausted.update(200000L, landmarks, [right]) catch {
    _ => ()
  } noraise {
    _ => fail("exit count overflow must roll back health and the pending entry")
  }
  assert_eq(@debug.to_string(exhausted.checkpoint()), before)
  assert_eq(
    exhausted.update(200000L, landmarks, [middle]).analysis.transit.pending_count,
    1,
  )
  assert_eq(exhausted.checkpoint().health.last_timestamp_us, Some(200000L))
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=1.25,
    offset_x=-15.0,
    offset_y=8.0,
  )
  let adapted = session.reframed(transform)
  let adapted_checkpoint = adapted.checkpoint()
  assert_eq(
    @debug.to_string(adapted_checkpoint.analysis.transit),
    @debug.to_string(saved.analysis.transit),
  )
  assert_eq(
    @debug.to_string(adapted_checkpoint.health.streak),
    @debug.to_string(saved.health.streak),
  )
  let restored = @guarded.EvidenceGuardedTransitSession::from_checkpoint(
    adapted_checkpoint,
  )
  let converted = landmarks.map(item => item.reframed(transform))
  let actual = adapted.update(200000L, converted, [right.reframed(transform)])
  assert_eq(
    @debug.to_string(actual),
    @debug.to_string(
      restored.update(200000L, converted, [right.reframed(transform)]),
    ),
  )
  let expected = session.update(200000L, landmarks, [right])
  assert_eq(actual.analysis.transit.passages.length(), 1)
  assert_eq(actual.analysis.transit.counts[0].completed, 1L)
  assert_true(
    (actual.analysis.transit.passages[0].estimated_elapsed_us -
    expected.analysis.transit.passages[0].estimated_elapsed_us).abs() <
    1.0e-6,
  )
  assert_eq(saved.analysis.transit.pending.length(), 1)
}

///|
test "packaged guarded transit blockage and projection barrier clear pending and hidden state independently" {
  let (session, landmarks, left, middle, right) = consumer_guarded_transit(
    @health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  let hidden = { ..left, track_id: 9, }
  ignore(session.update(0L, landmarks, [left, hidden]))
  assert_eq(
    session.update(100000L, landmarks, [middle]).analysis.transit.pending_count,
    1,
  )
  let branch = session.fork()
  let saved = session.checkpoint()
  let blocked = session.update(150000L, [], [right])
  assert_eq(blocked.decision, @guarded.Blocked)
  assert_eq(blocked.analysis.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(
    blocked.analysis.transit.cancellations[0].reason,
    @transit.Discontinuity,
  )
  assert_eq(blocked.analysis.transit.pending_count, 0)
  let resumed = @guarded.EvidenceGuardedTransitSession::from_checkpoint(
    session.checkpoint(),
  )
  let after_block = resumed.update(200000L, landmarks, [right])
  assert_eq(after_block.analysis.measurement.motion.tracks[0].segment_id, "3")
  assert_eq(after_block.analysis.transit.passages.length(), 0)
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.025, 0.0, 0.0, 0.0, 0.025, 0.0, 0.0, 0.0, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 640.0, y: 0.0, },
      { x: 640.0, y: 480.0, },
      { x: 0.0, y: 480.0, },
    ],
    ground_noise_floor_m=0.015,
  )
  let barrier = branch.replace_projection(150000L, calibration, camera=None)
  assert_eq(barrier.health.status, @health.Insufficient)
  assert_eq(barrier.analysis.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(
    barrier.analysis.transit.cancellations[0].reason,
    @transit.Discontinuity,
  )
  assert_eq(barrier.analysis.transit.pending_count, 0)
  let replacement = branch.checkpoint()
  assert_eq(replacement.analysis.transit.counting.sigma_multiplier, 3.0)
  assert_eq(
    replacement.analysis.transit.counting.counts[0].positive_to_negative,
    saved.analysis.transit.counting.counts[0].positive_to_negative,
  )
  assert_true(replacement.health.streak is None)
  let cold = @guarded.EvidenceGuardedTransitSession::from_checkpoint(
    replacement,
  )
  let fixed = replacement.health.landmarks.map(item => {
    @health.LandmarkObservation::new(
      item.landmark_id,
      { x: item.ground_m.x / 0.025, y: item.ground_m.y / 0.025, },
      @moonground.Covariance2::isotropic(2.0),
    )
  })
  let observed = @moonground.PixelObservation::new(
    7,
    { x: 6.4 / 0.025, y: 6.0 / 0.025, },
    @moonground.Covariance2::isotropic(2.0),
  )
  let restarted = cold.update(200000L, fixed, [observed])
  assert_eq(restarted.decision, @guarded.Allowed)
  assert_eq(restarted.analysis.measurement.motion.tracks[0].segment_id, "3")
  assert_eq(restarted.analysis.measurement.motion.tracks[0].accepted_count, 1)
  assert_eq(restarted.analysis.transit.passages.length(), 0)
  assert_eq(saved.analysis.transit.pending.length(), 1)
}
