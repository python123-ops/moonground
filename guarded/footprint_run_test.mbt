///|
fn footprint_guard_analysis(
  max_tracks~ : Int32 = 10,
  run_tracks~ : Int32 = 10,
  camera? : @moonground.CameraModel,
  projection~ : @moonground.GroundCalibration = calibration(),
) -> @analysis.FootprintRunSession raise @types.GroundError {
  @analysis.FootprintRunSession::from_pixel(
    @moonground.MeasurementSession::new(
      "guarded",
      projection,
      @moonground.MotionConfig::new(
        max_tracks~,
        min_observations=2,
        min_span_us=0L,
        gate=1.0e12,
      ),
      camera?,
    ),
    @zones.FootprintRunMonitor::new(
      "guarded",
      [
        @zones.ConvexZone::new("area", [
          { x: -10.0, y: -10.0, },
          { x: 10.0, y: -10.0, },
          { x: 10.0, y: 10.0, },
          { x: -10.0, y: 10.0, },
        ]),
      ],
      @zones.FootprintRunConfig::new(min_samples=2L, confirmation_us=100000L),
      max_tracks=run_tracks,
    ),
  )
}

///|
fn footprint_guard_fresh(
  instant~ : Bool = false,
  camera? : @moonground.CameraModel,
  projection~ : @moonground.GroundCalibration = calibration(),
) -> @guarded.FootprintRunGuardedSession raise @types.GroundError {
  @guarded.FootprintRunGuardedSession::new(
    footprint_guard_analysis(camera?, projection~),
    monitor(
      config=@health.HealthConfig::new(
        confirmation_us=if instant { 0L } else { 100000L },
        min_observations=if instant { 1 } else { 2 },
      ),
      camera?,
      projection~,
    ),
  )
}

///|
fn footprint_guard_bundle(
  preview : @guarded.FootprintRunGuardedPreview,
  radius~ : Double = 0.125,
  shape? : @zones.FootprintShape,
) -> @zones.FootprintAssignments raise @types.GroundError {
  let shape = match shape {
    Some(shape) => shape
    None => @zones.Disk(@zones.DiskFootprint::new(radius))
  }
  @zones.FootprintAssignments::new(
    preview.measurement.motion.timestamp_us,
    preview.measurement.motion.tracks.map(track => {
      @zones.FootprintAssignment::new(track.track_id, track.segment_id, shape)
    }),
  )
}

///|
fn footprint_guard_step(
  owner : @guarded.FootprintRunGuardedSession,
  timestamp : Int64,
  landmarks : Array[@health.LandmarkObservation],
  objects : Array[@moonground.PixelObservation],
) -> @guarded.FootprintRunGuardedFrame raise @types.GroundError {
  let prepared = owner.prepare(timestamp, landmarks, objects)
  prepared.commit(footprint_guard_bundle(prepared.preview()))
}

