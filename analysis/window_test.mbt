///|
fn joint_windows(
  upstream~ : @analysis.EvidenceTransitSession = transit_ground(),
  width~ : Int64 = 1000000L,
  origin~ : Int64 = 0L,
  limits~ : Array[Int64] = [0L, 100000L, 200000L, 9223372036854775807L],
) -> @analysis.EvidenceTransitWindowSession raise @types.GroundError {
  @analysis.EvidenceTransitWindowSession::new(
    upstream,
    window_us=width,
    origin_us=origin,
    duration_limits_us=limits,
  )
}

///|
fn zero_joint_window_totals(
  saved : @transit.EvidenceTransitWindowCheckpoint,
) -> @transit.EvidenceTransitWindowCheckpoint {
  {
    ..saved,
    current_window: saved.current_window.map(window => {
      ..window,
      sections: window.sections.map(section => {
        ..section,
        completed: 0L,
        duration_limits: section.duration_limits.map(row => {
          ..row,
          within: 0L,
          exceeded: 0L,
          indeterminate: 0L,
        }),
      }),
    }),
  }
}

///|
test "joint raw ground updates equal the original transit and window chain and advance each stage once" {
  let original = transit_ground()
  let windows = @transit.EvidenceTransitWindowCounter::new(
    original.checkpoint().transit,
    window_us=1000000L,
    duration_limits_us=[0L, 100000L, 200000L, 9223372036854775807L],
  )
  let session = joint_windows(upstream=original)
  for index, y in [-1.0, 1.0, 3.0, 1.0, -1.0, 1.0, 3.0] {
    let time = index.to_int64() * 100000L
    let expected = original.update_ground(time, [ground(0.0, y)])
    let aggregate = windows.update(expected.transit)
    let actual = session.update_ground(time, [ground(0.0, y)])
    assert_eq(@debug.to_string(actual.analysis), @debug.to_string(expected))
    assert_eq(@debug.to_string(actual.windows), @debug.to_string(aggregate))
    assert_eq(actual.windows.current_window.input_frames, index.to_int64() + 1L)
  }
  assert_eq(
    @debug.to_string(session.checkpoint().analysis),
    @debug.to_string(original.checkpoint()),
  )
  assert_eq(
    @debug.to_string(session.checkpoint().windows),
    @debug.to_string(windows.checkpoint()),
  )
}

///|
test "raw Brown pixel joint windows retain projection failures and match the original component chain" {
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let original = @analysis.EvidenceTransitSession::from_pixel(
    pixel_session(camera~),
    session_transit_counter(),
  )
  let windows = @transit.EvidenceTransitWindowCounter::new(
    original.checkpoint().transit,
    window_us=250000L,
    duration_limits_us=[100000L, 300000L],
  )
  let session = joint_windows(upstream=original, width=250000L, limits=[
    100000L, 300000L,
  ])
  for
    index, observations in [
      [pixel(0.0, -1.0)],
      [pixel(0.0, 1.0)],
      [pixel(0.0, 3.0)],
      [pixel(100.0, 0.0)],
      [],
    ] {
    let time = index.to_int64() * 100000L
    let upstream = original.update_pixel(time, observations)
    let actual = session.update_pixel(time, observations)
    assert_eq(@debug.to_string(actual.analysis), @debug.to_string(upstream))
    assert_eq(
      @debug.to_string(actual.windows),
      @debug.to_string(windows.update(upstream.transit)),
    )
  }
  ignore(
    @analysis.EvidenceTransitWindowSession::from_checkpoint(
      session.checkpoint(),
    ),
  )
}

///|
test "new statistics baseline retains older pending entries without counting checkpoint history as a frame" {
  let original = pending_transit()
  let session = joint_windows(upstream=original, origin=100000L)
  let initial = session.checkpoint()
  assert_eq(initial.windows.baseline_timestamp_us, Some(100000L))
  assert_true(initial.windows.current_window is None)
  let restored = @analysis.EvidenceTransitWindowSession::from_checkpoint(
    initial,
  )
  let result = restored.update_ground(200000L, [ground(0.0, 3.0)])
  assert_eq(result.analysis.transit.passages.length(), 1)
  assert_eq(result.windows.current_window.input_frames, 1L)
  assert_eq(result.windows.current_window.sections[0].completed, 1L)
  assert_eq(result.windows.unobserved_windows, 0L)
  ignore(
    @analysis.EvidenceTransitWindowSession::from_checkpoint(
      restored.checkpoint(),
    ),
  )
}

