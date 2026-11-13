///|
fn guarded_windows(
  upstream~ : @guarded.EvidenceGuardedTransitSession = guarded_transit(),
  width~ : Int64 = 500000L,
  origin~ : Int64 = 0L,
) -> @guarded.EvidenceGuardedTransitWindowSession raise @types.GroundError {
  @guarded.EvidenceGuardedTransitWindowSession::new(
    upstream,
    window_us=width,
    duration_limits_us=[0L, 100000L, 200000L, 9223372036854775807L],
    origin_us=origin,
  )
}

///|
fn guarded_window_components(
  saved : @guarded.EvidenceGuardedTransitWindowCheckpoint,
) -> Unit raise @types.GroundError {
  ignore(@guarded.EvidenceGuardedTransitSession::from_checkpoint(saved.guarded))
  ignore(
    @analysis.EvidenceTransitWindowSession::from_checkpoint({
      version: 1,
      analysis: saved.guarded.analysis,
      windows: saved.windows,
    }),
  )
}

///|
test "health-controlled raw transit windows equal the original guarded host chain in every health state" {
  let upstream = guarded_transit()
  let downstream = @transit.EvidenceTransitWindowCounter::new(
    upstream.checkpoint().analysis.transit,
    window_us=250000L,
    duration_limits_us=[0L, 100000L, 200000L, 9223372036854775807L],
  )
  let joined = guarded_windows(upstream~, width=250000L)
  let reports = [
    landmarks(),
    landmarks(),
    landmarks(),
    landmarks(),
    landmarks(shift=0.5),
    landmarks(shift=0.5),
    [],
    landmarks(),
    landmarks(),
    landmarks(),
  ]
  for index, y in [-1.0, -1.0, 1.0, 3.0, -1.0, 1.0, 3.0, -1.0, 1.0, 3.0] {
    let time = index.to_int64() * 100000L
    let expected = upstream.update(time, reports[index], [pixel(1, y)])
    let actual = joined.update(time, reports[index], [pixel(1, y)])
    assert_eq(@debug.to_string(actual.guarded), @debug.to_string(expected))
    assert_eq(
      @debug.to_string(actual.windows),
      @debug.to_string(downstream.update(expected.analysis.transit)),
    )
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
        joined.checkpoint(),
      ),
    )
  }
  assert_eq(
    @debug.to_string(joined.checkpoint().guarded),
    @debug.to_string(upstream.checkpoint()),
  )
  assert_eq(
    @debug.to_string(joined.checkpoint().windows),
    @debug.to_string(downstream.checkpoint()),
  )
}

///|
test "every full checkpoint cut preserves suppression health confirmation passages missing frames and exact windows" {
  let times = [
    0L, 100000L, 200000L, 300000L, 400000L, 500000L, 600000L, 700000L, 800000L, 1300000L,
  ]
  let positions = [-1.0, -1.0, 1.0, 3.0, -1.0, 1.0, 3.0, -1.0, 1.0, 3.0]
  let reports = [
    landmarks(),
    landmarks(),
    landmarks(),
    landmarks(),
    landmarks(shift=0.5),
    landmarks(shift=0.5),
    [],
    landmarks(),
    landmarks(),
    landmarks(),
  ]
  let full = guarded_windows(width=250000L)
  let expected = positions.mapi((index, y) => {
    @debug.to_string(full.update(times[index], reports[index], [pixel(1, y)]))
  })
  for cut in 0..<=positions.length() {
    let prefix = guarded_windows(width=250000L)
    for index in 0..<cut {
      ignore(
        prefix.update(times[index], reports[index], [pixel(1, positions[index])]),
      )
    }
    let restored = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<positions.length() {
      assert_eq(
        @debug.to_string(
          restored.update(times[index], reports[index], [
            pixel(1, positions[index]),
          ]),
        ),
        expected[index],
      )
    }
    assert_eq(
      @debug.to_string(restored.checkpoint()),
      @debug.to_string(full.checkpoint()),
    )
  }
}

