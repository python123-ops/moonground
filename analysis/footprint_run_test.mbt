///|
fn footprint_session_monitor(
  max_tracks~ : Int32 = 10,
) -> @zones.FootprintRunMonitor raise @types.GroundError {
  @zones.FootprintRunMonitor::new(
    "analysis",
    [
      @zones.ConvexZone::new("area", [
        { x: -10.0, y: -10.0, },
        { x: 10.0, y: -10.0, },
        { x: 10.0, y: 10.0, },
        { x: -10.0, y: 10.0, },
      ]),
    ],
    @zones.FootprintRunConfig::new(min_samples=2L, confirmation_us=100000L),
    max_tracks~,
  )
}

///|
fn footprint_session_ground(
  max_tracks~ : Int32 = 10,
  run_tracks~ : Int32 = 10,
) -> @analysis.FootprintRunSession raise @types.GroundError {
  @analysis.FootprintRunSession::from_ground(
    @motion.MotionEstimator::new(
      "analysis",
      @motion.MotionConfig::new(
        max_tracks~,
        min_observations=2,
        min_span_us=0L,
        gate=1.0e12,
      ),
    ),
    footprint_session_monitor(max_tracks=run_tracks),
  )
}

///|
fn footprint_session_bundle(
  measurement : @moonground.MeasurementFrame,
  radius~ : Double = 0.125,
) -> @zones.FootprintAssignments raise @types.GroundError {
  @zones.FootprintAssignments::new(
    measurement.motion.timestamp_us,
    measurement.motion.tracks.map(track => {
      @zones.FootprintAssignment::new(
        track.track_id,
        track.segment_id,
        @zones.Disk(@zones.DiskFootprint::new(radius)),
      )
    }),
  )
}

///|
fn footprint_session_step(
  session : @analysis.FootprintRunSession,
  timestamp : Int64,
  observations : Array[@types.GroundObservation],
) -> @analysis.FootprintRunSessionFrame raise @types.GroundError {
  let prepared = session.prepare_ground(timestamp, observations)
  prepared.commit(footprint_session_bundle(prepared.measurement()))
}

///|
fn footprint_session_motion(
  saved : @analysis.FootprintRunSessionCheckpoint,
) -> @motion.MotionCheckpoint {
  match saved.measurement {
    @analysis.Pixel(saved) => saved.motion
    @analysis.Ground(saved) => saved
  }
}

///|
fn footprint_session_snapshot(
  saved : @analysis.FootprintRunSessionCheckpoint,
) -> String {
  @debug.to_string(
    (
      saved.measurement,
      saved.runs.last_timestamp_us,
      saved.runs.states.map(state => {
        (
          state.run,
          state.last_position_m,
          state.last_position_covariance,
          match state.shape {
            @zones.Disk(shape) => shape.radius_m.to_string()
            @zones.Convex(shape) => @debug.to_string(shape.vertices_offset_m())
          },
        )
      }),
    ),
  )
}

///|
test "footprint session prepares real sorted segment identities without advancing either owner" {
  let session = footprint_session_ground()
  let before = footprint_session_snapshot(session.checkpoint())
  let prepared = session.prepare_ground(0L, [
    ground(0.5, 0.5, id=9),
    ground(0.5, 0.5, id=2),
  ])
  let measurement = prepared.measurement()
  assert_eq(measurement.motion.tracks.map(track => track.track_id), [2, 9])
  assert_eq(measurement.motion.tracks.map(track => track.segment_id), ["1", "2"])
  assert_eq(footprint_session_snapshot(session.checkpoint()), before)
  let result = prepared.commit(footprint_session_bundle(measurement))
  assert_eq(@debug.to_string(result.measurement), @debug.to_string(measurement))
  assert_eq(session.checkpoint().runs.last_timestamp_us, Some(0L))
  assert_eq(footprint_session_motion(session.checkpoint()).next_segment_id, 3L)
}