///|
test "all complete joint checkpoint cuts preserve missing lost removed gap and cancellation windows" {
  let times = [
    0L, 100000L, 200000L, 300000L, 400000L, 500000L, 600000L, 700000L, 800000L, 1300000L,
  ]
  let inputs = [
    [ground(0.0, -1.0)],
    [ground(0.0, 1.0)],
    [ground(0.0, 3.0)],
    [ground(0.0, -1.0)],
    [ground(0.0, 1.0)],
    [],
    [ground(0.0, 3.0)],
    [],
    [ground(0.0, -1.0)],
    [ground(0.0, 3.0)],
  ]
  let full = joint_windows(width=250000L)
  let expected : Array[String] = []
  for index, observations in inputs {
    expected.push(
      @debug.to_string(
        full.update_ground(
          times[index],
          observations,
          lost=if index == 5 { [1] } else { [] },
          removed=if index == 7 { [1] } else { [] },
        ),
      ),
    )
  }
  let final_state = @debug.to_string(full.checkpoint())
  for cut in 0..<=inputs.length() {
    let prefix = joint_windows(width=250000L)
    for index in 0..<cut {
      ignore(
        prefix.update_ground(
          times[index],
          inputs[index],
          lost=if index == 5 { [1] } else { [] },
          removed=if index == 7 { [1] } else { [] },
        ),
      )
    }
    let restored = @analysis.EvidenceTransitWindowSession::from_checkpoint(
      prefix.checkpoint(),
    )
    for index in cut..<inputs.length() {
      assert_eq(
        @debug.to_string(
          restored.update_ground(
            times[index],
            inputs[index],
            lost=if index == 5 { [1] } else { [] },
            removed=if index == 7 { [1] } else { [] },
          ),
        ),
        expected[index],
      )
    }
    assert_eq(@debug.to_string(restored.checkpoint()), final_state)
  }
}

///|
test "a real late window origin rejection discards accepted motion and segment allocation" {
  let session = joint_windows(origin=100L)
  let before = @debug.to_string(session.checkpoint())
  // The original upstream can accept this frame, but statistics cannot.
  let upstream = transit_ground()
  assert_eq(
    upstream.update_ground(99L, [ground(0.0, -1.0)]).measurement.motion.tracks[0].segment_id,
    "1",
  )
  invalid(() => ignore(session.update_ground(99L, [ground(0.0, -1.0)])))
  invalid(() => ignore(session.update_ground(99L, [ground(0.0, -2.0)])))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let accepted = session.update_ground(100L, [ground(0.0, -1.0)])
  assert_eq(accepted.analysis.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(accepted.windows.current_window.input_frames, 1L)
  assert_eq(transit_motion(session.checkpoint().analysis).next_segment_id, 2L)
}

///|
test "late upstream numeric rejection preserves all window and measurement state before same-time correction" {
  let session = joint_windows()
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  let before = @debug.to_string(session.checkpoint())
  invalid(() => {
    ignore(
      session.update_ground(100000L, [
        ground(0.0, 1.0),
        evidence_observation(
          1.0,
          -1.0,
          @types.Covariance2::new(1.0, -0.9999999999999999, 1.0),
          id=2,
        ),
      ]),
    )
  })
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let retry = session.update_ground(100000L, [
    ground(0.0, 1.0),
    ground(1.0, -1.0, id=2),
  ])
  assert_eq(retry.analysis.measurement.motion.tracks[1].segment_id, "2")
  assert_eq(retry.analysis.transit.pending_count, 1)
  assert_eq(retry.windows.current_window.input_frames, 2L)
}

///|
test "exit exhaustion keeps pending entry window bucket covariance paths and new segment identity retryable" {
  let session = joint_windows()
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(100000L, [ground(0.0, 1.0)]))
  let saved = session.checkpoint()
  let gate = saved.analysis.transit.counting
  let exhausted = @analysis.EvidenceTransitWindowSession::from_checkpoint({
    ..saved,
    analysis: {
      ..saved.analysis,
      transit: {
        ..saved.analysis.transit,
        counting: {
          ..gate,
          counts: [
            gate.counts[0],
            { ..gate.counts[1], negative_to_positive: 9223372036854775807L, },
          ],
        },
      },
    },
  })
  let before = @debug.to_string(exhausted.checkpoint())
  invalid(() => {
    ignore(
      exhausted.update_ground(200000L, [
        ground(0.0, 3.0),
        ground(1.0, -1.0, id=2),
      ]),
    )
  })
  assert_eq(@debug.to_string(exhausted.checkpoint()), before)
  let retry = exhausted.update_ground(200000L, [
    ground(0.0, 1.0),
    ground(1.0, -1.0, id=2),
  ])
  assert_eq(retry.analysis.transit.pending_count, 1)
  assert_eq(retry.analysis.measurement.motion.tracks[1].segment_id, "2")
}