///|
test "blocked objects remain structural only and malformed payloads preserve all four stages" {
  let joined = guarded_windows(upstream=guarded_transit(multiplier=1.0e308))
  let extreme = @moonground.PixelObservation::new(
    3,
    { x: 100.0, y: 100.0, },
    @types.Covariance2::new(1.0, -0.9999999999999999, 1.0),
  )
  let frame = joined.update(0L, landmarks(), [extreme, pixel(1, 0.0)])
  assert_eq(frame.guarded.decision, @guarded.Blocked)
  assert_eq(frame.guarded.suppressed_track_ids, [1, 3])
  assert_eq(frame.guarded.analysis.measurement.projection_failures.length(), 0)
  assert_eq(frame.guarded.analysis.transit.counting.evidence.length(), 0)
  assert_eq(frame.windows.current_window.input_frames, 1L)
  let before = @debug.to_string(joined.checkpoint())
  for
    objects in [
      [pixel(1, 0.0), pixel(1, 1.0)],
      [
        @moonground.PixelObservation::{
          track_id: 1,
          position: { x: 0.0, y: 0.0, },
          covariance: { xx: 1.0, xy: 2.0, yy: 1.0, },
        },
      ],
    ] {
    invalid(() => ignore(joined.update(1L, [], objects)))
  }
  invalid(() => ignore(joined.update(1L, [], [], lost=[1], removed=[1])))
  invalid(() => ignore(joined.update(1L, [], [pixel(1, 0.0)], lost=[1])))
  invalid(() => ignore(joined.update(1L, [landmarks()[0], landmarks()[0]], [])))
  assert_eq(@debug.to_string(joined.checkpoint()), before)
}

///|
test "a real late origin failure rolls back both blocked and allowed health candidates" {
  for original in [guarded_transit(), guarded_transit_immediate()] {
    let session = guarded_windows(upstream=original, origin=100L)
    let before = @debug.to_string(session.checkpoint())
    let independently = original.update(99L, landmarks(), [pixel(1, -1.0)])
    assert_eq(independently.health.timestamp_us, 99L)
    invalid(() => ignore(session.update(99L, landmarks(), [pixel(1, -1.0)])))
    assert_eq(@debug.to_string(session.checkpoint()), before)
    assert_eq(
      guarded_transit_pixel(session.checkpoint().guarded).motion.next_segment_id,
      1L,
    )
    let next = session.update(100L, landmarks(), [pixel(1, -1.0)])
    assert_eq(next.windows.current_window.input_frames, 1L)
    assert_eq(next.guarded.health.streak_observations, 1)
    if next.guarded.decision == @guarded.Allowed {
      assert_eq(
        next.guarded.analysis.measurement.motion.tracks[0].segment_id,
        "1",
      )
    }
  }
}

