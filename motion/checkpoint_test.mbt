///|
fn checkpoint_rejected(checkpoint : @motion.MotionCheckpoint) -> Unit raise {
  try @motion.MotionEstimator::from_checkpoint(checkpoint) catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid checkpoint was restored")
  }
}

///|
fn checkpoint_fixture() -> @motion.MotionCheckpoint raise @types.GroundError {
  let engine = @motion.MotionEstimator::new(
    "checkpoint",
    @motion.MotionConfig::new(),
  )
  for i in 0..<4 {
    ignore(
      engine.update(Int64::from_int(i) * 100000L, [
        sample(1, i.to_double() / 10.0, 0.0),
      ]),
    )
  }
  engine.checkpoint()
}

///|
struct ResumeFrame {
  timestamp : Int64
  observations : Array[@types.GroundObservation]
  lost : Array[Int32]
  removed : Array[Int32]
}

///|
test "checkpoints resume every lifecycle boundary with identical full outputs" {
  let frames : Array[ResumeFrame] = [
    {
      timestamp: 0L,
      observations: [sample(7, 0.0, 0.0), sample(2, 0.0, 0.0)],
      lost: [],
      removed: [],
    },
    {
      timestamp: 100000L,
      observations: [sample(2, 0.1, 0.0), sample(7, 0.2, 0.0)],
      lost: [],
      removed: [],
    },
    {
      timestamp: 200000L,
      observations: [sample(2, 0.2, 0.0)],
      lost: [],
      removed: [],
    },
    {
      timestamp: 300000L,
      observations: [sample(2, 10000.0, 0.0), sample(7, 0.6, 0.0)],
      lost: [],
      removed: [],
    },
    {
      timestamp: 400000L,
      observations: [sample(2, 0.4, 0.0), sample(7, 0.8, 0.0)],
      lost: [],
      removed: [],
    },
    { timestamp: 500000L, observations: [], lost: [7], removed: [], },
    {
      timestamp: 600000L,
      observations: [sample(7, 1.2, 0.0)],
      lost: [],
      removed: [],
    },
    {
      timestamp: 800000L,
      observations: [sample(2, 0.8, 0.0), sample(7, 1.6, 0.0)],
      lost: [],
      removed: [],
    },
    {
      timestamp: 900000L,
      observations: [sample(7, 1.8, 0.0)],
      lost: [],
      removed: [],
    },
    { timestamp: 1000000L, observations: [], lost: [], removed: [2], },
    {
      timestamp: 1100000L,
      observations: [sample(2, 1.1, 0.0), sample(7, 2.2, 0.0)],
      lost: [],
      removed: [],
    },
    { timestamp: 1400000L, observations: [], lost: [], removed: [], },
    {
      timestamp: 1600000L,
      observations: [sample(2, 1.6, 0.0)],
      lost: [],
      removed: [],
    },
  ]
  for
    config in [
      @motion.MotionConfig::new(),
      @motion.MotionConfig::new(max_velocity_std_mps=0.0001),
    ] {
    for cut in 0..<=frames.length() {
      let uninterrupted = @motion.MotionEstimator::new(
        "lifecycle-resume", config,
      )
      for i in 0..<cut {
        let frame = frames[i]
        ignore(
          uninterrupted.update(
            frame.timestamp,
            frame.observations,
            lost=frame.lost,
            removed=frame.removed,
          ),
        )
      }
      let restored = @motion.MotionEstimator::from_checkpoint(
        uninterrupted.checkpoint(),
      )
      for i in cut..<frames.length() {
        let frame = frames[i]
        let expected = uninterrupted.update(
          frame.timestamp,
          frame.observations,
          lost=frame.lost,
          removed=frame.removed,
        )
        let actual = restored.update(
          frame.timestamp,
          frame.observations,
          lost=frame.lost,
          removed=frame.removed,
        )
        assert_eq("\{Repr(actual)}", "\{Repr(expected)}")
      }
      assert_eq(
        "\{Repr(restored.checkpoint())}",
        "\{Repr(uninterrupted.checkpoint())}",
      )
    }
  }
}

