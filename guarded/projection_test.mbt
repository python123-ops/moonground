///|
fn replacement(
  scale~ : Double = 2.0,
  extent~ : Double = 5.0,
  noise~ : Double = 0.2,
) -> @moonground.GroundCalibration raise @types.GroundError {
  @moonground.GroundCalibration::from_homography(
    [scale, 0.0, 0.0, 0.0, scale, 0.0, 0.0, 0.0, 1.0],
    [
      { x: -extent, y: -extent, },
      { x: extent, y: -extent, },
      { x: extent, y: extent, },
      { x: -extent, y: extent, },
    ],
    max_meters_per_pixel=scale + 1.0,
    ground_noise_floor_m=noise,
  )
}

///|
fn scaled_landmarks(
  scale : Double,
) -> Array[@health.LandmarkObservation] raise @types.GroundError {
  landmarks().map(item => {
    @health.LandmarkObservation::new(
      item.landmark_id,
      { x: item.pixel.x / scale, y: item.pixel.y / scale, },
      item.covariance,
    )
  })
}

///|
fn immediate() -> @guarded.GuardedSession raise @types.GroundError {
  @guarded.GuardedSession::new(
    analysis(),
    monitor(
      config=@health.HealthConfig::new(confirmation_us=0L, min_observations=1),
    ),
  )
}

///|
fn brown_model() -> @moonground.CameraModel raise @types.GroundError {
  @moonground.CameraModel::new(
    fx=600.0,
    fy=580.0,
    cx=320.0,
    cy=240.0,
    k1=-0.12,
    k2=0.015,
    p1=0.001,
    p2=-0.002,
    k3=0.001,
    max_normalized_radius=0.8,
  )
}

///|
fn brown_calibration() -> @moonground.GroundCalibration raise @types.GroundError {
  @moonground.GroundCalibration::from_homography(
    [0.02, 0.0, 0.0, 0.0, 0.02, 0.0, 0.0, 0.0, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 640.0, y: 0.0, },
      { x: 640.0, y: 480.0, },
      { x: 0.0, y: 480.0, },
    ],
    ground_noise_floor_m=0.01,
  )
}

///|
// Forward Brown fixture coordinates for the retained metric references
// (0,0), (1,0), (0,1); production performs the inverse camera projection.
fn brown_landmarks() -> Array[@health.LandmarkObservation] raise @types.GroundError {
  let covariance = @types.Covariance2::isotropic(0.1)
  [
    @health.LandmarkObservation::new(
      "a",
      { x: 15.50613315569342, y: 12.30399024859068, },
      covariance,
    ),
    @health.LandmarkObservation::new(
      "b",
      { x: 60.817902203522635, y: 10.231313129250935, },
      covariance,
    ),
    @health.LandmarkObservation::new(
      "c",
      { x: 13.344441665097463, y: 58.42960837750746, },
      covariance,
    ),
  ]
}

///|
fn brown_ready() -> @guarded.GuardedSession raise @types.GroundError {
  let session = fresh()
  ignore(
    session.replace_projection(
      0L,
      brown_calibration(),
      camera=Some(brown_model()),
    ),
  )
  ignore(session.update(100000L, brown_landmarks(), []))
  ignore(
    session.update(200000L, brown_landmarks(), [
      @moonground.PixelObservation::new(
        1,
        { x: 36.953182470782224, y: 34.26313959170113, },
        @types.Covariance2::isotropic(0.1),
      ),
    ]),
  )
  session
}

///|
test "an unstarted replacement installs both projections at one insufficient empty barrier" {
  let session = fresh()
  let projection = replacement()
  let frame = session.replace_projection(0L, projection, camera=None)
  assert_eq(frame.decision, @guarded.Blocked)
  assert_eq(frame.suppressed_track_ids, [])
  assert_eq(frame.health.status, @health.Insufficient)
  assert_eq(frame.health.evidence, @health.Insufficient)
  assert_eq(frame.health.streak_since_us, None)
  assert_eq(frame.health.streak_observations, 0)
  assert_eq(frame.health.usable_count, 0)
  assert_eq(frame.health.landmarks.length(), 3)
  assert_true(
    frame.health.landmarks.all(item => item.rejection_reason == Some("missing")),
  )
  assert_eq(frame.analysis.measurement.motion.tracks.length(), 0)
  assert_eq(frame.analysis.measurement.motion.closed_segment_ids, [])
  let snapshot = session.checkpoint()
  let pixel = pixel_checkpoint(snapshot)
  assert_true(pixel.calibration.same_projection(projection))
  assert_true(snapshot.health.calibration.same_projection(projection))
  assert_eq(pixel.motion.last_timestamp_us, Some(0L))
  assert_eq(snapshot.health.last_timestamp_us, Some(0L))
  assert_eq(snapshot.analysis.counting.last_timestamp_us, Some(0L))
  assert_eq(pixel.motion.next_segment_id, 1L)
  assert_true(snapshot.health.streak is None)
  ignore(@guarded.GuardedSession::from_checkpoint(snapshot))
}