///|
test "first Healthy evidence numeric failure preserves health progress windows and segment identity before same-time correction" {
  let joined = guarded_windows(
    upstream=guarded_transit(
      config=@health.HealthConfig::new(
        confirmation_us=200000L,
        min_observations=3,
      ),
      multiplier=1.0e308,
    ),
  )
  ignore(joined.update(0L, landmarks(), []))
  ignore(joined.update(100000L, landmarks(), []))
  let before = @debug.to_string(joined.checkpoint())
  let overflow = @moonground.PixelObservation::new(
    1,
    { x: 0.0, y: -1.0, },
    @types.Covariance2::isotropic(10.0),
  )
  invalid(() => ignore(joined.update(200000L, landmarks(), [overflow])))
  assert_eq(@debug.to_string(joined.checkpoint()), before)
  assert_eq(joined.checkpoint().guarded.health.streak.unwrap().observations, 2)
  let next = joined.update(200000L, landmarks(), [pixel(1, -1.0)])
  assert_eq(next.guarded.health.status, @health.Healthy)
  assert_eq(next.guarded.analysis.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(next.windows.current_window.input_frames, 3L)
}

///|
test "pending exit exhaustion preserves motion health and all window fields before same-time new identity retry" {
  let original = guarded_windows(upstream=guarded_transit_immediate())
  ignore(original.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(original.update(100000L, landmarks(), [pixel(1, 1.0)]))
  let saved = original.checkpoint()
  let transit = saved.guarded.analysis.transit
  let gate = transit.counting
  let session = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint({
    ..saved,
    guarded: {
      ..saved.guarded,
      analysis: {
        ..saved.guarded.analysis,
        transit: {
          ..transit,
          counting: {
            ..gate,
            counts: [
              gate.counts[0],
              { ..gate.counts[1], negative_to_positive: 9223372036854775807L, },
            ],
          },
        },
      },
    },
  })
  let before = @debug.to_string(session.checkpoint())
  invalid(() => {
    ignore(
      session.update(200000L, landmarks(), [pixel(1, 3.0), pixel(2, -1.0)]),
    )
  })
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let next = session.update(200000L, landmarks(), [
    pixel(1, 1.0),
    pixel(2, -1.0),
  ])
  assert_eq(next.guarded.analysis.transit.pending_count, 1)
  assert_eq(next.guarded.analysis.measurement.motion.tracks[1].segment_id, "2")
  assert_eq(next.windows.current_window.input_frames, 3L)
}

///|
test "the first pending drift sample closes hidden filters and cancels the same window input exactly once" {
  let joined = guarded_windows()
  ignore(joined.update(0L, landmarks(), []))
  ignore(joined.update(100000L, landmarks(), [pixel(1, -1.0), pixel(2, -1.0)]))
  ignore(joined.update(200000L, landmarks(), [pixel(1, 1.0)]))
  let blocked = joined.update(300000L, landmarks(shift=0.5), [pixel(1, 3.0)])
  assert_eq(blocked.guarded.health.status, @health.Pending)
  assert_eq(blocked.guarded.analysis.measurement.motion.closed_segment_ids, [
    "1", "2",
  ])
  assert_eq(
    blocked.guarded.analysis.transit.cancellations[0].reason,
    @transit.Discontinuity,
  )
  assert_eq(blocked.windows.current_window.input_frames, 4L)
  assert_eq(
    blocked.windows.current_window.sections[0].cancellations[0].count,
    1L,
  )
  ignore(joined.update(400000L, landmarks(), [pixel(1, 3.0)]))
  let next = joined.update(500000L, landmarks(), [pixel(1, 3.0)])
  assert_eq(next.guarded.analysis.measurement.motion.tracks[0].segment_id, "3")
  assert_eq(next.guarded.analysis.transit.passages.length(), 0)
}

///|
test "replacement counts one cold barrier while retaining pending cancellation totals multiplier options and next identity" {
  let joined = guarded_windows(
    upstream=guarded_transit_immediate(multiplier=3.0),
  )
  for index, y in [-1.0, 1.0, 3.0, -1.0, 1.0] {
    ignore(
      joined.update(
        index.to_int64() * 100000L,
        landmarks(),
        if index == 3 {
          [pixel(1, y), pixel(2, -1.0)]
        } else {
          [pixel(1, y)]
        },
      ),
    )
  }
  let before = joined.checkpoint()
  let barrier = joined.replace_projection(450000L, replacement(), camera=None)
  let after = joined.checkpoint()
  assert_eq(barrier.guarded.decision, @guarded.Blocked)
  assert_eq(barrier.guarded.health.status, @health.Insufficient)
  assert_eq(barrier.guarded.suppressed_track_ids, [])
  assert_eq(barrier.guarded.analysis.measurement.motion.closed_segment_ids, [
    "1", "2",
  ])
  assert_eq(barrier.windows.current_window.input_frames, 6L)
  assert_eq(
    barrier.windows.current_window.sections[0].cancellations[0].count,
    1L,
  )
  assert_eq(
    @debug.to_string(after.windows.baseline_counts),
    @debug.to_string(before.windows.baseline_counts),
  )
  assert_eq(after.windows.duration_limits_us, before.windows.duration_limits_us)
  assert_eq(after.guarded.analysis.transit.counting.sigma_multiplier, 3.0)
  assert_eq(
    @debug.to_string(after.guarded.analysis.transit.counts),
    @debug.to_string(before.guarded.analysis.transit.counts),
  )
  assert_eq(
    @debug.to_string(after.guarded.analysis.transit.counting.counts),
    @debug.to_string(before.guarded.analysis.transit.counting.counts),
  )
  assert_eq(guarded_transit_pixel(after.guarded).motion.next_segment_id, 3L)
  assert_true(after.guarded.health.streak is None)
  let restored = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
    after,
  )
  assert_eq(
    restored.update(500000L, scaled_landmarks(2.0), [pixel(1, 1.5)]).guarded.analysis.measurement.motion.tracks[0].segment_id,
    "3",
  )
}

///|
test "equal projection replacement still requires new confirmation and every barrier checkpoint cut resumes identically" {
  let original = guarded_windows()
  ignore(original.update(0L, landmarks(), []))
  ignore(original.update(100000L, landmarks(), [pixel(1, -1.0)]))
  ignore(original.update(200000L, landmarks(), [pixel(1, 1.0)]))
  let prefix = original.checkpoint()
  let barrier = original.replace_projection(250000L, calibration(), camera=None)
  assert_eq(barrier.windows.current_window.input_frames, 4L)
  let before_barrier = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
    prefix,
  )
  assert_eq(
    @debug.to_string(
      before_barrier.replace_projection(250000L, calibration(), camera=None),
    ),
    @debug.to_string(barrier),
  )
  let restored = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
    original.checkpoint(),
  )
  for index, time in [300000L, 400000L] {
    let next = original.update(time, landmarks(), [pixel(1, 3.0)])
    assert_eq(
      @debug.to_string(next),
      @debug.to_string(restored.update(time, landmarks(), [pixel(1, 3.0)])),
    )
    assert_eq(
      next.guarded.decision,
      if index == 0 {
        @guarded.Blocked
      } else {
        @guarded.Allowed
      },
    )
    assert_eq(next.guarded.analysis.transit.passages.length(), 0)
  }
}