///|
test "checkpoint configuration fields are publicly readable and preserve resolved values" {
  let config = @motion.MotionConfig::new(
    max_gap_us=900000L,
    min_observations=4,
    min_span_us=500000L,
    q=0.125,
    initial_velocity_std=3.0,
    gate=9.21034,
    max_tracks=7,
    max_position_std_m=0.2,
    max_velocity_std_mps=0.4,
  )
  let snapshot = @motion.MotionEstimator::new("resolved", config).checkpoint()
  assert_eq(snapshot.version, 1)
  assert_eq(snapshot.config.max_gap_us, 900000L)
  assert_eq(snapshot.config.min_observations, 4)
  assert_eq(snapshot.config.min_span_us, 500000L)
  assert_eq(snapshot.config.acceleration_spectral_density, 0.125)
  assert_eq(snapshot.config.initial_velocity_std, 3.0)
  assert_eq(snapshot.config.innovation_gate, 9.21034)
  assert_eq(snapshot.config.max_tracks, 7)
  assert_eq(snapshot.config.max_position_std_m, Some(0.2))
  assert_eq(snapshot.config.max_velocity_std_mps, Some(0.4))
  let restored = @motion.MotionEstimator::from_checkpoint(snapshot).checkpoint()
  assert_eq("\{Repr(snapshot)}", "\{Repr(restored)}")
}

///|
test "checkpoint export and import arrays never alias engine state" {
  let original = @motion.MotionEstimator::from_checkpoint(checkpoint_fixture())
  let exported = original.checkpoint()
  let restored = @motion.MotionEstimator::from_checkpoint(exported)
  let before = "\{Repr(original.checkpoint())}"
  exported.tracks[0].state[0] = 1.0e30
  exported.tracks[0].covariance[0] = 1.0e30
  exported.tracks.clear()
  assert_eq("\{Repr(original.checkpoint())}", before)
  assert_eq("\{Repr(restored.checkpoint())}", before)
  let actual = restored.update(400000L, [sample(1, 0.4, 0.0)])
  let expected = original.update(400000L, [sample(1, 0.4, 0.0)])
  assert_eq("\{Repr(actual)}", "\{Repr(expected)}")
}

///|
test "checkpoint restores frame watermark separately from accepted timestamps" {
  let original = @motion.MotionEstimator::new(
    "watermark",
    @motion.MotionConfig::new(),
  )
  ignore(original.update(0L, [sample(1, 0.0, 0.0)]))
  ignore(original.update(100000L, [sample(1, 10000.0, 0.0)]))
  ignore(original.update(200000L, []))
  let checkpoint = original.checkpoint()
  assert_eq(checkpoint.last_timestamp_us, Some(200000L))
  assert_eq(checkpoint.tracks[0].last_timestamp_us, 0L)
  let restored = @motion.MotionEstimator::from_checkpoint(checkpoint)
  try restored.update(200000L, []) catch {
    _ => ()
  } noraise {
    _ => fail("restored frame watermark lost")
  }
  let result = restored.update(500000L, [sample(1, 1.0, 0.0)])
  assert_eq(result.closed_segment_ids, ["1"])
  assert_eq(result.tracks[0].segment_id, "2")
}

