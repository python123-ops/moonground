///|
fn footprint_window_session(
  width~ : Int64 = 1000000L,
  origin~ : Int64 = 0L,
  run_tracks~ : Int32 = 10,
) -> @analysis.FootprintRunWindowSession raise @types.GroundError {
  @analysis.FootprintRunWindowSession::new(
    footprint_session_ground(run_tracks~),
    window_us=width,
    origin_us=origin,
  )
}

///|
fn footprint_window_step(
  session : @analysis.FootprintRunWindowSession,
  timestamp : Int64,
  observations : Array[@types.GroundObservation],
) -> @analysis.FootprintRunWindowSessionFrame raise @types.GroundError {
  let prepared = session.prepare_ground(timestamp, observations)
  prepared.commit(footprint_session_bundle(prepared.measurement()))
}

///|
fn footprint_window_motion(
  saved : @analysis.FootprintRunWindowSessionCheckpoint,
) -> @motion.MotionCheckpoint {
  match saved.measurement {
    @analysis.Pixel(snapshot) => snapshot.motion
    @analysis.Ground(snapshot) => snapshot
  }
}

///|
fn footprint_window_snapshot(
  saved : @analysis.FootprintRunWindowSessionCheckpoint,
) -> String {
  @debug.to_string(
    (
      footprint_session_snapshot({
        version: 1,
        measurement: saved.measurement,
        runs: saved.windows.runs,
      }),
      saved.windows.window_us,
      saved.windows.origin_us,
      saved.windows.baseline_timestamp_us,
      saved.windows.current_window,
    ),
  )
}

///|
test "window preparation exposes actual new identities without advancing any committed component" {
  let session = footprint_window_session()
  let before = footprint_window_snapshot(session.checkpoint())
  let prepared = session.prepare_ground(0L, [
    ground(0.5, 0.5, id=9),
    ground(0.5, 0.5, id=2),
  ])
  let candidate = prepared.measurement()
  assert_eq(candidate.motion.tracks.map(track => track.track_id), [2, 9])
  assert_eq(candidate.motion.tracks.map(track => track.segment_id), ["1", "2"])
  assert_eq(footprint_window_snapshot(session.checkpoint()), before)
  let result = prepared.commit(footprint_session_bundle(candidate))
  assert_eq(@debug.to_string(result.measurement), @debug.to_string(candidate))
  assert_eq(result.windows.statistics.current_window.input_frames, 1L)
  assert_eq(footprint_window_motion(session.checkpoint()).next_segment_id, 3L)
}

