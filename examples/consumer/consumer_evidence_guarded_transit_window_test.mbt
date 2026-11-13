///|
test "packaged health windows discard origin failure and late first healthy evidence failure" {
  let (guarded, landmarks, left, _, _) = consumer_guarded_transit(
    @health.HealthConfig::new(confirmation_us=0L, min_observations=3),
    multiplier=1.0e308,
  )
  let session = @guarded.EvidenceGuardedTransitWindowSession::new(
    guarded,
    window_us=1000000L,
    duration_limits_us=[0L, 200000L, 9223372036854775807L],
    origin_us=100L,
  )
  let before = @debug.to_string(session.checkpoint())
  try session.update(99L, landmarks, [left]) catch {
    _ => ()
  } noraise {
    _ => fail("window origin must discard the blocked health candidate")
  }
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let first = session.update(100L, landmarks, [left])
  assert_eq(first.guarded.decision, @guarded.Blocked)
  assert_eq(first.guarded.health.streak_observations, 1)
  assert_eq(first.windows.current_window.input_frames, 1L)
  ignore(session.update(200L, landmarks, [left]))
  let saved = @debug.to_string(session.checkpoint())
  let large = {
    ..left,
    covariance: @moonground.Covariance2::isotropic(1000.0),
  }
  try session.update(300L, landmarks, [large]) catch {
    _ => ()
  } noraise {
    _ =>
      fail(
        "normal overflow must also discard healthy confirmation and statistics",
      )
  }
  assert_eq(@debug.to_string(session.checkpoint()), saved)
  assert_eq(session.checkpoint().guarded.health.streak.unwrap().observations, 2)
  let retry = session.update(300L, landmarks, [left])
  assert_eq(retry.guarded.decision, @guarded.Allowed)
  assert_eq(retry.guarded.health.streak_observations, 3)
  assert_eq(retry.guarded.analysis.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(retry.windows.current_window.input_frames, 3L)
  assert_eq(
    @debug.to_string(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
        session.checkpoint(),
      ).checkpoint(),
    ),
    @debug.to_string(session.checkpoint()),
  )
}

///|
test "packaged Brown health windows retain pending on late overflow and warm reframe" {
  let (guarded, landmarks, left, middle, right) = consumer_guarded_transit(
    @health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  let session = @guarded.EvidenceGuardedTransitWindowSession::new(
    guarded,
    window_us=1000000L,
    duration_limits_us=[0L, 200000L, 9223372036854775807L],
  )
  ignore(session.update(0L, landmarks, [left]))
  assert_eq(
    session.update(100000L, landmarks, [middle]).guarded.analysis.transit.pending_count,
    1,
  )
  let saved = session.checkpoint()
  let exhausted = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint({
      ..saved,
      guarded: {
        ..saved.guarded,
        analysis: {
          ..saved.guarded.analysis,
          transit: {
            ..saved.guarded.analysis.transit,
            counting: {
              ..saved.guarded.analysis.transit.counting,
              counts: saved.guarded.analysis.transit.counting.counts.map(count => {
                ..count,
                negative_to_positive: 9223372036854775807L,
                positive_to_negative: 9223372036854775807L,
              }),
            },
          },
        },
      },
    },
  )
  let before = @debug.to_string(exhausted.checkpoint())
  try exhausted.update(200000L, landmarks, [right]) catch {
    _ => ()
  } noraise {
    _ =>
      fail("exit count overflow must preserve health, pending entry and window")
  }
  assert_eq(@debug.to_string(exhausted.checkpoint()), before)
  let retry = exhausted.update(200000L, landmarks, [middle])
  assert_eq(retry.guarded.analysis.transit.pending_count, 1)
  assert_eq(retry.windows.current_window.input_frames, 3L)
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=1.25,
    offset_x=-15.0,
    offset_y=8.0,
  )
  let adapted = session.reframed(transform)
  let changed = adapted.checkpoint()
  assert_eq(@debug.to_string(changed.windows), @debug.to_string(saved.windows))
  assert_eq(
    @debug.to_string(changed.guarded.analysis.transit),
    @debug.to_string(saved.guarded.analysis.transit),
  )
  assert_eq(
    @debug.to_string(changed.guarded.health.streak),
    @debug.to_string(saved.guarded.health.streak),
  )
  let restored = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
    changed,
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
  assert_eq(actual.guarded.analysis.transit.passages.length(), 1)
  assert_eq(actual.windows.current_window.sections[0].completed, 1L)
  assert_eq(
    @debug.to_string(actual.windows),
    @debug.to_string(expected.windows),
  )
}

///|
test "packaged health windows count blockage and cold projection barriers once" {
  let (guarded, landmarks, left, middle, right) = consumer_guarded_transit(
    @health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  let session = @guarded.EvidenceGuardedTransitWindowSession::new(
    guarded,
    window_us=1000000L,
    duration_limits_us=[0L, 200000L, 9223372036854775807L],
  )
  ignore(session.update(0L, landmarks, [left, { ..left, track_id: 9, }]))
  ignore(session.update(100000L, landmarks, [middle]))
  let branch = session.fork()
  let saved = session.checkpoint()
  let blocked = session.update(150000L, [], [right])
  assert_eq(blocked.guarded.decision, @guarded.Blocked)
  assert_eq(blocked.guarded.analysis.measurement.motion.closed_segment_ids, [
    "1", "2",
  ])
  assert_eq(blocked.guarded.analysis.transit.pending_count, 0)
  assert_eq(blocked.windows.current_window.input_frames, 3L)
  assert_eq(
    blocked.windows.current_window.sections[0].cancellations[0].count,
    1L,
  )
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
  assert_eq(barrier.guarded.health.status, @health.Insufficient)
  assert_eq(barrier.guarded.analysis.measurement.motion.closed_segment_ids, [
    "1", "2",
  ])
  assert_eq(barrier.windows.current_window.input_frames, 3L)
  assert_eq(
    barrier.windows.current_window.sections[0].cancellations[0].count,
    1L,
  )
  let checkpoint = branch.checkpoint()
  assert_eq(checkpoint.guarded.analysis.transit.counting.sigma_multiplier, 3.0)
  assert_eq(
    @debug.to_string(checkpoint.windows.baseline_counts),
    @debug.to_string(saved.windows.baseline_counts),
  )
  let cold = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
    checkpoint,
  )
  let fixed = checkpoint.guarded.health.landmarks.map(item => {
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
  assert_eq(restarted.guarded.decision, @guarded.Allowed)
  assert_eq(
    restarted.guarded.analysis.measurement.motion.tracks[0].segment_id,
    "3",
  )
  assert_eq(restarted.guarded.analysis.transit.passages.length(), 0)
  assert_eq(restarted.windows.current_window.input_frames, 4L)
}