///|
test "mode structural capacity and time errors do not update either original component" {
  let session = joint_windows(
    upstream=transit_ground(max_tracks=2, counter_tracks=1),
  )
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.update_pixel(0L, [pixel(0.0, -1.0)])))
  invalid(() => ignore(session.reframed(@types.PixelTransform::new())))
  invalid(() => {
    ignore(
      session.update_ground(0L, [ground(0.0, -1.0), ground(1.0, -1.0, id=2)]),
    )
  })
  invalid(() => ignore(session.update_ground(-1L, [])))
  invalid(() => ignore(session.update_ground(0L, [ground(0.0, -1.0)], lost=[1])))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  let started = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.update_ground(0L, [])))
  assert_eq(@debug.to_string(session.checkpoint()), started)
}

///|
test "component checkpoints must bind exact gate section configuration policy watermark and lifetime counts" {
  let session = joint_windows()
  ignore(session.update_ground(0L, []))
  let saved = session.checkpoint()
  let source = saved.windows
  let alternate_gate = @events.LineGate::new(
    "entry",
    { x: -4.0, y: 0.0, },
    { x: 5.0, y: 0.0, },
    deadband_m=0.1,
  )
  for
    windows in [
      { ..source, session_id: "other", },
      { ..source, sigma_multiplier: 0.0, },
      {
        ..source,
        config: @events.GateConfig::new(max_tracks=10, max_gap_us=400000L),
      },
      {
        ..source,
        config: @events.GateConfig::new(max_tracks=10, max_position_std_m=1.0),
      },
      { ..source, gates: [source.gates[1], source.gates[0]], },
      { ..source, gates: [alternate_gate, source.gates[1]], },
      {
        ..source,
        sections: [
          @transit.Section::new(
            "aisle",
            "entry",
            @events.PositiveToNegative,
            "exit",
            @events.NegativeToPositive,
          ),
        ],
      },
      {
        ..source,
        last_timestamp_us: Some(1L),
        current_window: Some({
          ..source.current_window.unwrap(),
          last_timestamp_us: 1L,
        }),
      },
      { ..source, counts: [{ ..source.counts[0], completed: 1L, }], },
    ] {
    ignore(@transit.EvidenceTransitWindowCounter::from_checkpoint(windows))
    invalid(() => {
      ignore(
        @analysis.EvidenceTransitWindowSession::from_checkpoint({
          ..saved,
          windows,
        }),
      )
    })
  }
  invalid(() => {
    ignore(
      @analysis.EvidenceTransitWindowSession::from_checkpoint({
        ..saved,
        version: 2,
      }),
    )
  })
}

///|
test "saved accepted timestamps cannot be omitted from the current window but baseline history may be earlier" {
  let session = joint_windows()
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(1L, [ground(0.0, -1.0)]))
  let saved = session.checkpoint()
  let current = saved.windows.current_window.unwrap()
  let shortened = {
    ..saved.windows,
    current_window: Some({
      ..current,
      first_timestamp_us: 1L,
      input_frames: 1L,
    }),
  }
  ignore(@transit.EvidenceTransitWindowCounter::from_checkpoint(shortened))
  invalid(() => {
    ignore(
      @analysis.EvidenceTransitWindowSession::from_checkpoint({
        ..saved,
        windows: shortened,
      }),
    )
  })
  let seeded = { ..shortened, baseline_timestamp_us: Some(0L), }
  ignore(
    @analysis.EvidenceTransitWindowSession::from_checkpoint({
      ..saved,
      windows: seeded,
    }),
  )
}