///|
test "failed projection barriers preserve cold and warm health windows before a valid later replacement" {
  let unstarted = guarded_windows(origin=100L)
  let before = @debug.to_string(unstarted.checkpoint())
  invalid(() => {
    ignore(unstarted.replace_projection(99L, calibration(), camera=None))
  })
  assert_eq(@debug.to_string(unstarted.checkpoint()), before)
  ignore(unstarted.replace_projection(100L, calibration(), camera=None))
  let warm = guarded_windows(upstream=guarded_transit_immediate())
  ignore(warm.update(0L, landmarks(), [pixel(1, -1.0)]))
  let before = @debug.to_string(warm.checkpoint())
  invalid(() => ignore(warm.replace_projection(0L, replacement(), camera=None)))
  assert_eq(@debug.to_string(warm.checkpoint()), before)
  assert_eq(
    warm.replace_projection(1L, calibration(), camera=None).windows.current_window.input_frames,
    2L,
  )
}

///|
test "warm Brown reframing preserves health pending witnesses and entire window state in complete continuation" {
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let original = guarded_windows(
    upstream=guarded_transit(camera~),
    width=250000L,
  )
  ignore(original.update(0L, landmarks(), []))
  ignore(original.update(100000L, landmarks(), [pixel(1, -1.0)]))
  ignore(original.update(200000L, landmarks(), [pixel(1, 1.0)]))
  let before = original.checkpoint()
  let transform = @types.PixelTransform::new(
    scale_x=2.0,
    scale_y=0.5,
    offset_x=4.0,
    offset_y=-2.0,
  )
  let adapted = original.reframed(transform)
  assert_eq(
    @debug.to_string(adapted.checkpoint().windows),
    @debug.to_string(before.windows),
  )
  assert_eq(
    @debug.to_string(adapted.checkpoint().guarded.analysis.transit),
    @debug.to_string(before.guarded.analysis.transit),
  )
  let restored = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
    adapted.checkpoint(),
  )
  for index, y in [3.0, 1.0, -1.0, 1.0, 3.0] {
    let time = (index + 3).to_int64() * 100000L
    let actual = adapted.update(
      time,
      landmarks().map(item => item.reframed(transform)),
      [pixel(1, y).reframed(transform)],
    )
    assert_eq(
      @debug.to_string(actual),
      @debug.to_string(
        restored.update(
          time,
          landmarks().map(item => item.reframed(transform)),
          [pixel(1, y).reframed(transform)],
        ),
      ),
    )
    assert_eq(
      actual.guarded.analysis.transit.counts[0].completed,
      original.update(time, landmarks(), [pixel(1, y)]).guarded.analysis.transit.counts[0].completed,
    )
  }
}