///|
test "checkpoint rejects malformed envelope identities capacity and time without altering source" {
  let checkpoint = checkpoint_fixture()
  let track = checkpoint.tracks[0]
  let before = "\{Repr(checkpoint)}"
  for
    invalid in [
      { ..checkpoint, version: 0, },
      { ..checkpoint, version: 2, },
      { ..checkpoint, session_id: "", },
      { ..checkpoint, next_segment_id: 0L, },
      { ..checkpoint, next_segment_id: 1L, },
      { ..checkpoint, last_timestamp_us: None, },
      { ..checkpoint, last_timestamp_us: Some(-1L), },
      { ..checkpoint, last_timestamp_us: Some(299999L), },
      { ..checkpoint, last_timestamp_us: Some(800000L), },
      { ..checkpoint, tracks: [track, track], },
      { ..checkpoint, tracks: [track, { ..track, track_id: 2, }], },
      {
        ..checkpoint,
        config: @motion.MotionConfig::new(max_tracks=1),
        tracks: [track, { ..track, track_id: 2, segment_id: 2L, }],
        next_segment_id: 3L,
      },
    ] {
    checkpoint_rejected(invalid)
  }
  assert_eq("\{Repr(checkpoint)}", before)
  for
    invalid in [
      { ..track, track_id: 0, },
      { ..track, segment_id: 0L, },
      { ..track, segment_id: 2L, },
      { ..track, first_timestamp_us: -1L, },
      { ..track, first_timestamp_us: 400000L, },
      { ..track, last_timestamp_us: 400000L, },
      { ..track, accepted_count: 0, },
      { ..track, accepted_count: 1, },
      { ..track, accepted_count: 300002, },
    ] {
    checkpoint_rejected({ ..checkpoint, tracks: [invalid], })
  }
}

///|
test "checkpoint rejects malformed arrays covariances and paths" {
  let checkpoint = checkpoint_fixture()
  let track = checkpoint.tracks[0]
  let nan = 0.0 / 0.0
  let inf = 1.0 / 0.0
  for
    invalid in [
      { ..track, state: [], },
      { ..track, state: [0.0, 0.0, 0.0, 0.0, 0.0], },
      { ..track, state: [nan, 0.0, 0.0, 0.0], },
      { ..track, state: [track.state[0], 0.0, 1.7e308, 1.7e308], },
      { ..track, covariance: [], },
      { ..track, covariance: Array::make(16, 0.0), },
      { ..track, covariance: Array::make(16, nan), },
      {
        ..track,
        covariance: [
          1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0,
          1.0,
        ],
      },
      {
        ..track,
        covariance: [
          1.0, 2.0, 0.0, 0.0, 2.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0,
          1.0,
        ],
      },
      {
        ..track,
        covariance: [
          1.0, 0.0, 2.0, 0.0, 0.0, 1.0, 0.0, 0.0, 2.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0,
          1.0,
        ],
      },
      {
        ..track,
        covariance: [
          1.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0,
          1.0,
        ],
      },
      { ..track, observed_path_length_m: -1.0, },
      { ..track, observed_path_length_m: nan, },
      { ..track, observed_path_length_m: inf, },
      { ..track, observed_path_length_m: 0.0, },
      { ..track, first_filtered: { x: nan, y: 0.0, }, },
      {
        ..track,
        first_filtered: { x: -1.7e308, y: -1.7e308, },
        last_filtered: { x: 1.7e308, y: 1.7e308, },
        state: [1.7e308, 1.7e308, 0.0, 0.0],
      },
      { ..track, last_filtered: { x: 0.0, y: 0.0, }, },
    ] {
    checkpoint_rejected({ ..checkpoint, tracks: [invalid], })
  }
}

///|
test "checkpoint rejects impossible single-observation state and prior" {
  let engine = @motion.MotionEstimator::new(
    "initial",
    @motion.MotionConfig::new(),
  )
  ignore(engine.update(100L, [sample(1, 2.0, 3.0)]))
  let checkpoint = engine.checkpoint()
  let track = checkpoint.tracks[0]
  for
    invalid in [
      { ..track, accepted_count: 2, },
      { ..track, observed_path_length_m: 0.1, },
      {
        ..track,
        first_filtered: { x: 1.0, y: 3.0, },
        observed_path_length_m: 1.0,
      },
      { ..track, state: [2.0, 3.0, 1.0, 0.0], },
    ] {
    checkpoint_rejected({ ..checkpoint, tracks: [invalid], })
  }
  for index in [1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15] {
    let covariance = track.covariance.copy()
    covariance[index] = covariance[index] + 0.000000000001
    checkpoint_rejected({ ..checkpoint, tracks: [{ ..track, covariance, }], })
  }
}