///|
fn footprint_guard_snapshot(
  owner : @guarded.FootprintRunGuardedSession,
) -> String {
  let saved = owner.checkpoint()
  @debug.to_string(
    (
      saved.analysis.measurement,
      saved.health,
      saved.analysis.runs.last_timestamp_us,
      saved.analysis.runs.states.map(state => {
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
fn footprint_guard_pixel(
  saved : @guarded.FootprintRunGuardedCheckpoint,
) -> @moonground.MeasurementCheckpoint raise {
  guard saved.analysis.measurement is @analysis.Pixel(pixel) else {
    fail("pixel checkpoint missing")
  }
  pixel
}

///|
test "guarded footprint candidate reveals blocked emptiness and actual allowed identities without committing health" {
  let owner = footprint_guard_fresh()
  let before = footprint_guard_snapshot(owner)
  let prepared = owner.prepare(0L, landmarks(), [pixel(3, 0.5), pixel(1, 0.5)])
  let preview = prepared.preview()
  assert_eq(preview.decision, @guarded.Blocked)
  assert_eq(preview.health.status, @health.Pending)
  assert_eq(preview.suppressed_track_ids, [1, 3])
  assert_eq(preview.measurement.motion.tracks.length(), 0)
  assert_eq(footprint_guard_snapshot(owner), before)
  ignore(prepared.commit(footprint_guard_bundle(preview)))
  assert_eq(
    footprint_guard_pixel(owner.checkpoint()).motion.next_segment_id,
    1L,
  )
  let allowed = owner.prepare(100000L, landmarks(), [
    pixel(3, 0.5),
    pixel(1, 0.5),
  ])
  let preview = allowed.preview()
  assert_eq(preview.decision, @guarded.Allowed)
  assert_eq(preview.measurement.motion.tracks.map(track => track.track_id), [
    1, 3,
  ])
  assert_eq(preview.measurement.motion.tracks.map(track => track.segment_id), [
    "1", "2",
  ])
  ignore(allowed.commit(footprint_guard_bundle(preview)))
  assert_eq(owner.checkpoint().health.last_timestamp_us, Some(100000L))
}

///|
test "first confirmed health and new segment allocation roll back on a wrong assignment and retry same candidate" {
  let owner = footprint_guard_fresh()
  ignore(footprint_guard_step(owner, 0L, landmarks(), [pixel(1, 0.5)]))
  let before = footprint_guard_snapshot(owner)
  let prepared = owner.prepare(100000L, landmarks(), [pixel(1, 0.5)])
  assert_eq(prepared.preview().health.status, @health.Healthy)
  let bad = @zones.FootprintAssignments::new(100000L, [
    @zones.FootprintAssignment::new(
      1,
      "99",
      @zones.Disk(@zones.DiskFootprint::new(0.125)),
    ),
  ])
  invalid(() => ignore(prepared.commit(bad)))
  assert_eq(footprint_guard_snapshot(owner), before)
  assert_eq(owner.checkpoint().health.streak.unwrap().observations, 1)
  assert_eq(
    footprint_guard_pixel(owner.checkpoint()).motion.next_segment_id,
    1L,
  )
  let result = prepared.commit(footprint_guard_bundle(prepared.preview()))
  assert_eq(result.health.status, @health.Healthy)
  assert_eq(result.analysis.measurement.motion.tracks[0].segment_id, "1")
}

///|
test "blocked guarded footprint commit rejects nonempty or wrong clock without discarding the preparation" {
  let owner = footprint_guard_fresh()
  let prepared = owner.prepare(0L, landmarks(), [pixel(1, 100.0, x=100.0)])
  let before = footprint_guard_snapshot(owner)
  let nonempty = @zones.FootprintAssignments::new(0L, [
    @zones.FootprintAssignment::new(
      1,
      "1",
      @zones.Disk(@zones.DiskFootprint::new(1.0e308)),
    ),
  ])
  invalid(() => ignore(prepared.commit(nonempty)))
  invalid(() => {
    ignore(prepared.commit(@zones.FootprintAssignments::new(1L, [])))
  })
  assert_eq(footprint_guard_snapshot(owner), before)
  let result = prepared.commit(@zones.FootprintAssignments::new(0L, []))
  assert_eq(result.decision, @guarded.Blocked)
  assert_eq(result.analysis.measurement.projection_failures.length(), 0)
  assert_eq(result.analysis.runs.evidence.evidence.length(), 0)
}

///|
test "blocked guarded footprint payloads validate raw covariance identities capacity and conflicts before health" {
  let owner = footprint_guard_fresh()
  let before = footprint_guard_snapshot(owner)
  let raw = pixel(1, 0.5)
  for
    observations in [
      [{ ..raw, covariance: { xx: 1.0, xy: 2.0, yy: 1.0, }, }],
      [raw, raw],
      [{ ..raw, position: { x: 1.0 / 0.0, y: 0.0, }, }],
      [{ ..raw, track_id: 0, }],
    ] {
    invalid(() => ignore(owner.prepare(0L, landmarks(), observations)))
  }
  invalid(() => ignore(owner.prepare(0L, landmarks(), [raw], lost=[1])))
  invalid(() => {
    ignore(owner.prepare(0L, landmarks(), [], lost=[1], removed=[1]))
  })
  invalid(() => {
    ignore(
      owner.prepare(
        0L,
        landmarks(),
        Array::makei(11, i => { ..raw, track_id: i + 1, }),
      ),
    )
  })
  assert_eq(footprint_guard_snapshot(owner), before)
}

///|
test "guarded footprint used and competing candidates cannot commit again after any successful frame" {
  let owner = footprint_guard_fresh()
  let first = owner.prepare(0L, landmarks(), [])
  let other = owner.prepare(1L, landmarks(), [pixel(2, 0.5)])
  ignore(first.commit(footprint_guard_bundle(first.preview())))
  let before = footprint_guard_snapshot(owner)
  invalid(() => ignore(first.commit(footprint_guard_bundle(first.preview()))))
  invalid(() => ignore(other.commit(footprint_guard_bundle(other.preview()))))
  assert_eq(footprint_guard_snapshot(owner), before)
}

///|
test "guarded footprint preview health suppressed arrays and nested measurement diagnostics are detached" {
  let owner = footprint_guard_fresh()
  let blocked = owner.prepare(0L, landmarks(), [pixel(1, 0.5)])
  let expected = @debug.to_string(blocked.preview())
  let preview = blocked.preview()
  preview.health.landmarks.clear()
  preview.suppressed_track_ids.clear()
  preview.measurement.motion.closed_segment_ids.push("999")
  assert_eq(@debug.to_string(blocked.preview()), expected)
  ignore(blocked.commit(footprint_guard_bundle(blocked.preview())))
  let allowed = owner.prepare(100000L, landmarks(), [pixel(1, 0.5)])
  let expected = @debug.to_string(allowed.preview())
  let preview = allowed.preview()
  preview.measurement.motion.tracks[0].filtered_state.unwrap()[0] = 999.0
  preview.measurement.motion.tracks[0].filtered_covariance.unwrap()[0] = 999.0
  preview.measurement.motion.tracks.clear()
  assert_eq(@debug.to_string(allowed.preview()), expected)
  ignore(allowed.commit(footprint_guard_bundle(allowed.preview())))
  assert_true(
    footprint_guard_pixel(owner.checkpoint()).motion.tracks[0].state[0] != 999.0,
  )
}

///|
test "instant health restart with Ready motion rolls back new health streak on late footprint numerical rejection" {
  let owner = @guarded.FootprintRunGuardedSession::new(
    footprint_guard_analysis(),
    monitor(
      config=@health.HealthConfig::new(
        min_observations=1,
        confirmation_us=0L,
        max_gap_us=150000L,
      ),
    ),
  )
  for time in [0L, 100000L] {
    ignore(footprint_guard_step(owner, time, landmarks(), [pixel(1, 0.5)]))
  }
  let before = footprint_guard_snapshot(owner)
  let prepared = owner.prepare(300000L, landmarks(), [
    pixel(1, 0.5),
    pixel(2, 0.5),
  ])
  assert_eq(prepared.preview().health.streak_since_us, Some(300000L))
  assert_eq(
    prepared.preview().measurement.motion.tracks[0].status,
    @motion.Ready,
  )
  invalid(() => {
    ignore(
      prepared.commit(
        footprint_guard_bundle(prepared.preview(), radius=1.0e-300),
      ),
    )
  })
  assert_eq(footprint_guard_snapshot(owner), before)
  assert_eq(owner.checkpoint().health.streak.unwrap().since_us, 0L)
  assert_eq(
    footprint_guard_pixel(owner.checkpoint()).motion.next_segment_id,
    2L,
  )
  let result = prepared.commit(footprint_guard_bundle(prepared.preview()))
  assert_eq(result.health.streak_since_us, Some(300000L))
  assert_eq(result.analysis.measurement.motion.tracks[1].segment_id, "2")
  ignore(
    @guarded.FootprintRunGuardedSession::from_checkpoint(owner.checkpoint()),
  )
}

///|
test "pending drift insufficient and recovery interrupt runs immediately with fresh motion warmup" {
  let owner = footprint_guard_fresh()
  for time in [0L, 100000L, 200000L] {
    ignore(footprint_guard_step(owner, time, landmarks(), [pixel(1, 0.5)]))
  }
  let pending = footprint_guard_step(owner, 250000L, landmarks(shift=0.5), [
    pixel(1, 0.5),
  ])
  assert_eq(pending.health.status, @health.Pending)
  assert_eq(pending.analysis.runs.closed[0].reason, @zones.SegmentClosed)
  assert_eq(pending.analysis.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(
    footprint_guard_step(owner, 350000L, landmarks(shift=0.5), []).health.status,
    @health.Drift,
  )
  assert_eq(
    footprint_guard_step(owner, 400000L, landmarks(), []).decision,
    @guarded.Blocked,
  )
  let recovered = footprint_guard_step(owner, 500000L, landmarks(), [
    pixel(1, 0.5),
  ])
  assert_eq(recovered.decision, @guarded.Allowed)
  assert_eq(recovered.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(recovered.analysis.runs.active.length(), 0)
  let missing = footprint_guard_step(owner, 600000L, [], [pixel(1, 0.5)])
  assert_eq(missing.health.status, @health.Insufficient)
  assert_eq(missing.analysis.measurement.motion.closed_segment_ids, ["2"])
  ignore(
    @guarded.FootprintRunGuardedSession::from_checkpoint(owner.checkpoint()),
  )
}

///|
test "blocked footprint preparation closes all hidden tracks and preserves old run closure priorities" {
  let owner = footprint_guard_fresh(instant=true)
  for time in [0L, 100000L] {
    ignore(
      footprint_guard_step(owner, time, landmarks(), [
        pixel(1, 0.5),
        pixel(2, 0.5),
      ]),
    )
  }
  ignore(footprint_guard_step(owner, 200000L, landmarks(), [pixel(1, 0.5)]))
  let before = footprint_guard_snapshot(owner)
  let prepared = owner.prepare(300000L, [], [pixel(7, 100.0)])
  assert_eq(prepared.preview().measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(prepared.preview().suppressed_track_ids, [7])
  assert_eq(footprint_guard_snapshot(owner), before)
  let result = prepared.commit(footprint_guard_bundle(prepared.preview()))
  assert_eq(result.analysis.runs.closed[0].reason, @zones.SegmentClosed)
  assert_eq(result.analysis.runs.active.length(), 0)
  assert_eq(footprint_guard_pixel(owner.checkpoint()).motion.tracks.length(), 0)
  assert_eq(
    footprint_guard_pixel(owner.checkpoint()).motion.next_segment_id,
    3L,
  )
}

///|
test "guarded footprint health fatal input and conflicting object IDs preserve all components" {
  let owner = footprint_guard_fresh(instant=true)
  ignore(footprint_guard_step(owner, 0L, landmarks(), [pixel(1, 0.5)]))
  let before = footprint_guard_snapshot(owner)
  invalid(() => {
    ignore(
      owner.prepare(100000L, [landmarks()[0], landmarks()[0]], [pixel(1, 0.5)]),
    )
  })
  invalid(() => {
    ignore(
      owner.prepare(
        100000L,
        [
          @health.LandmarkObservation::new(
            "unknown",
            { x: 0.0, y: 0.0, },
            @types.Covariance2::isotropic(0.1),
          ),
        ],
        [pixel(1, 0.5)],
      ),
    )
  })
  invalid(() => ignore(owner.prepare(0L, landmarks(), [pixel(1, 0.5)])))
  assert_eq(footprint_guard_snapshot(owner), before)
  ignore(footprint_guard_step(owner, 100000L, landmarks(), [pixel(1, 0.5)]))
}

///|
test "returned guarded footprint evidence faces vertices and arrays cannot mutate private preparation or committed state" {
  let owner = footprint_guard_fresh(instant=true)
  ignore(footprint_guard_step(owner, 0L, landmarks(), [pixel(1, 0.5)]))
  let prepared = owner.prepare(100000L, landmarks(), [pixel(1, 0.5)])
  let shape : @zones.FootprintShape = @zones.Convex(
    @zones.ConvexFootprint::new([
      { x: -0.125, y: -0.125, },
      { x: 0.125, y: -0.125, },
      { x: 0.125, y: 0.125, },
      { x: -0.125, y: 0.125, },
    ]),
  )
  let expected_preview = @debug.to_string(prepared.preview())
  let result = prepared.commit(
    footprint_guard_bundle(prepared.preview(), shape~),
  )
  let before = footprint_guard_snapshot(owner)
  guard result.analysis.runs.evidence.evidence[0].evidence
    is @zones.Convex(band) else {
    fail("convex evidence missing")
  }
  band.faces.clear()
  band.vertices_offset_m.clear()
  result.health.landmarks.clear()
  result.suppressed_track_ids.push(999)
  result.analysis.measurement.motion.tracks[0].filtered_covariance.unwrap()[0] = 999.0
  result.analysis.runs.active.clear()
  result.analysis.runs.confirmed.clear()
  result.analysis.runs.closed.clear()
  result.analysis.runs.evidence.evidence.clear()
  assert_eq(footprint_guard_snapshot(owner), before)
  assert_eq(@debug.to_string(prepared.preview()), expected_preview)
  ignore(
    @guarded.FootprintRunGuardedSession::from_checkpoint(owner.checkpoint()),
  )
}

///|
test "guarded footprint fork and exported checkpoints detach original ownership and retained arrays" {
  let owner = footprint_guard_fresh(instant=true)
  for time in [0L, 100000L] {
    ignore(footprint_guard_step(owner, time, landmarks(), [pixel(1, 0.5)]))
  }
  let before = footprint_guard_snapshot(owner)
  let branch = owner.fork()
  let prepared = branch.prepare(200000L, [], [pixel(1, 0.5)])
  ignore(prepared.commit(footprint_guard_bundle(prepared.preview())))
  let saved = owner.checkpoint()
  saved.analysis.runs.states.clear()
  saved.analysis.runs.zones.clear()
  saved.health.landmarks.clear()
  footprint_guard_pixel(saved).motion.tracks[0].state[0] = 999.0
  assert_eq(footprint_guard_snapshot(owner), before)
  assert_eq(branch.checkpoint().analysis.runs.states.length(), 0)
  assert_eq(owner.checkpoint().analysis.runs.states.length(), 1)
}

///|
test "warm Brown footprint guard reframes health objects and complete recovery in the same metric frame" {
  let owner = footprint_guard_fresh(
    instant=true,
    camera=brown_model(),
    projection=brown_calibration(),
  )
  for time in [0L, 100000L, 200000L] {
    ignore(
      footprint_guard_step(owner, time, brown_landmarks(), [
        pixel(1, 200.0, x=300.0),
      ]),
    )
  }
  let before = owner.checkpoint()
  let transform = @types.PixelTransform::new(
    scale_x=0.5,
    scale_y=0.75,
    offset_x=-4.0,
    offset_y=2.0,
  )
  let changed = owner.reframed(transform)
  assert_eq(
    @debug.to_string(footprint_guard_pixel(changed.checkpoint()).motion),
    @debug.to_string(footprint_guard_pixel(before).motion),
  )
  assert_eq(
    @debug.to_string(
      changed.checkpoint().analysis.runs.states.map(state => state.run),
    ),
    @debug.to_string(before.analysis.runs.states.map(state => state.run)),
  )
  let restored = @guarded.FootprintRunGuardedSession::from_checkpoint(
    changed.checkpoint(),
  )
  let refs = brown_landmarks().map(observation => {
    observation.reframed(transform)
  })
  let object = pixel(1, 200.0, x=300.0).reframed(transform)
  let result = footprint_guard_step(restored, 300000L, refs, [object])
  assert_eq(result.decision, @guarded.Allowed)
  assert_eq(result.analysis.runs.active[0].sample_count, 3L)
  assert_eq(owner.checkpoint().health.last_timestamp_us, Some(200000L))
}

///|
test "projection replacement closes runs clears hidden tracks and makes staged candidates stale while confirmation restarts" {
  let owner = footprint_guard_fresh()
  for time in [0L, 100000L, 200000L] {
    ignore(footprint_guard_step(owner, time, landmarks(), [pixel(1, 0.5)]))
  }
  let pending = owner.prepare(300000L, landmarks(), [pixel(1, 0.5)])
  let before = footprint_guard_snapshot(owner)
  invalid(() => {
    ignore(owner.replace_projection(200000L, replacement(), camera=None))
  })
  assert_eq(footprint_guard_snapshot(owner), before)
  let result = owner.replace_projection(250000L, replacement(), camera=None)
  assert_eq(result.decision, @guarded.Blocked)
  assert_eq(result.health.status, @health.Insufficient)
  assert_eq(result.suppressed_track_ids, [])
  assert_eq(result.analysis.runs.closed[0].reason, @zones.SegmentClosed)
  assert_eq(result.analysis.measurement.motion.closed_segment_ids, ["1"])
  invalid(() => {
    ignore(pending.commit(footprint_guard_bundle(pending.preview())))
  })
  let saved = owner.checkpoint()
  assert_eq(saved.analysis.runs.states.length(), 0)
  assert_eq(saved.analysis.runs.config.min_samples, 2L)
  assert_eq(footprint_guard_pixel(saved).motion.next_segment_id, 2L)
  let resumed = @guarded.FootprintRunGuardedSession::from_checkpoint(saved)
  assert_eq(
    footprint_guard_step(resumed, 300000L, scaled_landmarks(2.0), [
      pixel(1, 0.25),
    ]).decision,
    @guarded.Blocked,
  )
  let allowed = footprint_guard_step(resumed, 400000L, scaled_landmarks(2.0), [
    pixel(1, 0.25),
  ])
  assert_eq(allowed.decision, @guarded.Allowed)
  assert_eq(allowed.analysis.measurement.motion.tracks[0].segment_id, "2")
}

///|
test "equal projection replacement still resets warm health and discards all retained runs" {
  let owner = footprint_guard_fresh(instant=true)
  for time in [0L, 100000L] {
    ignore(footprint_guard_step(owner, time, landmarks(), [pixel(1, 0.5)]))
  }
  let old = owner.checkpoint()
  let result = owner.replace_projection(
    200000L,
    footprint_guard_pixel(old).calibration,
    camera=footprint_guard_pixel(old).camera,
  )
  assert_eq(result.health.status, @health.Insufficient)
  assert_true(owner.checkpoint().health.streak is None)
  assert_eq(owner.checkpoint().analysis.runs.states.length(), 0)
  let frame = footprint_guard_step(owner, 300000L, landmarks(), [pixel(1, 0.5)])
  assert_eq(frame.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(frame.analysis.runs.active.length(), 0)
}

///|
test "guarded footprint exact timestamp adjacent frames preserve preparation clocks near Int64 maximum" {
  for first in [9007199254740992L, 9223372036854775805L] {
    let owner = footprint_guard_fresh(instant=true)
    for delta in [0L, 1L, 2L] {
      let result = footprint_guard_step(owner, first + delta, landmarks(), [
        pixel(1, 0.5),
      ])
      assert_eq(result.health.timestamp_us, first + delta)
      assert_eq(result.analysis.measurement.motion.timestamp_us, first + delta)
    }
    assert_eq(owner.checkpoint().analysis.runs.states[0].run.sample_count, 2L)
    ignore(
      @guarded.FootprintRunGuardedSession::from_checkpoint(owner.checkpoint()),
    )
  }
}