///|
test "window exact assignment failure leaves the same real preparation retryable" {
  let session = footprint_window_session()
  let before = footprint_window_snapshot(session.checkpoint())
  let prepared = session.prepare_ground(0L, [ground(0.5, 0.5)])
  invalid(() => {
    ignore(prepared.commit(@zones.FootprintAssignments::new(1L, [])))
  })
  let wrong = @zones.FootprintAssignments::new(0L, [
    @zones.FootprintAssignment::new(
      1,
      "9",
      @zones.Disk(@zones.DiskFootprint::new(0.125)),
    ),
  ])
  invalid(() => ignore(prepared.commit(wrong)))
  assert_eq(footprint_window_snapshot(session.checkpoint()), before)
  let result = prepared.commit(footprint_session_bundle(prepared.measurement()))
  assert_eq(result.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(result.windows.statistics.current_window.input_frames, 1L)
}

///|
test "first Ready shape failure rolls back candidate filter IDs runs and an imminent window rollover" {
  let session = footprint_window_session(width=100000L)
  ignore(footprint_window_step(session, 0L, [ground(0.5, 0.5)]))
  let before = footprint_window_snapshot(session.checkpoint())
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
  assert_eq(footprint_window_snapshot(session.checkpoint()), before)
  assert_eq(footprint_window_motion(session.checkpoint()).next_segment_id, 2L)
  let result = prepared.commit(footprint_session_bundle(candidate))
  assert_eq(
    result.windows.statistics.closed_window.unwrap().last_timestamp_us,
    0L,
  )
  assert_eq(result.windows.statistics.current_window.input_frames, 1L)
  assert_eq(result.windows.runs.active[0].sample_count, 1L)
  assert_eq(footprint_window_motion(session.checkpoint()).next_segment_id, 3L)
}

///|
test "origin rejection after a valid raw measurement leaves all three stages unstarted" {
  let session = footprint_window_session(origin=100L)
  let prepared = session.prepare_ground(99L, [ground(0.5, 0.5)])
  let before = footprint_window_snapshot(session.checkpoint())
  invalid(() => {
    ignore(prepared.commit(footprint_session_bundle(prepared.measurement())))
  })
  assert_eq(footprint_window_snapshot(session.checkpoint()), before)
  assert_eq(footprint_window_motion(session.checkpoint()).next_segment_id, 1L)
  let result = footprint_window_step(session, 100L, [ground(0.5, 0.5)])
  assert_eq(result.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(result.windows.statistics.current_window.first_timestamp_us, 100L)
  invalid(() => {
    ignore(prepared.commit(footprint_session_bundle(prepared.measurement())))
  })
}

///|
test "raw ground window frames exactly equal separate original motion and v29 outputs" {
  let estimator = @motion.MotionEstimator::new(
    "analysis",
    @motion.MotionConfig::new(
      max_tracks=10,
      min_observations=2,
      min_span_us=0L,
      gate=1.0e12,
    ),
  )
  let monitor = footprint_session_monitor()
  let joint = @analysis.FootprintRunWindowSession::new(
    @analysis.FootprintRunSession::from_ground(estimator, monitor),
    window_us=200000L,
  )
  let downstream = @zones.FootprintRunWindowMonitor::new(
    monitor,
    window_us=200000L,
  )
  let inputs = [
    [ground(0.5, 0.5)],
    [ground(0.5, 0.5)],
    [ground(0.5, 0.5)],
    [],
    [ground(20.0, 0.5)],
    [ground(20.0, 0.5)],
    [],
  ]
  for index, observations in inputs {
    let time = index.to_int64() * 100000L
    let motion = estimator.update(time, observations)
    let measurement : @moonground.MeasurementFrame = {
      motion,
      projection_failures: [],
    }
    let assignments = footprint_session_bundle(measurement)
    let expected = downstream.update(motion, assignments)
    let actual = joint.update_ground(time, observations, assignments)
    assert_eq(
      @debug.to_string(actual.measurement),
      @debug.to_string(measurement),
    )
    assert_eq(@debug.to_string(actual.windows), @debug.to_string(expected))
    assert_eq(
      @debug.to_string(footprint_window_motion(joint.checkpoint())),
      @debug.to_string(estimator.checkpoint()),
    )
    ignore(
      @analysis.FootprintRunWindowSession::from_checkpoint(joint.checkpoint()),
    )
  }
}

///|
test "new window owner detaches started sessions and never backfills existing confirmations" {
  for already_confirmed in [false, true] {
    let old = footprint_session_ground()
    ignore(footprint_session_step(old, 0L, [ground(0.5, 0.5)]))
    ignore(footprint_session_step(old, 100000L, [ground(0.5, 0.5)]))
    if already_confirmed {
      ignore(footprint_session_step(old, 200000L, [ground(0.5, 0.5)]))
    }
    let baseline = old.checkpoint().runs.last_timestamp_us.unwrap()
    let session = @analysis.FootprintRunWindowSession::new(
      old,
      window_us=1000000L,
    )
    assert_true(session.checkpoint().windows.current_window is None)
    assert_eq(
      session.checkpoint().windows.baseline_timestamp_us,
      Some(baseline),
    )
    ignore(footprint_session_step(old, baseline + 1L, []))
    let result = footprint_window_step(session, baseline + 100000L, [
      ground(0.5, 0.5),
    ])
    let row = result.windows.statistics.current_window.zones[0]
    assert_eq(row.opening_active, 1L)
    assert_eq(row.opening_confirmed, if already_confirmed { 1L } else { 0L })
    assert_eq(row.confirmed_inside, if already_confirmed { 0L } else { 1L })
    let ended = footprint_window_step(session, baseline + 200000L, [])
    assert_eq(
      ended.windows.statistics.current_window.zones[0].endings[3].confirmed,
      1L,
    )
    ignore(
      @analysis.FootprintRunWindowSession::from_checkpoint(session.checkpoint()),
    )
  }
}

///|
test "window preparations reject repeated or competing commits and capture their own branches" {
  let session = footprint_window_session()
  let branch = session.fork()
  let first = session.prepare_ground(0L, [ground(0.5, 0.5)])
  let other = session.prepare_ground(0L, [ground(0.5, 0.5, id=2)])
  let independent = branch.prepare_ground(0L, [ground(0.5, 0.5, id=3)])
  let bundle = footprint_session_bundle(first.measurement())
  ignore(first.commit(bundle))
  let before = footprint_window_snapshot(session.checkpoint())
  invalid(() => ignore(first.commit(bundle)))
  invalid(() => {
    ignore(other.commit(footprint_session_bundle(other.measurement())))
  })
  ignore(
    independent.commit(footprint_session_bundle(independent.measurement())),
  )
  assert_eq(footprint_window_snapshot(session.checkpoint()), before)
  assert_eq(footprint_window_motion(branch.checkpoint()).tracks[0].track_id, 3)
}

///|
test "window candidate inspection and successful diagnostics deeply detach filter arrays" {
  let session = footprint_window_session()
  let prepared = session.prepare_ground(0L, [ground(0.5, 0.5)])
  let expected = @debug.to_string(prepared.measurement())
  let exposed = prepared.measurement()
  exposed.motion.tracks[0].filtered_state.unwrap()[0] = 999.0
  exposed.motion.tracks[0].filtered_covariance.unwrap()[0] = 999.0
  exposed.motion.closed_segment_ids.push("999")
  exposed.projection_failures.push({ track_id: 999, reason: "external", })
  exposed.motion.tracks.clear()
  assert_eq(@debug.to_string(prepared.measurement()), expected)
  let result = prepared.commit(footprint_session_bundle(prepared.measurement()))
  result.measurement.motion.tracks[0].filtered_state.unwrap()[0] = 888.0
  result.windows.statistics.current_window.zones.clear()
  assert_eq(
    footprint_window_motion(session.checkpoint()).tracks[0].state[0],
    0.5,
  )
  assert_eq(
    session.checkpoint().windows.current_window.unwrap().zones.length(),
    1,
  )
}

///|
test "complete window checkpoints exports and forks isolate nested pools and retained run arrays" {
  let session = footprint_window_session()
  for time in [0L, 100000L, 200000L] {
    ignore(footprint_window_step(session, time, [ground(0.5, 0.5)]))
  }
  let before = footprint_window_snapshot(session.checkpoint())
  let saved = session.checkpoint()
  let restored = @analysis.FootprintRunWindowSession::from_checkpoint(saved)
  let branch = session.fork()
  saved.windows.current_window.unwrap().zones[0].endings.clear()
  saved.windows.runs.states.clear()
  footprint_window_motion(saved).tracks[0].covariance[0] = 777.0
  assert_eq(footprint_window_snapshot(session.checkpoint()), before)
  assert_eq(footprint_window_snapshot(restored.checkpoint()), before)
  ignore(footprint_window_step(branch, 300000L, []))
  assert_eq(session.checkpoint().windows.runs.states.length(), 1)
  assert_eq(branch.checkpoint().windows.runs.states.length(), 0)
}

///|
test "window interrupt closes hidden tracks counts that single input and preserves next segment IDs" {
  let session = footprint_window_session()
  for time in [0L, 100000L] {
    ignore(
      footprint_window_step(session, time, [
        ground(0.5, 0.5),
        ground(0.5, 0.5, id=2),
      ]),
    )
  }
  ignore(footprint_window_step(session, 200000L, [ground(0.5, 0.5)]))
  assert_eq(footprint_window_motion(session.checkpoint()).tracks.length(), 2)
  let result = session.interrupt(300000L)
  assert_eq(result.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(result.windows.statistics.current_window.input_frames, 4L)
  assert_eq(
    result.windows.statistics.current_window.zones[0].endings[1].confirmed,
    1L,
  )
  assert_eq(footprint_window_motion(session.checkpoint()).tracks.length(), 0)
  let next = footprint_window_step(session, 400000L, [ground(0.5, 0.5, id=2)])
  assert_eq(next.measurement.motion.tracks[0].segment_id, "3")
  ignore(
    @analysis.FootprintRunWindowSession::from_checkpoint(session.checkpoint()),
  )
}

///|
test "smaller run capacity remains legal and late rejection preserves measurement and statistics" {
  let session = footprint_window_session(run_tracks=1)
  let before = footprint_window_snapshot(session.checkpoint())
  let candidate = session.prepare_ground(0L, [
    ground(0.5, 0.5),
    ground(0.5, 0.5, id=2),
  ])
  invalid(() => {
    ignore(candidate.commit(footprint_session_bundle(candidate.measurement())))
  })
  assert_eq(footprint_window_snapshot(session.checkpoint()), before)
  let corrected = footprint_window_step(session, 0L, [ground(0.5, 0.5, id=2)])
  assert_eq(corrected.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(corrected.windows.statistics.current_window.input_frames, 1L)
}

///|
test "wrong measurement mode raw identity conflicts and repeated time leave the complete owner unchanged" {
  let session = footprint_window_session()
  let pixels = @analysis.FootprintRunWindowSession::new(
    @analysis.FootprintRunSession::from_pixel(
      pixel_session(),
      footprint_session_monitor(),
    ),
    window_us=1000000L,
  )
  invalid(() => ignore(session.prepare_pixel(0L, [pixel(0.5, 0.5)])))
  invalid(() => ignore(pixels.prepare_ground(0L, [ground(0.5, 0.5)])))
  invalid(() => {
    ignore(session.prepare_ground(0L, [ground(0.5, 0.5), ground(0.5, 0.5)]))
  })
  invalid(() => ignore(session.reframed(@types.PixelTransform::new())))
  ignore(footprint_window_step(session, 0L, [ground(0.5, 0.5)]))
  let before = footprint_window_snapshot(session.checkpoint())
  invalid(() => ignore(session.prepare_ground(0L, [ground(0.5, 0.5)])))
  assert_eq(footprint_window_snapshot(session.checkpoint()), before)
}

///|
test "joint windows resume every cut across missing observations expiry and bucket skips" {
  let times = [0L, 100000L, 200000L, 300000L, 400000L, 900000L, 1000000L]
  let inputs = [
    [ground(0.5, 0.5)],
    [ground(0.5, 0.5)],
    [ground(0.5, 0.5)],
    [],
    [ground(0.5, 0.5)],
    [ground(0.5, 0.5)],
    [ground(0.5, 0.5)],
  ]
  let full = footprint_window_session(width=200000L)
  let expected : Array[String] = []
  for index, time in times {
    expected.push(
      @debug.to_string(footprint_window_step(full, time, inputs[index])),
    )
  }
  for cut in 0..<=times.length() {
    let prefix = footprint_window_session(width=200000L)
    for index in 0..<cut {
      ignore(footprint_window_step(prefix, times[index], inputs[index]))
    }
    let resumed = @analysis.FootprintRunWindowSession::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<times.length() {
      assert_eq(
        @debug.to_string(
          footprint_window_step(resumed, times[index], inputs[index]),
        ),
        expected[index],
      )
    }
    assert_eq(
      footprint_window_snapshot(resumed.checkpoint()),
      footprint_window_snapshot(full.checkpoint()),
    )
  }
}

///|
test "adjacent exact clocks above two to fifty third and terminal maximum buckets survive complete restore" {
  for first in [9007199254740992L, 9223372036854775805L] {
    let session = footprint_window_session(width=1L)
    for delta in [0L, 1L, 2L] {
      let result = footprint_window_step(session, first + delta, [
        ground(0.5, 0.5),
      ])
      assert_eq(
        result.windows.statistics.current_window.start_us,
        first + delta,
      )
      assert_eq(result.windows.statistics.current_window.input_frames, 1L)
      ignore(
        @analysis.FootprintRunWindowSession::from_checkpoint(
          session.checkpoint(),
        ),
      )
    }
    if first == 9223372036854775805L {
      assert_eq(
        session.checkpoint().windows.current_window.unwrap().end_exclusive_us,
        None,
      )
    }
  }
}

///|
test "warm Brown reframe and complete resume preserve metric runs window counts and continuation" {
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let session = @analysis.FootprintRunWindowSession::new(
    @analysis.FootprintRunSession::from_pixel(
      pixel_session(camera~),
      footprint_session_monitor(),
    ),
    window_us=200000L,
  )
  for time in [0L, 100000L, 200000L, 300000L] {
    let candidate = session.prepare_pixel(time, [pixel(0.5, 0.5)])
    ignore(candidate.commit(footprint_session_bundle(candidate.measurement())))
  }
  let transform = @types.PixelTransform::new(
    scale_x=2.0,
    scale_y=3.0,
    offset_x=4.0,
    offset_y=-2.0,
  )
  let reframed = session.reframed(transform)
  assert_eq(
    @debug.to_string(footprint_window_motion(reframed.checkpoint())),
    @debug.to_string(footprint_window_motion(session.checkpoint())),
  )
  assert_eq(
    @debug.to_string(reframed.checkpoint().windows.current_window),
    @debug.to_string(session.checkpoint().windows.current_window),
  )
  let restored = @analysis.FootprintRunWindowSession::from_checkpoint(
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
    @debug.to_string(first.windows.statistics),
    @debug.to_string(second.windows.statistics),
  )
  let p = first.measurement.motion.tracks[0].position.unwrap()
  let q = second.measurement.motion.tracks[0].position.unwrap()
  assert_true((p.x - q.x).abs() < 1.0e-12 && (p.y - q.y).abs() < 1.0e-12)
}

///|
test "pixel projection failure remains unavailable and counts its original missing-target ending" {
  let session = @analysis.FootprintRunWindowSession::new(
    @analysis.FootprintRunSession::from_pixel(
      pixel_session(),
      footprint_session_monitor(),
    ),
    window_us=1000000L,
  )
  for time in [0L, 100000L, 200000L, 300000L] {
    let prepared = session.prepare_pixel(time, [pixel(0.5, 0.5)])
    ignore(prepared.commit(footprint_session_bundle(prepared.measurement())))
  }
  let prepared = session.prepare_pixel(400000L, [pixel(100.0, 100.0)])
  let preview = prepared.measurement()
  preview.projection_failures.clear()
  let result = prepared.commit(@zones.FootprintAssignments::new(400000L, []))
  assert_eq(result.measurement.projection_failures.length(), 1)
  assert_eq(
    result.windows.runs.evidence.unavailable[0].reason,
    @zones.Position(@zones.RejectedProjection),
  )
  assert_eq(result.windows.statistics.current_window.input_frames, 5L)
  assert_eq(
    result.windows.statistics.current_window.zones[0].endings[3].unconfirmed,
    1L,
  )
  assert_eq(
    result.windows.statistics.current_window.zones[0].endings[3].confirmed,
    0L,
  )
  ignore(
    @analysis.FootprintRunWindowSession::from_checkpoint(session.checkpoint()),
  )
}

///|
test "empty raw observations are supplied window frames and skipped buckets remain unobserved" {
  let session = footprint_window_session(width=10L)
  ignore(footprint_window_step(session, 0L, []))
  ignore(footprint_window_step(session, 1L, []))
  let result = footprint_window_step(session, 100L, [])
  assert_eq(result.windows.statistics.closed_window.unwrap().input_frames, 2L)
  assert_eq(result.windows.statistics.unobserved_windows, 9L)
  assert_eq(result.windows.statistics.current_window.input_frames, 1L)
  assert_eq(result.windows.statistics.current_window.zones[0].started, 0L)
  ignore(
    @analysis.FootprintRunWindowSession::from_checkpoint(session.checkpoint()),
  )
}