///|
test "footprint preparation wrong new segment fails atomically and the same candidate is retryable" {
  let session = footprint_session_ground()
  let before = footprint_session_snapshot(session.checkpoint())
  let prepared = session.prepare_ground(0L, [ground(0.5, 0.5)])
  let bad = @zones.FootprintAssignments::new(0L, [
    @zones.FootprintAssignment::new(
      1,
      "9",
      @zones.Disk(@zones.DiskFootprint::new(0.125)),
    ),
  ])
  invalid(() => ignore(prepared.commit(bad)))
  assert_eq(footprint_session_snapshot(session.checkpoint()), before)
  let result = prepared.commit(footprint_session_bundle(prepared.measurement()))
  assert_eq(result.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(footprint_session_motion(session.checkpoint()).next_segment_id, 2L)
}

///|
test "footprint preparation assignment clock mismatch does not consume its candidate" {
  let session = footprint_session_ground()
  let prepared = session.prepare_ground(100L, [ground(0.5, 0.5)])
  invalid(() => {
    ignore(prepared.commit(@zones.FootprintAssignments::new(101L, [])))
  })
  assert_eq(session.checkpoint().runs.last_timestamp_us, None)
  ignore(prepared.commit(footprint_session_bundle(prepared.measurement())))
  assert_eq(session.checkpoint().runs.last_timestamp_us, Some(100L))
}

///|
test "footprint preparation rejects repeated commits and competing candidates at the same baseline" {
  let session = footprint_session_ground()
  let first = session.prepare_ground(0L, [ground(0.5, 0.5)])
  let other = session.prepare_ground(0L, [ground(0.5, 0.5, id=2)])
  let first_bundle = footprint_session_bundle(first.measurement())
  ignore(first.commit(first_bundle))
  let committed = footprint_session_snapshot(session.checkpoint())
  invalid(() => ignore(first.commit(first_bundle)))
  invalid(() => {
    ignore(other.commit(footprint_session_bundle(other.measurement())))
  })
  assert_eq(footprint_session_snapshot(session.checkpoint()), committed)
}

///|
test "footprint preparations are captured by their original owners and branches remain independent" {
  let first = footprint_session_ground()
  let second = first.fork()
  let a = first.prepare_ground(0L, [ground(0.5, 0.5)])
  let b = second.prepare_ground(0L, [ground(0.5, 0.5, id=2)])
  ignore(a.commit(footprint_session_bundle(a.measurement())))
  assert_eq(second.checkpoint().runs.last_timestamp_us, None)
  ignore(b.commit(footprint_session_bundle(b.measurement())))
  assert_eq(footprint_session_motion(first.checkpoint()).tracks[0].track_id, 1)
  assert_eq(footprint_session_motion(second.checkpoint()).tracks[0].track_id, 2)
}

///|
test "footprint preparation preview deeply detaches diagnostics closed arrays and target arrays" {
  let session = footprint_session_ground()
  let prepared = session.prepare_ground(0L, [ground(0.5, 0.5)])
  let expected = @debug.to_string(prepared.measurement())
  let preview = prepared.measurement()
  guard preview.motion.tracks[0].filtered_state is Some(state) &&
    preview.motion.tracks[0].filtered_covariance is Some(covariance) else {
    fail("expected diagnostics")
  }
  state[0] = 999.0
  covariance[0] = 999.0
  preview.motion.closed_segment_ids.push("999")
  preview.projection_failures.push({ track_id: 999, reason: "external", })
  preview.motion.tracks.clear()
  assert_eq(@debug.to_string(prepared.measurement()), expected)
  let result = prepared.commit(footprint_session_bundle(prepared.measurement()))
  assert_eq(@debug.to_string(result.measurement), expected)
  result.measurement.motion.tracks.clear()
  assert_eq(footprint_session_motion(session.checkpoint()).tracks.length(), 1)
}

///|
test "first Ready footprint numerical failure preserves new IDs filter state and same candidate retry" {
  let session = footprint_session_ground()
  ignore(footprint_session_step(session, 0L, [ground(0.5, 0.5)]))
  let before = footprint_session_snapshot(session.checkpoint())
  let prepared = session.prepare_ground(100000L, [
    ground(0.5, 0.5),
    ground(0.5, 0.5, id=2),
  ])
  let candidate = prepared.measurement()
  assert_eq(candidate.motion.tracks[0].status, @motion.Ready)
  invalid(() => {
    ignore(
      prepared.commit(footprint_session_bundle(candidate, radius=1.0e-300)),
    )
  })
  assert_eq(footprint_session_snapshot(session.checkpoint()), before)
  assert_eq(footprint_session_motion(session.checkpoint()).next_segment_id, 2L)
  let result = prepared.commit(footprint_session_bundle(candidate))
  assert_eq(result.runs.active[0].sample_count, 1L)
  assert_eq(result.measurement.motion.tracks[1].segment_id, "2")
  assert_eq(footprint_session_motion(session.checkpoint()).next_segment_id, 3L)
}

///|
test "smaller footprint monitor capacity rejects a successful motion candidate without allocating segments" {
  let session = footprint_session_ground(run_tracks=1)
  let before = footprint_session_snapshot(session.checkpoint())
  let prepared = session.prepare_ground(0L, [
    ground(0.5, 0.5),
    ground(0.5, 0.5, id=2),
  ])
  invalid(() => {
    ignore(prepared.commit(footprint_session_bundle(prepared.measurement())))
  })
  assert_eq(footprint_session_snapshot(session.checkpoint()), before)
  let corrected = session.prepare_ground(0L, [ground(0.5, 0.5, id=2)])
  let result = corrected.commit(
    footprint_session_bundle(corrected.measurement()),
  )
  assert_eq(result.measurement.motion.tracks[0].segment_id, "1")
  invalid(() => {
    ignore(prepared.commit(footprint_session_bundle(prepared.measurement())))
  })
}

///|
test "footprint joint metric updates exactly equal separately committed old measurement and run stages" {
  let estimator = @motion.MotionEstimator::new(
    "analysis",
    @motion.MotionConfig::new(min_observations=2, min_span_us=0L, gate=1.0e12),
  )
  let monitor = footprint_session_monitor()
  let joint = @analysis.FootprintRunSession::from_ground(estimator, monitor)
  for
    index, observations in [
      [ground(0.5, 0.5)],
      [ground(0.5, 0.5)],
      [ground(0.5, 0.5)],
      [],
      [ground(20.0, 0.5)],
      [ground(20.0, 0.5)],
    ] {
    let time = index.to_int64() * 100000L
    let motion = estimator.update(time, observations)
    let measurement : @moonground.MeasurementFrame = {
      motion,
      projection_failures: [],
    }
    let assignments = footprint_session_bundle(measurement)
    let expected = monitor.update(motion, assignments)
    let actual = joint.update_ground(time, observations, assignments)
    assert_eq(
      @debug.to_string(actual.measurement),
      @debug.to_string(measurement),
    )
    assert_eq(@debug.to_string(actual.runs), @debug.to_string(expected))
    ignore(@analysis.FootprintRunSession::from_checkpoint(joint.checkpoint()))
  }
}

///|
test "footprint interrupt closes hidden motion and existing runs without losing next segment identity" {
  let session = footprint_session_ground()
  for time in [0L, 100000L] {
    ignore(
      footprint_session_step(session, time, [
        ground(0.5, 0.5),
        ground(0.5, 0.5, id=2),
      ]),
    )
  }
  ignore(footprint_session_step(session, 200000L, [ground(0.5, 0.5)]))
  assert_eq(footprint_session_motion(session.checkpoint()).tracks.length(), 2)
  let result = session.interrupt(300000L)
  assert_eq(result.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(result.runs.closed[0].reason, @zones.SegmentClosed)
  assert_eq(result.runs.active.length(), 0)
  assert_eq(footprint_session_motion(session.checkpoint()).tracks.length(), 0)
  let next = footprint_session_step(session, 400000L, [ground(0.5, 0.5, id=2)])
  assert_eq(next.measurement.motion.tracks[0].segment_id, "3")
}

///|
test "footprint pixel projection failures are unavailable with no artificial segment or assignment" {
  let session = @analysis.FootprintRunSession::from_pixel(
    pixel_session(),
    footprint_session_monitor(),
  )
  for time in [0L, 100000L, 200000L, 300000L] {
    let prepared = session.prepare_pixel(time, [pixel(0.5, 0.5)])
    ignore(prepared.commit(footprint_session_bundle(prepared.measurement())))
  }
  assert_eq(session.checkpoint().runs.states.length(), 1)
  let prepared = session.prepare_pixel(400000L, [pixel(100.0, 100.0)])
  let preview = prepared.measurement()
  assert_eq(preview.projection_failures.length(), 1)
  preview.projection_failures.clear()
  let result = prepared.commit(@zones.FootprintAssignments::new(400000L, []))
  assert_eq(result.measurement.projection_failures.length(), 1)
  assert_eq(result.runs.closed[0].reason, @zones.MissingTarget)
  assert_eq(result.runs.evidence.unavailable[0].segment_id, None)
  assert_eq(
    result.runs.evidence.unavailable[0].reason,
    @zones.Position(@zones.RejectedProjection),
  )
}

///|
test "footprint wrong mode bad raw IDs and old time do not advance the owner" {
  let ground_session = footprint_session_ground()
  let pixel_session = @analysis.FootprintRunSession::from_pixel(
    pixel_session(),
    footprint_session_monitor(),
  )
  invalid(() => ignore(ground_session.prepare_pixel(0L, [pixel(0.5, 0.5)])))
  invalid(() => ignore(pixel_session.prepare_ground(0L, [ground(0.5, 0.5)])))
  invalid(() => {
    ignore(
      ground_session.prepare_ground(0L, [ground(0.5, 0.5), ground(0.5, 0.5)]),
    )
  })
  assert_eq(ground_session.checkpoint().runs.last_timestamp_us, None)
  ignore(footprint_session_step(ground_session, 0L, [ground(0.5, 0.5)]))
  let before = footprint_session_snapshot(ground_session.checkpoint())
  invalid(() => ignore(ground_session.prepare_ground(0L, [ground(0.5, 0.5)])))
  invalid(() => ignore(ground_session.reframed(@types.PixelTransform::new())))
  assert_eq(footprint_session_snapshot(ground_session.checkpoint()), before)
}

///|
test "footprint construction export and fork independently detach all retained components" {
  let estimator = @motion.MotionEstimator::new(
    "analysis",
    @motion.MotionConfig::new(min_observations=2, min_span_us=0L),
  )
  let monitor = footprint_session_monitor()
  let session = @analysis.FootprintRunSession::from_ground(estimator, monitor)
  ignore(estimator.update(0L, [ground(0.5, 0.5)]))
  assert_eq(session.checkpoint().runs.last_timestamp_us, None)
  ignore(footprint_session_step(session, 0L, [ground(0.5, 0.5)]))
  ignore(footprint_session_step(session, 100000L, [ground(0.5, 0.5)]))
  let branch = session.fork()
  let saved = session.checkpoint()
  saved.runs.states.clear()
  saved.runs.zones.clear()
  let tracks = footprint_session_motion(saved).tracks
  tracks[0].state[0] = 999.0
  tracks.clear()
  ignore(footprint_session_step(branch, 200000L, [ground(0.5, 0.5)]))
  assert_eq(session.checkpoint().runs.states[0].run.sample_count, 1L)
  assert_eq(branch.checkpoint().runs.states[0].run.sample_count, 2L)
  assert_eq(
    footprint_session_motion(session.checkpoint()).tracks[0].state[0],
    0.5,
  )
}

///|
test "footprint warm Brown reframing preserves metric runs and restored continuation" {
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let session = @analysis.FootprintRunSession::from_pixel(
    pixel_session(camera~),
    footprint_session_monitor(),
  )
  for time in [0L, 100000L, 200000L, 300000L] {
    let prepared = session.prepare_pixel(time, [pixel(0.5, 0.5)])
    ignore(prepared.commit(footprint_session_bundle(prepared.measurement())))
  }
  let transform = @types.PixelTransform::new(
    scale_x=2.0,
    scale_y=3.0,
    offset_x=4.0,
    offset_y=-2.0,
  )
  let reframed = session.reframed(transform)
  assert_eq(
    @debug.to_string(footprint_session_motion(reframed.checkpoint())),
    @debug.to_string(footprint_session_motion(session.checkpoint())),
  )
  assert_eq(
    @debug.to_string(reframed.checkpoint().runs.states.map(state => state.run)),
    @debug.to_string(session.checkpoint().runs.states.map(state => state.run)),
  )
  let restored = @analysis.FootprintRunSession::from_checkpoint(
    reframed.checkpoint(),
  )
  let original = pixel(0.5, 0.5)
  let changed = @moonground.PixelObservation::new(
    1,
    transform.point(original.position),
    transform.covariance(original.covariance),
  )
  let a = session.prepare_pixel(400000L, [original])
  let b = restored.prepare_pixel(400000L, [changed])
  let first = a.commit(footprint_session_bundle(a.measurement()))
  let second = b.commit(footprint_session_bundle(b.measurement()))
  assert_eq(
    first.runs.active[0].sample_count,
    second.runs.active[0].sample_count,
  )
  assert_eq(
    first.runs.active[0].first_timestamp_us,
    second.runs.active[0].first_timestamp_us,
  )
  let p = first.measurement.motion.tracks[0].position.unwrap()
  let q = second.measurement.motion.tracks[0].position.unwrap()
  assert_true((p.x - q.x).abs() < 1.0e-12 && (p.y - q.y).abs() < 1.0e-12)
}

///|
test "footprint complete ground checkpoints continue every missing and segment expiry cut" {
  let times = [0L, 100000L, 200000L, 300000L, 400000L, 900000L, 1000000L]
  let observations = [
    [ground(0.5, 0.5)],
    [ground(0.5, 0.5)],
    [ground(0.5, 0.5)],
    [],
    [ground(0.5, 0.5)],
    [ground(0.5, 0.5)],
    [ground(0.5, 0.5)],
  ]
  let full = footprint_session_ground()
  let expected : Array[String] = []
  for index, time in times {
    expected.push(
      @debug.to_string(footprint_session_step(full, time, observations[index])),
    )
  }
  for cut in 0..<=times.length() {
    let prefix = footprint_session_ground()
    for index in 0..<cut {
      ignore(footprint_session_step(prefix, times[index], observations[index]))
    }
    let resumed = @analysis.FootprintRunSession::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<times.length() {
      assert_eq(
        @debug.to_string(
          footprint_session_step(resumed, times[index], observations[index]),
        ),
        expected[index],
      )
    }
    assert_eq(
      footprint_session_snapshot(resumed.checkpoint()),
      footprint_session_snapshot(full.checkpoint()),
    )
  }
}

///|
test "footprint exact adjacent timestamps survive preparation above two to fifty third and near maximum" {
  for first in [9007199254740992L, 9223372036854775805L] {
    let session = footprint_session_ground()
    for dt in [0L, 1L, 2L] {
      let result = footprint_session_step(session, first + dt, [
        ground(0.5, 0.5),
      ])
      assert_eq(result.measurement.motion.timestamp_us, first + dt)
    }
    assert_eq(session.checkpoint().runs.states[0].run.sample_span_us, 1L)
    assert_eq(session.checkpoint().runs.states[0].run.sample_count, 2L)
    ignore(@analysis.FootprintRunSession::from_checkpoint(session.checkpoint()))
  }
}