///|
test "distinct accepted times across hidden tracks require enough frames without summing simultaneous track counts" {
  let session = joint_windows()
  ignore(
    session.update_ground(0L, [ground(0.0, -1.0), ground(1.0, -1.0, id=2)]),
  )
  ignore(
    session.update_ground(1L, [ground(0.0, -1.0), ground(1.0, -1.0, id=2)]),
  )
  ignore(session.update_ground(2L, [ground(0.0, -1.0)]))
  let saved = session.checkpoint()
  assert_eq(saved.windows.current_window.unwrap().input_frames, 3L)
  ignore(@analysis.EvidenceTransitWindowSession::from_checkpoint(saved))
  let current = saved.windows.current_window.unwrap()
  let fewer = {
    ..saved.windows,
    current_window: Some({ ..current, input_frames: 2L, }),
  }
  ignore(@transit.EvidenceTransitWindowCounter::from_checkpoint(fewer))
  invalid(() => {
    ignore(
      @analysis.EvidenceTransitWindowSession::from_checkpoint({
        ..saved,
        windows: fewer,
      }),
    )
  })
}

///|
test "exact accepted observation count bounds current samples even when only two endpoints were saved" {
  let session = joint_windows()
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(10L, [ground(0.0, -1.0)]))
  let saved = session.checkpoint()
  let motion = transit_motion(saved.analysis)
  let altered = {
    ..saved.analysis,
    measurement: Ground({
      ..motion,
      tracks: [{ ..motion.tracks[0], accepted_count: 10, }],
    }),
  }
  ignore(@analysis.EvidenceTransitSession::from_checkpoint(altered))
  invalid(() => {
    ignore(
      @analysis.EvidenceTransitWindowSession::from_checkpoint({
        ..saved,
        analysis: altered,
      }),
    )
  })
  let current = saved.windows.current_window.unwrap()
  let partial = {
    ..saved.windows,
    baseline_timestamp_us: Some(0L),
    current_window: Some({ ..current, first_timestamp_us: 1L, }),
  }
  ignore(@transit.EvidenceTransitWindowCounter::from_checkpoint(partial))
  invalid(() => {
    ignore(
      @analysis.EvidenceTransitWindowSession::from_checkpoint({
        ..saved,
        analysis: altered,
        windows: partial,
      }),
    )
  })
  let compatible = {
    ..saved.windows,
    baseline_timestamp_us: Some(8L),
    current_window: Some({ ..current, first_timestamp_us: 9L, }),
  }
  ignore(
    @analysis.EvidenceTransitWindowSession::from_checkpoint({
      ..saved,
      analysis: altered,
      windows: compatible,
    }),
  )
}

///|
test "a fresh joint origin forbids older accepted history while a started baseline permits it" {
  let session = joint_windows()
  for time in [0L, 100L, 200L] {
    ignore(session.update_ground(time, [ground(0.0, -1.0)]))
  }
  let saved = session.checkpoint()
  let current = saved.windows.current_window.unwrap()
  let changed = {
    ..saved.windows,
    origin_us: 100L,
    current_window: Some({
      ..current,
      start_us: 100L,
      end_exclusive_us: Some(1000100L),
      first_timestamp_us: 100L,
      input_frames: 2L,
    }),
  }
  ignore(@transit.EvidenceTransitWindowCounter::from_checkpoint(changed))
  invalid(() => {
    ignore(
      @analysis.EvidenceTransitWindowSession::from_checkpoint({
        ..saved,
        windows: changed,
      }),
    )
  })
  let seeded = {
    ..changed,
    baseline_timestamp_us: Some(100L),
    current_window: Some({
      ..changed.current_window.unwrap(),
      first_timestamp_us: 200L,
      input_frames: 1L,
    }),
  }
  ignore(
    @analysis.EvidenceTransitWindowSession::from_checkpoint({
      ..saved,
      windows: seeded,
    }),
  )
}