///|
test "checkpoint retains empty frame state and exhausted segment counter" {
  let empty = @motion.MotionEstimator::new("empty", @motion.MotionConfig::new()).checkpoint()
  assert_eq(empty.last_timestamp_us, None)
  checkpoint_rejected({ ..empty, next_segment_id: 2L, })
  let processed = @motion.MotionEstimator::from_checkpoint(empty)
  ignore(processed.update(0L, []))
  let checkpoint = processed.checkpoint()
  assert_eq(checkpoint.last_timestamp_us, Some(0L))
  let exhausted = @motion.MotionEstimator::from_checkpoint({
    ..checkpoint,
    next_segment_id: 9223372036854775807L,
  })
  ignore(exhausted.update(1L, []))
  try exhausted.update(2L, [sample(1, 0.0, 0.0)]) catch {
    _ => ()
  } noraise {
    _ => fail("exhausted segment counter allocated")
  }
  assert_eq(exhausted.last_timestamp_us(), Some(1L))
  let active = checkpoint_fixture()
  let active_exhausted = @motion.MotionEstimator::from_checkpoint({
    ..active,
    next_segment_id: 9223372036854775807L,
  })
  assert_eq(
    active_exhausted.update(400000L, [sample(1, 0.4, 0.0)]).tracks[0].accepted_count,
    5,
  )
}

///|
test "checkpoint preserves exact Int64 epochs and terminal timestamp" {
  let engine = @motion.MotionEstimator::new(
    "large-time",
    @motion.MotionConfig::new(),
  )
  let epoch = 9223372036854375807L
  ignore(engine.update(epoch, [sample(1, 0.0, 0.0)]))
  ignore(engine.update(epoch + 200000L, [sample(1, 0.2, 0.0)]))
  let restored = @motion.MotionEstimator::from_checkpoint(engine.checkpoint())
  let expected = engine.update(9223372036854775807L, [sample(1, 0.4, 0.0)])
  let actual = restored.update(9223372036854775807L, [sample(1, 0.4, 0.0)])
  assert_eq("\{Repr(actual)}", "\{Repr(expected)}")
  assert_eq(
    @motion.MotionEstimator::from_checkpoint(restored.checkpoint()).last_timestamp_us(),
    Some(9223372036854775807L),
  )
}

///|
test "checkpoint preserves tiny relative covariance asymmetry without repair" {
  let checkpoint = checkpoint_fixture()
  let track = checkpoint.tracks[0]
  for scale in [1.0e-280, 1.0, 1.0e280] {
    let covariance = track.covariance.map(value => value * scale)
    covariance[2] = covariance[2] + 1.0e-15 * scale
    assert_true(covariance[2] != covariance[8])
    let modified : @motion.MotionCheckpoint = {
      ..checkpoint,
      tracks: [{ ..track, covariance, }],
    }
    let restored = @motion.MotionEstimator::from_checkpoint(modified).checkpoint()
    assert_eq(restored.tracks[0].covariance, covariance)
  }
}