///|
test "new owner restores inherited projection health and source policy constraints without loosening old checkpoints" {
  let session = guarded_windows(upstream=guarded_transit_immediate())
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  let saved = session.checkpoint()
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint({
        ..saved,
        version: 2,
      }),
    )
  })
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint({
        ..saved,
        guarded: {
          ..saved.guarded,
          health: { ..saved.guarded.health, streak: None, },
        },
      }),
    )
  })
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint({
        ..saved,
        guarded: {
          ..saved.guarded,
          health: { ..saved.guarded.health, calibration: replacement(), },
        },
      }),
    )
  })
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint({
        ..saved,
        windows: { ..saved.windows, sigma_multiplier: 3.0, },
      }),
    )
  })
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint({
        ..saved,
        windows: { ..saved.windows, session_id: "different", },
      }),
    )
  })
  assert_eq(@debug.to_string(session.checkpoint()), @debug.to_string(saved))
}

///|
test "health streak start cannot be omitted even while all objects are blocked" {
  let session = guarded_windows(
    upstream=guarded_transit(
      config=@health.HealthConfig::new(min_observations=10, confirmation_us=0L),
    ),
  )
  for time in [0L, 100L, 200L] {
    ignore(session.update(time, landmarks(), []))
  }
  let saved = session.checkpoint()
  let changed = {
    ..saved,
    windows: {
      ..saved.windows,
      current_window: Some({
        ..saved.windows.current_window.unwrap(),
        first_timestamp_us: 100L,
        input_frames: 2L,
      }),
    },
  }
  guarded_window_components(changed)
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(changed),
    )
  })
}

///|
test "saved health observations require their own frames beyond the two stored endpoints" {
  let session = guarded_windows(
    upstream=guarded_transit(
      config=@health.HealthConfig::new(min_observations=10, confirmation_us=0L),
    ),
  )
  for time in [0L, 100L, 200L] {
    ignore(session.update(time, landmarks(), []))
  }
  let saved = session.checkpoint()
  let changed = {
    ..saved,
    windows: {
      ..saved.windows,
      current_window: Some({
        ..saved.windows.current_window.unwrap(),
        input_frames: 2L,
      }),
    },
  }
  guarded_window_components(changed)
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(changed),
    )
  })
}

///|
test "known pre-streak frames cannot also supply the clamped current-streak observation lower bound" {
  let session = guarded_windows(
    upstream=guarded_transit(
      config=@health.HealthConfig::new(
        min_observations=3,
        confirmation_us=0L,
        max_gap_us=10L,
      ),
    ),
  )
  ignore(session.update(0L, [], []))
  for time in [2L, 6L, 10L] {
    ignore(session.update(time, landmarks(), []))
  }
  let saved = session.checkpoint()
  let changed = {
    ..saved,
    windows: {
      ..saved.windows,
      current_window: Some({
        ..saved.windows.current_window.unwrap(),
        input_frames: 3L,
      }),
    },
  }
  guarded_window_components(changed)
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(changed),
    )
  })
}