///|
test "the first possible statistics bucket cannot lose completed classifications while later buckets retain only their own outcomes" {
  let session = joint_windows(width=250000L)
  for (time, y) in [(0L, -1.0), (100000L, 1.0), (200000L, 3.0)] {
    ignore(session.update_ground(time, [ground(0.0, y)]))
  }
  let saved = session.checkpoint()
  let missing = zero_joint_window_totals(saved.windows)
  ignore(@transit.EvidenceTransitWindowCounter::from_checkpoint(missing))
  invalid(() => {
    ignore(
      @analysis.EvidenceTransitWindowSession::from_checkpoint({
        ..saved,
        windows: missing,
      }),
    )
  })
  ignore(session.update_ground(300000L, [ground(0.0, 3.0)]))
  assert_eq(
    session.checkpoint().windows.current_window.unwrap().sections[0].completed,
    0L,
  )
  assert_eq(session.checkpoint().windows.counts[0].completed, 1L)
  ignore(
    @analysis.EvidenceTransitWindowSession::from_checkpoint(
      session.checkpoint(),
    ),
  )
}

///|
test "a baseline at the bucket start or one microsecond before it cannot hide post-baseline completions" {
  for baseline in [99L, 100L] {
    let upstream = @analysis.EvidenceTransitSession::from_ground(
      @motion.MotionEstimator::new(
        "analysis",
        @motion.MotionConfig::new(q=1.0e20, gate=1.0e12),
      ),
      session_transit_counter(),
    )
    ignore(upstream.update_ground(baseline, [ground(0.0, -1.0)]))
    let session = joint_windows(upstream~, width=100L)
    ignore(session.update_ground(baseline + 1L, [ground(0.0, 1.0)]))
    ignore(session.update_ground(baseline + 30L, [ground(0.0, 3.0)]))
    let saved = session.checkpoint()
    let missing = zero_joint_window_totals(saved.windows)
    assert_eq(saved.windows.current_window.unwrap().sections[0].completed, 1L)
    ignore(@transit.EvidenceTransitWindowCounter::from_checkpoint(missing))
    invalid(() => {
      ignore(
        @analysis.EvidenceTransitWindowSession::from_checkpoint({
          ..saved,
          windows: missing,
        }),
      )
    })
  }
}

///|
test "window cancellation totals consume one shared entry budget per section including current pending entries" {
  let session = joint_windows()
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(100000L, [ground(0.0, 1.0)]))
  let saved = session.checkpoint()
  let current = saved.windows.current_window.unwrap()
  let row = current.sections[0]
  let windows = {
    ..saved.windows,
    current_window: Some({
      ..current,
      sections: [
        {
          ..row,
          cancellations: row.cancellations.map(reason => {
            ..reason,
            count: 1L,
          }),
        },
      ],
    }),
  }
  ignore(@transit.EvidenceTransitWindowCounter::from_checkpoint(windows))
  let gate = saved.analysis.transit.counting
  for budget in [5L, 6L] {
    let analysis = {
      ..saved.analysis,
      transit: {
        ..saved.analysis.transit,
        counting: {
          ..gate,
          counts: [
            { ..gate.counts[0], negative_to_positive: budget, },
            gate.counts[1],
          ],
        },
      },
    }
    ignore(@analysis.EvidenceTransitSession::from_checkpoint(analysis))
    if budget == 5L {
      invalid(() => {
        ignore(
          @analysis.EvidenceTransitWindowSession::from_checkpoint({
            ..saved,
            analysis,
            windows,
          }),
        )
      })
    } else {
      ignore(
        @analysis.EvidenceTransitWindowSession::from_checkpoint({
          ..saved,
          analysis,
          windows,
        }),
      )
    }
  }
}