///|
test "checkpoint resumes per-target numerical failure and segment ID holes" {
  let engine = @motion.MotionEstimator::new(
    "numerical-resume",
    @motion.MotionConfig::new(initial_velocity_std=0.001),
  )
  ignore(
    engine.update(0L, [sample(1, 0.0, 0.0, std=1.0e-8), sample(2, 0.0, 0.0)]),
  )
  let failure = engine.update(1L, [
    sample(1, 0.0, 0.0, std=1.0e-8),
    sample(2, 0.0, 0.0),
  ])
  assert_eq(failure.tracks[0].status, @motion.NumericalFailure)
  let restored = @motion.MotionEstimator::from_checkpoint(engine.checkpoint())
  assert_eq(
    "\{Repr(restored.update(100000L, [sample(1, 0.0, 0.0), sample(2, 0.1, 0.0)]))}",
    "\{Repr(engine.update(100000L, [sample(1, 0.0, 0.0), sample(2, 0.1, 0.0)]))}",
  )
  ignore(engine.update(200000L, [], lost=[1, 2]))
  let closed = engine.checkpoint()
  assert_eq(closed.tracks.length(), 0)
  assert_eq(closed.next_segment_id, 3L)
  let reuse = @motion.MotionEstimator::from_checkpoint(closed).update(300000L, [
    sample(1, 0.0, 0.0),
  ])
  assert_eq(reuse.tracks[0].segment_id, "3")
}

///|
test "restored accepted counter exhaustion rolls back complete frame" {
  let checkpoint = checkpoint_fixture()
  let track = checkpoint.tracks[0]
  let last = 2147483646L
  let exhausted : @motion.MotionCheckpoint = {
    ..checkpoint,
    last_timestamp_us: Some(last),
    tracks: [{ ..track, accepted_count: 2147483647, last_timestamp_us: last, }],
  }
  let restored = @motion.MotionEstimator::from_checkpoint(exhausted)
  let before = "\{Repr(restored.checkpoint())}"
  try
    restored.update(last + 100000L, [sample(1, 0.4, 0.0), sample(2, 0.0, 0.0)])
  catch {
    _ => ()
  } noraise {
    _ => fail("accepted counter overflow was committed")
  }
  assert_eq("\{Repr(restored.checkpoint())}", before)
}

///|
test "checkpoint export orders tracks after unsorted public import" {
  let engine = @motion.MotionEstimator::new(
    "ordered-import",
    @motion.MotionConfig::new(),
  )
  ignore(
    engine.update(0L, [
      sample(9, 0.0, 0.0),
      sample(1, 0.0, 0.0),
      sample(4, 0.0, 0.0),
    ]),
  )
  let checkpoint = engine.checkpoint()
  let tracks = checkpoint.tracks
  let unsorted : @motion.MotionCheckpoint = {
    ..checkpoint,
    tracks: [tracks[2], tracks[0], tracks[1]],
  }
  let restored = @motion.MotionEstimator::from_checkpoint(unsorted)
  assert_eq(restored.checkpoint().tracks.map(track => track.track_id), [1, 4, 9])
  assert_eq(restored.checkpoint().tracks.map(track => track.segment_id), [
    1L, 2L, 3L,
  ])
}

///|
test "checkpoint covariance validation uses local scales across mixed position and velocity variances" {
  let checkpoint = checkpoint_fixture()
  let track = checkpoint.tracks[0]
  let covariance = [
    1.0e-200, 1.0e-201, 0.0, 0.0, 1.0e-201, 1.0e-200, 0.0, 0.0, 0.0, 0.0, 1.0e200,
    0.0, 0.0, 0.0, 0.0, 1.0e200,
  ]
  let valid : @motion.MotionCheckpoint = {
    ..checkpoint,
    tracks: [{ ..track, covariance, }],
  }
  assert_eq(
    @motion.MotionEstimator::from_checkpoint(valid).checkpoint().tracks[0].covariance,
    covariance,
  )
  let asymmetric = covariance.copy()
  asymmetric[4] = 0.0
  checkpoint_rejected({
    ..checkpoint,
    tracks: [{ ..track, covariance: asymmetric, }],
  })
  let indefinite = covariance.copy()
  indefinite[2] = 2.0
  indefinite[8] = 2.0
  checkpoint_rejected({
    ..checkpoint,
    tracks: [{ ..track, covariance: indefinite, }],
  })
  // Every correlation has magnitude below one, but the complete matrix is
  // indefinite; pairwise bounds alone cannot validate a covariance.
  let correlation_indefinite = [
    1.0e-200, -0.9e-200, -0.9, 0.0, -0.9e-200, 1.0e-200, -0.9, 0.0, -0.9, -0.9, 1.0e200,
    0.0, 0.0, 0.0, 0.0, 1.0e200,
  ]
  checkpoint_rejected({
    ..checkpoint,
    tracks: [{ ..track, covariance: correlation_indefinite, }],
  })
  for scales in [(1.0e-100, 1.0e100), (1.0e100, 1.0e-100)] {
    let engine = @motion.MotionEstimator::new(
      "mixed-own-export",
      @motion.MotionConfig::new(initial_velocity_std=scales.1),
    )
    ignore(engine.update(0L, [sample(1, 0.0, 0.0, std=scales.0)]))
    let exported = engine.checkpoint()
    assert_eq(exported.tracks.length(), 1)
    assert_eq(
      @motion.MotionEstimator::from_checkpoint(exported).checkpoint().tracks[0].covariance,
      exported.tracks[0].covariance,
    )
  }
}