///|
test "saturated evidence still needs enough samples to sustain its complete health span" {
  let session = guarded_windows(
    upstream=guarded_transit(
      config=@health.HealthConfig::new(
        min_observations=1,
        confirmation_us=0L,
        max_gap_us=4L,
      ),
    ),
  )
  for time in [0L, 3L, 6L, 9L] {
    ignore(session.update(time, landmarks(), []))
  }
  let saved = session.checkpoint()
  assert_eq(saved.guarded.health.streak.unwrap().observations, 1)
  ignore(@guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(saved))
  let changed = {
    ..saved,
    windows: {
      ..saved.windows,
      current_window: Some({
        ..saved.windows.current_window.unwrap(),
        input_frames: 2L,
      }),
    },
  }
  guarded_window_components(changed)
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(changed),
    )
  })
}

///|
test "health gap budget is spent per known interval including hidden motion timestamps" {
  let session = guarded_windows(
    upstream=guarded_transit(
      config=@health.HealthConfig::new(
        min_observations=1,
        confirmation_us=0L,
        max_gap_us=4L,
      ),
    ),
  )
  for time in [0L, 2L, 4L, 6L, 8L] {
    ignore(
      session.update(
        time,
        landmarks(),
        if time == 4L {
          [pixel(1, -1.0)]
        } else {
          []
        },
      ),
    )
  }
  let saved = session.checkpoint()
  let changed = {
    ..saved,
    windows: {
      ..saved.windows,
      current_window: Some({
        ..saved.windows.current_window.unwrap(),
        input_frames: 4L,
      }),
    },
  }
  guarded_window_components(changed)
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(changed),
    )
  })
}

///|
test "the first post-cut sample must be reachable across bucket and baseline health continuity boundaries" {
  for baseline_cut in [false, true] {
    let upstream = guarded_transit(
      config=@health.HealthConfig::new(
        min_observations=1,
        confirmation_us=0L,
        max_gap_us=4L,
      ),
    )
    ignore(upstream.update(0L, landmarks(), []))
    if baseline_cut {
      ignore(upstream.update(3L, landmarks(), []))
      ignore(upstream.update(4L, landmarks(), []))
    }
    let session = guarded_windows(
      upstream~,
      width=if baseline_cut { 1000L } else { 5L },
    )
    if !baseline_cut {
      ignore(session.update(3L, landmarks(), []))
      ignore(session.update(4L, landmarks(), []))
    }
    ignore(session.update(7L, landmarks(), []))
    ignore(session.update(9L, landmarks(), []))
    let saved = session.checkpoint()
    ignore(@guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(saved))
    let changed = {
      ..saved,
      windows: {
        ..saved.windows,
        current_window: Some({
          ..saved.windows.current_window.unwrap(),
          first_timestamp_us: 8L,
          input_frames: 2L,
        }),
      },
    }
    guarded_window_components(changed)
    invalid(() => {
      ignore(
        @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(changed),
      )
    })
  }
}

///|
test "unsaturated health count is exact when the whole statistics window lies in the evidence streak" {
  let session = guarded_windows(
    upstream=guarded_transit(
      config=@health.HealthConfig::new(min_observations=4, confirmation_us=0L),
    ),
  )
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(2L, landmarks(), []))
  let saved = session.checkpoint()
  let changed = {
    ..saved,
    windows: {
      ..saved.windows,
      current_window: Some({
        ..saved.windows.current_window.unwrap(),
        input_frames: 3L,
      }),
    },
  }
  guarded_window_components(changed)
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(changed),
    )
  })
}

///|
test "exact health sample count must also reserve the minimum samples before the current window" {
  let session = guarded_windows(
    upstream=guarded_transit(
      config=@health.HealthConfig::new(
        min_observations=10,
        confirmation_us=0L,
        max_gap_us=4L,
      ),
    ),
    width=4L,
  )
  for time in [0L, 2L, 4L, 6L] {
    ignore(session.update(time, landmarks(), []))
  }
  let saved = session.checkpoint()
  ignore(@guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(saved))
  let changed = {
    ..saved,
    windows: {
      ..saved.windows,
      current_window: Some({
        ..saved.windows.current_window.unwrap(),
        input_frames: 3L,
      }),
    },
  }
  guarded_window_components(changed)
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(changed),
    )
  })
}