///|
test "warm Brown reframing preserves full windows and metric pending state through complete recovery" {
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let original = joint_windows(
    upstream=@analysis.EvidenceTransitSession::from_pixel(
      pixel_session(camera~),
      session_transit_counter(),
    ),
    width=250000L,
  )
  ignore(original.update_pixel(0L, [pixel(0.0, -1.0)]))
  ignore(original.update_pixel(100000L, [pixel(0.0, 1.0)]))
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
    @debug.to_string(adapted.checkpoint().analysis.transit),
    @debug.to_string(before.analysis.transit),
  )
  let restored = @analysis.EvidenceTransitWindowSession::from_checkpoint(
    adapted.checkpoint(),
  )
  for index, y in [3.0, 1.0, -1.0, 1.0, 3.0] {
    let time = (index + 2).to_int64() * 100000L
    let observation = pixel(0.0, y)
    let actual = adapted.update_pixel(time, [observation.reframed(transform)])
    let expected = original.update_pixel(time, [observation])
    assert_eq(
      @debug.to_string(actual),
      @debug.to_string(
        restored.update_pixel(time, [observation.reframed(transform)]),
      ),
    )
    assert_eq(
      actual.analysis.transit.counts[0].completed,
      expected.analysis.transit.counts[0].completed,
    )
    assert_eq(
      actual.windows.current_window.sections[0].completed,
      expected.windows.current_window.sections[0].completed,
    )
  }
}

///|
test "interrupt cancels pending and hidden segments and counts exactly its empty confirmation frame" {
  let session = joint_windows()
  ignore(
    session.update_ground(0L, [ground(0.0, -1.0), ground(1.0, -1.0, id=2)]),
  )
  ignore(session.update_ground(100000L, [ground(0.0, 1.0)]))
  let frame = session.interrupt(200000L)
  assert_eq(frame.analysis.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(
    frame.analysis.transit.cancellations[0].reason,
    @transit.Discontinuity,
  )
  assert_eq(frame.windows.current_window.input_frames, 3L)
  assert_eq(frame.windows.current_window.sections[0].cancellations[0].count, 1L)
  assert_eq(transit_motion(session.checkpoint().analysis).next_segment_id, 3L)
  ignore(
    @analysis.EvidenceTransitWindowSession::from_checkpoint(
      session.checkpoint(),
    ),
  )
}

///|
test "checkpoint constructors forks and returned nested windows cannot alias mutable state" {
  let original = transit_ground()
  let limits = [0L, 200000L]
  let session = joint_windows(upstream=original, limits~)
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(100000L, [ground(0.0, 1.0)]))
  let branch = session.fork()
  let snapshot = session.checkpoint()
  let restored = @analysis.EvidenceTransitWindowSession::from_checkpoint(
    snapshot,
  )
  let before = @debug.to_string(session.checkpoint())
  limits.clear()
  snapshot.windows.current_window.unwrap().sections[0].duration_limits.clear()
  snapshot.analysis.transit.pending.clear()
  snapshot.windows.gates.clear()
  transit_motion(snapshot.analysis).tracks[0].state[0] = 999.0
  ignore(original.update_ground(0L, [ground(1.0, -1.0, id=2)]))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let output = branch.update_ground(200000L, [ground(0.0, 3.0)])
  let expected = restored.update_ground(200000L, [ground(0.0, 3.0)])
  assert_eq(@debug.to_string(output), @debug.to_string(expected))
  output.windows.current_window.sections[0].cancellations.clear()
  output.analysis.transit.passages.clear()
  assert_eq(
    @debug.to_string(branch.checkpoint()),
    @debug.to_string(restored.checkpoint()),
  )
}

///|
test "maximum exact confirmation clocks retain exclusive MAX and terminal windows through complete checkpoint restore" {
  let maximum = 9223372036854775807L
  let upstream = @analysis.EvidenceTransitSession::from_ground(
    @motion.MotionEstimator::new(
      "analysis",
      @motion.MotionConfig::new(q=1.0e20, gate=1.0e12),
    ),
    session_transit_counter(),
  )
  let session = joint_windows(upstream~, width=maximum)
  ignore(session.update_ground(maximum - 2L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(maximum - 1L, [ground(0.0, 1.0)]))
  let result = session.update_ground(maximum, [ground(0.0, 3.0)])
  assert_eq(
    result.windows.closed_window.unwrap().end_exclusive_us,
    Some(maximum),
  )
  assert_eq(result.windows.current_window.start_us, maximum)
  assert_true(result.windows.current_window.end_exclusive_us is None)
  assert_eq(result.analysis.transit.passages[0].elapsed_upper_us, 2L)
  ignore(
    @analysis.EvidenceTransitWindowSession::from_checkpoint(
      session.checkpoint(),
    ),
  )
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.interrupt(maximum)))
  assert_eq(@debug.to_string(session.checkpoint()), before)
}