///|
test "replacement closes hidden active filters and retains exact totals identities and configurations" {
  let session = fresh()
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0), pixel(2, -1.0)]))
  ignore(session.update(200000L, landmarks(), [pixel(1, 1.0)]))
  let before = session.checkpoint()
  let frame = session.replace_projection(250000L, replacement(), camera=None)
  let after = session.checkpoint()
  assert_eq(frame.analysis.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(frame.analysis.measurement.projection_failures.length(), 0)
  assert_eq(frame.analysis.counting.crossings.length(), 0)
  assert_eq(frame.analysis.counting.counts[0].negative_to_positive, 1L)
  assert_eq(pixel_checkpoint(after).motion.tracks.length(), 0)
  assert_eq(after.analysis.counting.tracks.length(), 0)
  assert_eq(pixel_checkpoint(after).motion.next_segment_id, 3L)
  assert_eq(
    pixel_checkpoint(after).motion.session_id,
    pixel_checkpoint(before).motion.session_id,
  )
  assert_eq(
    @debug.to_string(pixel_checkpoint(after).motion.config),
    @debug.to_string(pixel_checkpoint(before).motion.config),
  )
  assert_eq(
    @debug.to_string(after.analysis.counting.config),
    @debug.to_string(before.analysis.counting.config),
  )
  assert_eq(
    @debug.to_string(after.analysis.counting.gates),
    @debug.to_string(before.analysis.counting.gates),
  )
  assert_eq(
    @debug.to_string(after.health.config),
    @debug.to_string(before.health.config),
  )
  assert_eq(
    @debug.to_string(after.health.landmarks),
    @debug.to_string(before.health.landmarks),
  )
}

///|
test "new projection evidence reconfirms before a fresh object segment warms up" {
  let session = fresh()
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100000L, landmarks(), [pixel(1, -1.0)]))
  ignore(session.update(200000L, landmarks(), [pixel(1, 1.0)]))
  ignore(session.replace_projection(250000L, replacement(), camera=None))
  let pending = session.update(300000L, scaled_landmarks(2.0), [pixel(1, -0.5)])
  assert_eq(pending.decision, @guarded.Blocked)
  assert_eq(pending.health.status, @health.Pending)
  assert_eq(pending.health.streak_since_us, Some(300000L))
  let allowed = session.update(400000L, scaled_landmarks(2.0), [pixel(1, 0.5)])
  assert_eq(allowed.decision, @guarded.Allowed)
  assert_eq(allowed.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(allowed.analysis.measurement.motion.tracks[0].accepted_count, 1)
  assert_eq(
    allowed.analysis.measurement.motion.tracks[0].observed_path_length_m,
    0.0,
  )
  assert_eq(allowed.analysis.measurement.motion.tracks[0].speed_mps, None)
  assert_eq(allowed.analysis.counting.crossings.length(), 0)
  assert_eq(allowed.analysis.counting.counts[0].negative_to_positive, 1L)
  ignore(@guarded.GuardedSession::from_checkpoint(session.checkpoint()))
}