///|
test "started statistics baseline legitimately excludes older health samples and begins without an empty bucket" {
  let upstream = guarded_transit(
    config=@health.HealthConfig::new(
      min_observations=10,
      confirmation_us=0L,
      max_gap_us=4L,
    ),
  )
  for time in [0L, 2L, 4L] {
    ignore(upstream.update(time, landmarks(), []))
  }
  let session = guarded_windows(upstream~, origin=4L)
  assert_true(session.checkpoint().windows.current_window is None)
  let restored = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
    session.checkpoint(),
  )
  let next = restored.update(6L, landmarks(), [])
  assert_eq(next.windows.current_window.input_frames, 1L)
  assert_eq(next.guarded.health.streak_since_us, Some(0L))
  ignore(
    @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
      restored.checkpoint(),
    ),
  )
}

///|
test "fresh origin cannot hide a blocked health streak but an inherited baseline may precede current samples" {
  let session = guarded_windows()
  ignore(session.update(0L, landmarks(), []))
  ignore(session.update(100L, landmarks(), []))
  let saved = session.checkpoint()
  let changed = {
    ..saved,
    windows: {
      ..saved.windows,
      origin_us: 50L,
      current_window: Some({
        ..saved.windows.current_window.unwrap(),
        start_us: 50L,
        end_exclusive_us: Some(500050L),
        first_timestamp_us: 100L,
        input_frames: 1L,
      }),
    },
  }
  guarded_window_components(changed)
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(changed),
    )
  })
  let inherited = {
    ..changed,
    windows: { ..changed.windows, baseline_timestamp_us: Some(50L), },
  }
  ignore(
    @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(inherited),
  )
}

///|
test "health start shares one timestamp union with original accepted object witnesses across an instant restart" {
  let session = guarded_windows(
    upstream=guarded_transit(
      config=@health.HealthConfig::new(
        min_observations=1,
        confirmation_us=0L,
        max_gap_us=5L,
      ),
    ),
  )
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(session.update(5L, landmarks(), []))
  ignore(session.update(8L, landmarks(), [pixel(1, -1.0)]))
  let saved = session.checkpoint()
  assert_eq(saved.guarded.health.streak.unwrap().since_us, 5L)
  let changed = {
    ..saved,
    windows: {
      ..saved.windows,
      current_window: Some({
        ..saved.windows.current_window.unwrap(),
        input_frames: 2L,
      }),
    },
  }
  guarded_window_components(changed)
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(changed),
    )
  })
}

///|
test "constructor snapshots forks checkpoint arrays and returned statistics remain independently mutable" {
  let upstream = guarded_transit_immediate()
  let limits = [0L, 200000L]
  let session = @guarded.EvidenceGuardedTransitWindowSession::new(
    upstream,
    window_us=500000L,
    duration_limits_us=limits,
  )
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(session.update(100000L, landmarks(), [pixel(1, 1.0)]))
  let branch = session.fork()
  let snapshot = session.checkpoint()
  let restored = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
    snapshot,
  )
  let before = @debug.to_string(session.checkpoint())
  limits.clear()
  snapshot.windows.current_window.unwrap().sections[0].duration_limits.clear()
  snapshot.guarded.analysis.transit.pending.clear()
  snapshot.guarded.health.landmarks.clear()
  guarded_transit_pixel(snapshot.guarded).motion.tracks[0].state[0] = 999.0
  ignore(upstream.update(0L, landmarks(), []))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let actual = branch.update(200000L, landmarks(), [pixel(1, 3.0)])
  assert_eq(
    @debug.to_string(actual),
    @debug.to_string(restored.update(200000L, landmarks(), [pixel(1, 3.0)])),
  )
  actual.windows.current_window.sections[0].cancellations.clear()
  actual.guarded.analysis.transit.passages.clear()
  assert_eq(
    @debug.to_string(branch.checkpoint()),
    @debug.to_string(restored.checkpoint()),
  )
}