///|
test "extreme update rejects locally indefinite covariance before committing checkpoint state" {
  let engine = @motion.MotionEstimator::new(
    "local-psd-commit",
    @motion.MotionConfig::new(
      q=0.0,
      initial_velocity_std=1.0e106,
      max_gap_us=2000000L,
    ),
  )
  let observation = @types.GroundObservation::new(
    1,
    @types.Point2::new(0.0, 0.0),
    @types.Covariance2::new(1.0e-32, -9.999999999990001e-33, 1.0e-32),
  )
  ignore(engine.update(500000L, [observation]))
  let before = engine.checkpoint().tracks[0]
  let result = engine.update(500001L, [
      @types.GroundObservation::new(
        1,
        @types.Point2::new(0.0, 0.0),
        @types.Covariance2::new(1.0e186, 0.0, 1.0e186),
      ),
    ]).tracks[0]
  assert_eq(result.status, @motion.NumericalFailure)
  assert_eq(result.accepted_count, 1)
  assert_eq(result.last_accepted_timestamp_us, 500000L)
  assert_eq(result.filtered_state, None)
  assert_eq(result.filtered_covariance, None)
  let saved = engine.checkpoint()
  assert_eq(saved.last_timestamp_us, Some(500001L))
  assert_eq("\{Repr(saved.tracks[0])}", "\{Repr(before)}")
  let restored = @motion.MotionEstimator::from_checkpoint(saved).checkpoint()
  assert_eq("\{Repr(restored)}", "\{Repr(saved)}")
}

///|
test "restored uncertain segment recovers speed without restarting warmup" {
  let engine = @motion.MotionEstimator::new(
    "resume-uncertain-recovery",
    @motion.MotionConfig::new(
      min_observations=2,
      min_span_us=0L,
      q=0.0,
      max_position_std_m=0.2,
      max_velocity_std_mps=0.7,
    ),
  )
  ignore(engine.update(0L, [sample(1, 0.0, 0.0, std=1.0)]))
  let uncertain = engine.update(200000L, [sample(1, 0.0, 0.0, std=1.0)]).tracks[0]
  assert_eq(uncertain.status, @motion.Uncertain)
  let restored = @motion.MotionEstimator::from_checkpoint(engine.checkpoint())
  let mut last = uncertain
  for i in 2..<10 {
    let timestamp = Int64::from_int(i) * 200000L
    let observation = [sample(1, 0.0, 0.0, std=0.01)]
    let expected = engine.update(timestamp, observation)
    let actual = restored.update(timestamp, observation)
    assert_eq("\{Repr(actual)}", "\{Repr(expected)}")
    last = actual.tracks[0]
  }
  assert_eq(last.status, @motion.Ready)
  assert_eq(last.segment_id, uncertain.segment_id)
  assert_eq(last.accepted_count, 10)
  assert_eq(last.speed_mps, Some(0.0))
}