///|
test "equal projection replacement still resets every old evidence streak" {
  let session = immediate()
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  let reset = session.replace_projection(1L, calibration(), camera=None)
  assert_eq(reset.analysis.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(reset.health.status, @health.Insufficient)
  let repeated = session.replace_projection(2L, calibration(), camera=None)
  assert_eq(repeated.health.status, @health.Insufficient)
  assert_eq(repeated.analysis.measurement.motion.closed_segment_ids, [])
  assert_eq(pixel_checkpoint(session.checkpoint()).motion.next_segment_id, 2L)
}

///|
test "zero-span one-sample confirmation still needs a later observed frame" {
  let session = immediate()
  let reset = session.replace_projection(0L, calibration(), camera=None)
  assert_eq(reset.health.status, @health.Insufficient)
  assert_eq(reset.health.streak_observations, 0)
  invalid(() => ignore(session.update(0L, landmarks(), [pixel(1, -1.0)])))
  assert_eq(
    session.update(1L, landmarks(), [pixel(1, -1.0)]).decision,
    @guarded.Allowed,
  )
  assert_eq(
    pixel_checkpoint(session.checkpoint()).motion.tracks[0].first_timestamp_us,
    1L,
  )
}

///|
test "invalid replacement time leaves old projection all filters health and counters unchanged" {
  let session = immediate()
  ignore(session.update(100L, landmarks(), [pixel(1, -1.0)]))
  let before = @debug.to_string(session.checkpoint())
  for time in [-1L, 0L, 99L, 100L] {
    invalid(() => {
      ignore(
        session.replace_projection(
          time,
          replacement(),
          camera=Some(brown_model()),
        ),
      )
    })
    assert_eq(@debug.to_string(session.checkpoint()), before)
  }
  let unchanged = session.update(101L, landmarks(), [pixel(1, 3.0)])
  assert_eq(unchanged.decision, @guarded.Allowed)
  assert_eq(unchanged.analysis.counting.counts[0].negative_to_positive, 1L)
}

///|
test "replacement and the next fresh segment preserve exact maximum Int64 timestamps" {
  let session = immediate()
  let end = 9223372036854775807L
  ignore(session.update(end - 2L, landmarks(), [pixel(1, -1.0)]))
  let reset = session.replace_projection(end - 1L, calibration(), camera=None)
  assert_eq(reset.health.timestamp_us, end - 1L)
  let last = session.update(end, landmarks(), [pixel(1, 1.0)])
  assert_eq(last.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(
    last.analysis.measurement.motion.tracks[0].last_accepted_timestamp_us,
    end,
  )
  ignore(@guarded.GuardedSession::from_checkpoint(session.checkpoint()))
  let before = @debug.to_string(session.checkpoint())
  invalid(() => {
    ignore(session.replace_projection(end, replacement(), camera=None))
  })
  assert_eq(@debug.to_string(session.checkpoint()), before)
}

///|
test "replacement preserves exhausted segment allocation and a failed later frame can retry" {
  let original = immediate()
  ignore(original.update(0L, landmarks(), [pixel(1, -1.0)]))
  let snapshot = original.checkpoint()
  let pixel_state = pixel_checkpoint(snapshot)
  let exhausted = @guarded.GuardedSession::from_checkpoint({
    ..snapshot,
    analysis: {
      ..snapshot.analysis,
      measurement: @analysis.Pixel({
        ..pixel_state,
        motion: { ..pixel_state.motion, next_segment_id: 9223372036854775807L, },
      }),
    },
  })
  ignore(exhausted.replace_projection(1L, calibration(), camera=None))
  assert_eq(
    pixel_checkpoint(exhausted.checkpoint()).motion.next_segment_id,
    9223372036854775807L,
  )
  let before = @debug.to_string(exhausted.checkpoint())
  invalid(() => ignore(exhausted.update(2L, landmarks(), [pixel(1, -1.0)])))
  assert_eq(@debug.to_string(exhausted.checkpoint()), before)
  assert_eq(exhausted.update(2L, landmarks(), []).decision, @guarded.Allowed)
}

///|
test "replacement can install a full Brown model without changing known ground landmarks" {
  let session = brown_ready()
  let snapshot = session.checkpoint()
  assert_eq(snapshot.health.streak.unwrap().since_us, 100000L)
  assert_eq(snapshot.health.landmarks[1].ground_m.x, 1.0)
  let object = pixel_checkpoint(snapshot).motion.tracks[0]
  assert_true((object.last_filtered.x - 0.5).abs() < 1.0e-8)
  assert_true((object.last_filtered.y - 0.5).abs() < 1.0e-8)
  assert_eq(
    pixel_checkpoint(snapshot).camera.unwrap().parameters(),
    brown_model().parameters(),
  )
  assert_eq(
    snapshot.health.camera.unwrap().parameters(),
    brown_model().parameters(),
  )
  ignore(@guarded.GuardedSession::from_checkpoint(snapshot))
}

///|
test "explicit None removes the Brown model and later pixels use the new convention" {
  let session = brown_ready()
  let reset = session.replace_projection(
    250000L,
    brown_calibration(),
    camera=None,
  )
  assert_eq(reset.analysis.measurement.motion.closed_segment_ids, ["1"])
  let refs = scaled_landmarks(0.02)
  ignore(session.update(300000L, refs, []))
  let ready = session.update(400000L, refs, [pixel(1, 25.0, x=25.0)])
  assert_eq(ready.decision, @guarded.Allowed)
  assert_eq(ready.analysis.measurement.motion.tracks[0].segment_id, "2")
  let point = ready.analysis.measurement.motion.tracks[0].position.unwrap()
  assert_true((point.x - 0.5).abs() < 1.0e-12)
  assert_true((point.y - 0.5).abs() < 1.0e-12)
  assert_true(pixel_checkpoint(session.checkpoint()).camera is None)
  assert_true(session.checkpoint().health.camera is None)
}

///|
test "new ROI scale and noise apply after the barrier without changing gate metres" {
  let session = immediate()
  let projection = replacement(extent=0.75)
  ignore(session.replace_projection(0L, projection, camera=None))
  let result = session.update(100000L, scaled_landmarks(2.0), [
    pixel(1, 0.25),
    pixel(2, 2.0),
  ])
  assert_eq(result.decision, @guarded.Allowed)
  assert_eq(result.analysis.measurement.projection_failures[0].track_id, 2)
  assert_eq(result.analysis.measurement.motion.tracks.length(), 1)
  assert_true(
    (result.analysis.measurement.motion.tracks[0].position.unwrap().y - 0.5).abs() <
    1.0e-12,
  )
  assert_true(
    (result.analysis.measurement.motion.tracks[0].position_covariance.unwrap().xx -
    0.0404).abs() <
    1.0e-12,
  )
  let snapshot = session.checkpoint()
  assert_true(
    pixel_checkpoint(snapshot).calibration.same_projection(projection),
  )
  assert_eq(snapshot.analysis.counting.gates[0].start_m.x, -5.0)
  assert_eq(snapshot.analysis.counting.gates[0].deadband_m, 0.1)
}

///|
test "replacement forks checkpoints and pixel reframing keep independent configuration bindings" {
  let original = immediate()
  ignore(original.update(0L, landmarks(), [pixel(1, -1.0)]))
  let before = @debug.to_string(original.checkpoint())
  let branch = original.fork()
  ignore(branch.replace_projection(1L, replacement(), camera=None))
  assert_eq(@debug.to_string(original.checkpoint()), before)
  let snapshot = branch.checkpoint()
  let restored = @guarded.GuardedSession::from_checkpoint(snapshot)
  invalid(() => {
    ignore(
      @guarded.GuardedSession::from_checkpoint({
        ..snapshot,
        health: { ..snapshot.health, calibration: calibration(), },
      }),
    )
  })
  snapshot.health.landmarks.clear()
  snapshot.analysis.counting.gates.clear()
  let transform = @types.PixelTransform::new(
    scale_x=0.5,
    scale_y=0.75,
    offset_x=-4.0,
    offset_y=2.0,
  )
  let reframed = restored.reframed(transform)
  let refs = scaled_landmarks(2.0).map(item => item.reframed(transform))
  let object = pixel(1, 0.5).reframed(transform)
  let allowed = reframed.update(2L, refs, [object])
  assert_eq(allowed.decision, @guarded.Allowed)
  assert_eq(allowed.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_true(
    (allowed.analysis.measurement.motion.tracks[0].position.unwrap().y - 1.0).abs() <
    1.0e-12,
  )
  assert_eq(branch.checkpoint().health.last_timestamp_us, Some(1L))
  assert_eq(restored.checkpoint().health.last_timestamp_us, Some(1L))
  ignore(@guarded.GuardedSession::from_checkpoint(reframed.checkpoint()))
}

///|
test "a replacement barrier cancels downstream pending transit without resetting its totals" {
  let gates = @events.GateCounter::new(
    "guarded",
    [
      @events.LineGate::new("entry", { x: -5.0, y: 0.0, }, { x: 5.0, y: 0.0, }),
      @events.LineGate::new("exit", { x: -5.0, y: 2.0, }, { x: 5.0, y: 2.0, }),
    ],
    @events.GateConfig::new(max_tracks=10),
  )
  let analysis = @analysis.AnalysisSession::from_pixel(
    @moonground.MeasurementSession::new(
      "guarded",
      calibration(),
      @moonground.MotionConfig::new(max_tracks=10, gate=1.0e12),
    ),
    gates,
  )
  let session = @guarded.GuardedSession::new(
    analysis,
    monitor(
      config=@health.HealthConfig::new(confirmation_us=0L, min_observations=1),
    ),
  )
  let transit = @transit.TransitCounter::new(gates, [
    @transit.Section::new(
      "aisle",
      "entry",
      @events.NegativeToPositive,
      "exit",
      @events.NegativeToPositive,
    ),
  ])
  ignore(
    transit.update(
      session.update(0L, landmarks(), [pixel(1, -1.0)]).analysis.measurement.motion,
    ),
  )
  assert_eq(
    transit.update(
      session.update(100000L, landmarks(), [pixel(1, 1.0)]).analysis.measurement.motion,
    ).pending_count,
    1,
  )
  let barrier = session.replace_projection(200000L, calibration(), camera=None)
  let cancelled = transit.update(barrier.analysis.measurement.motion)
  assert_eq(cancelled.cancellations[0].reason, @transit.Discontinuity)
  assert_eq(cancelled.pending_count, 0)
  assert_eq(cancelled.counting.counts[0].negative_to_positive, 1L)
  let exit_only = transit.update(
    session.update(300000L, landmarks(), [pixel(1, 3.0)]).analysis.measurement.motion,
  )
  assert_eq(exit_only.passages.length(), 0)
  assert_eq(exit_only.counts[0].completed, 0L)
}