///|
test "MAX exact time one-microsecond health restart and terminal window preserve complete recovery" {
  let maximum = 9223372036854775807L
  let session = guarded_windows(
    upstream=guarded_transit(
      config=@health.HealthConfig::new(
        min_observations=1,
        confirmation_us=0L,
        max_gap_us=1L,
      ),
    ),
    width=maximum,
  )
  ignore(session.update(maximum - 1L, landmarks(), []))
  let next = session.update(maximum, landmarks(), [])
  assert_eq(next.guarded.health.streak_since_us, Some(maximum))
  assert_eq(next.windows.closed_window.unwrap().end_exclusive_us, Some(maximum))
  assert_true(next.windows.current_window.end_exclusive_us is None)
  assert_eq(next.windows.current_window.input_frames, 1L)
  ignore(
    @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
      session.checkpoint(),
    ),
  )
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.update(maximum, landmarks(), [])))
  invalid(() => {
    ignore(session.replace_projection(maximum, calibration(), camera=None))
  })
  assert_eq(@debug.to_string(session.checkpoint()), before)
}

///|
test "a started guarded pending entry and old health streak can complete after the fresh statistics baseline" {
  let upstream = guarded_transit_immediate()
  ignore(upstream.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(upstream.update(100000L, landmarks(), [pixel(1, 1.0)]))
  let joined = guarded_windows(upstream~, origin=100000L)
  assert_true(joined.checkpoint().windows.current_window is None)
  assert_eq(joined.checkpoint().windows.baseline_timestamp_us, Some(100000L))
  assert_eq(joined.checkpoint().guarded.analysis.transit.pending.length(), 1)
  let restored = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
    joined.checkpoint(),
  )
  let next = restored.update(200000L, landmarks(), [pixel(1, 3.0)])
  assert_eq(next.guarded.analysis.transit.passages.length(), 1)
  assert_eq(next.windows.current_window.input_frames, 1L)
  assert_eq(next.windows.current_window.sections[0].completed, 1L)
  ignore(
    @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
      restored.checkpoint(),
    ),
  )
}

///|
test "Brown camera installation removal and cold confirmation retain the original joint window history" {
  let joined = guarded_windows()
  ignore(joined.update(0L, landmarks(), []))
  ignore(joined.update(100000L, landmarks(), [pixel(1, -1.0)]))
  ignore(
    joined.replace_projection(
      200000L,
      brown_calibration(),
      camera=Some(brown_model()),
    ),
  )
  let installed = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
    joined.checkpoint(),
  )
  ignore(installed.update(250000L, brown_landmarks(), []))
  assert_eq(
    installed.update(350000L, brown_landmarks(), []).guarded.decision,
    @guarded.Allowed,
  )
  let before = installed.checkpoint()
  let barrier = installed.replace_projection(
    400000L,
    calibration(),
    camera=None,
  )
  assert_eq(barrier.guarded.health.status, @health.Insufficient)
  assert_eq(barrier.windows.current_window.input_frames, 6L)
  assert_true(
    guarded_transit_pixel(installed.checkpoint().guarded).camera is None,
  )
  assert_eq(
    installed.checkpoint().windows.baseline_timestamp_us,
    before.windows.baseline_timestamp_us,
  )
  let restored = @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint(
    installed.checkpoint(),
  )
  ignore(restored.update(450000L, landmarks(), []))
  assert_eq(
    restored.update(550000L, landmarks(), [pixel(1, -1.0)]).guarded.decision,
    @guarded.Allowed,
  )
  assert_eq(
    guarded_transit_pixel(restored.checkpoint().guarded).motion.next_segment_id,
    3L,
  )
}
