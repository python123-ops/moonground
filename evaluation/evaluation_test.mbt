///|
fn invalid(action : () -> Unit raise @types.GroundError) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid evaluation input was accepted")
  }
}

///|
fn track(
  id : Int32,
  time : Int64,
  x~ : Double = 0.0,
  y~ : Double = 0.0,
  speed~ : Double = 0.0,
  status~ : @motion.MotionStatus = @motion.Ready,
) -> @motion.TrackEstimate {
  let accepted = status is @motion.Initializing ||
    status is @motion.Ready ||
    status is @motion.Uncertain
  {
    track_id: id,
    segment_id: id.to_string(),
    status,
    position: if accepted {
      Some({ x, y, })
    } else {
      None
    },
    speed_mps: if status is @motion.Ready {
      Some(speed)
    } else {
      None
    },
    position_covariance: None,
    velocity: None,
    velocity_covariance: None,
    position_std_m: None,
    velocity_std_mps: None,
    observed_path_length_m: 0.0,
    net_displacement_m: 0.0,
    accepted_count: 1,
    last_accepted_timestamp_us: time,
    filtered_state: None,
    filtered_covariance: None,
  }
}

///|
fn frame(
  time : Int64,
  tracks : Array[@motion.TrackEstimate],
) -> @motion.FrameResult {
  {
    session_id: "evaluation",
    timestamp_us: time,
    tracks,
    closed_segment_ids: [],
  }
}

///|
fn reference(
  id : Int32,
  speed~ : Double? = Some(0.0),
) -> @evaluation.ReferenceSample raise @types.GroundError {
  @evaluation.ReferenceSample::new(id, { x: 0.0, y: 0.0, }, speed_mps?=speed)
}

///|
test "empty evaluation has no fabricated errors coverage or timestamps" {
  let report = @evaluation.EvaluationSession::new("evaluation").report()
  assert_eq(report.counts.frames, 0L)
  assert_eq(report.position_error_m.samples, 0)
  assert_eq(report.position_error_m.mean_absolute_error, None)
  assert_eq(report.position_error_m.root_mean_square_error, None)
  assert_eq(report.position_error_m.maximum_absolute_error, None)
  assert_eq(report.position_bias_m is None, true)
  assert_eq(report.position_coverage, None)
  assert_eq(report.speed_coverage, None)
  assert_eq(report.first_timestamp_us, None)
  assert_eq(report.last_timestamp_us, None)
}

///|
test "position norm and speed errors have hand computed statistics and signed bias" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  let a = @evaluation.ReferenceSample::new(
    1,
    { x: 0.0, y: 0.0, },
    speed_mps=3.0,
  )
  ignore(
    session.update(frame(0L, [track(1, 0L, x=3.0, y=4.0, speed=5.0)]), 0L, [a]),
  )
  let b = @evaluation.ReferenceSample::new(
    1,
    { x: 0.0, y: 0.0, },
    speed_mps=5.0,
  )
  let result = session.update(frame(1L, [track(1, 1L, speed=3.0)]), 1L, [b])
  assert_eq(result.position_error_m.mean_absolute_error, Some(2.5))
  if result.position_error_m.root_mean_square_error is Some(value) {
    assert_eq((value - 12.5.sqrt()).abs() < 1.0e-14, true)
  } else {
    fail("missing RMS")
  }
  assert_eq(result.position_bias_m.map(p => p.x), Some(1.5))
  assert_eq(result.position_bias_m.map(p => p.y), Some(2.0))
  assert_eq(result.speed_error_mps.mean_absolute_error, Some(2.0))
  assert_eq(result.speed_error_mps.root_mean_square_error, Some(2.0))
  assert_eq(result.speed_bias_mps, Some(0.0))
  assert_eq(result.position_coverage, Some(1.0))
  assert_eq(result.speed_coverage, Some(1.0))
}

///|
test "all missing and rejection causes remain in the reference denominators" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  let rows = [
    track(1, 0L, status=@motion.Initializing),
    track(2, 0L),
    track(3, 0L, status=@motion.Uncertain),
    track(4, 0L, status=@motion.RejectedInnovation),
    track(5, 0L, status=@motion.NumericalFailure),
    track(8, 0L),
  ]
  let report = session.update(
    frame(0L, rows),
    0L,
    Array::makei(7, i => reference(i + 1)),
    projection_failures=[6],
  )
  assert_eq(report.counts.references, 7)
  assert_eq(report.counts.measurements, 7)
  assert_eq(report.counts.without_reference, 1)
  assert_eq(report.counts.missing, 1)
  assert_eq(report.counts.initializing, 1)
  assert_eq(report.counts.ready, 1)
  assert_eq(report.counts.uncertain, 1)
  assert_eq(report.counts.rejected_innovation, 1)
  assert_eq(report.counts.numerical_failure, 1)
  assert_eq(report.counts.rejected_projection, 1)
  assert_eq(report.position_error_m.samples, 3)
  assert_eq(report.speed_error_mps.samples, 1)
  assert_eq(report.position_coverage, Some(3.0 / 7.0))
  assert_eq(report.speed_coverage, Some(1.0 / 7.0))
}

///|
test "ready outputs without reference speed do not invent speed truth" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  let report = session.update(frame(0L, [track(1, 0L, speed=50.0)]), 0L, [
    reference(1, speed=None),
  ])
  assert_eq(report.position_error_m.samples, 1)
  assert_eq(report.speed_error_mps.samples, 0)
  assert_eq(report.speed_error_mps.maximum_absolute_error, None)
  assert_eq(report.speed_bias_mps, None)
  assert_eq(report.speed_coverage, None)
}

///|
test "exact Int64 timestamps are aligned and failures retain the watermark" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  let time = 9007199254740993L
  invalid(() => ignore(session.update(frame(time, []), time - 1L, [])))
  assert_eq(session.report().counts.frames, 0L)
  ignore(session.update(frame(time, []), time, []))
  invalid(() => ignore(session.update(frame(time, []), time, [])))
  let other = { ..frame(time + 1L, []), session_id: "other", }
  invalid(() => ignore(session.update(other, time + 1L, [])))
  let report = session.update(
    frame(9223372036854775807L, []),
    9223372036854775807L,
    [],
  )
  assert_eq(report.first_timestamp_us, Some(time))
  assert_eq(report.last_timestamp_us, Some(9223372036854775807L))
  assert_eq(report.counts.frames, 2L)
}

///|
test "late duplicate references and arithmetic failures are atomic and retryable" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  let rows = [track(1, 0L, x=3.0), track(2, 0L, x=1.0e308)]
  invalid(() => {
    ignore(session.update(frame(0L, rows), 0L, [reference(1), reference(1)]))
  })
  let huge = @evaluation.ReferenceSample::new(2, { x: -1.0e308, y: 0.0, })
  invalid(() => {
    ignore(session.update(frame(0L, rows), 0L, [reference(1), huge]))
  })
  assert_eq(session.report().counts.frames, 0L)
  assert_eq(session.report().position_error_m.samples, 0)
  let good = session.update(frame(0L, [rows[0]]), 0L, [reference(1)])
  assert_eq(good.position_error_m.mean_absolute_error, Some(3.0))
}

///|
test "sample capacity accounts for unreferenced outputs and remains atomic" {
  let session = @evaluation.EvaluationSession::new("evaluation", max_samples=2)
  ignore(session.update(frame(0L, [track(8, 0L), track(9, 0L)]), 0L, []))
  invalid(() => {
    ignore(session.update(frame(1L, [track(1, 1L)]), 1L, [reference(1)]))
  })
  assert_eq(session.report().last_timestamp_us, Some(0L))
  let report = session.update(frame(1L, []), 1L, [reference(1), reference(2)])
  assert_eq(report.counts.without_reference, 2)
  assert_eq(report.counts.missing, 2)
  assert_eq(report.position_coverage, Some(0.0))
  assert_eq(report.position_error_m.mean_absolute_error, None)
}

///|
test "forks and returned reports retain independent numerical state" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  let rows = [track(1, 0L, x=2.0)]
  let refs = [reference(1)]
  let before = session.update(frame(0L, rows), 0L, refs)
  rows.clear()
  refs.clear()
  let branch = session.fork()
  ignore(branch.update(frame(1L, [track(1, 1L, x=4.0)]), 1L, [reference(1)]))
  assert_eq(branch.report().position_error_m.mean_absolute_error, Some(3.0))
  assert_eq(session.report().position_error_m.mean_absolute_error, Some(2.0))
  assert_eq(before.counts.frames, 1L)
}

///|
test "scaled RMS retains tiny errors and finite errors with overflowing squares" {
  for scale in [1.0e-200, 1.0e200] {
    let session = @evaluation.EvaluationSession::new("evaluation")
    let report = session.update(
      frame(0L, [track(1, 0L, x=3.0 * scale, y=4.0 * scale)]),
      0L,
      [reference(1)],
    )
    if report.position_error_m.root_mean_square_error is Some(value) {
      assert_eq((value / scale - 5.0).abs() < 1.0e-14, true)
    } else {
      fail("missing scaled RMS")
    }
  }
  let session = @evaluation.EvaluationSession::new("evaluation")
  ignore(
    session.update(frame(0L, [track(1, 0L, x=1.0e308)]), 0L, [reference(1)]),
  )
  let report = session.update(frame(1L, [track(1, 1L, x=-1.0e308)]), 1L, [
    reference(1),
  ])
  assert_eq(report.position_error_m.root_mean_square_error, Some(1.0e308))
  assert_eq(report.position_bias_m.map(p => p.x), Some(0.0))
  assert_eq(report.position_bias_m.map(p => p.y), Some(0.0))
}

///|
test "malformed measurements are checked even when no matching truth exists" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  let row = track(1, 0L)
  for
    bad in [
      { ..row, track_id: 0, },
      { ..row, position: None, },
      { ..row, speed_mps: Some(-1.0), },
      { ..row, position: Some({ x: 1.0 / 0.0, y: 0.0, }), },
      { ..row, last_accepted_timestamp_us: 1L, },
    ] {
    invalid(() => ignore(session.update(frame(0L, [bad]), 0L, [])))
  }
  invalid(() => ignore(session.update(frame(0L, [row, row]), 0L, [])))
  invalid(() => {
    ignore(session.update(frame(0L, [row]), 0L, [], projection_failures=[1]))
  })
  invalid(() => {
    ignore(session.update(frame(0L, []), 0L, [], projection_failures=[2, 2]))
  })
  assert_eq(session.report().counts.frames, 0L)
}

///|
test "evaluation constructors bound identities capacity and reference values" {
  for id in ["", String::make(129, 's')] {
    invalid(() => ignore(@evaluation.EvaluationSession::new(id)))
  }
  for limit in [0, 4097] {
    invalid(() => {
      ignore(@evaluation.EvaluationSession::new("evaluation", max_tracks=limit))
    })
  }
  invalid(() => {
    ignore(@evaluation.EvaluationSession::new("evaluation", max_samples=0))
  })
  invalid(() => ignore(reference(0)))
  for bad in [-1.0, 1.0 / 0.0, 0.0 / 0.0] {
    invalid(() => ignore(reference(1, speed=Some(bad))))
  }
}

///|
test "maximum evaluation frame and real estimator initialization are accepted" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  let rows = Array::makei(4096, i => track(i + 1, 0L))
  let refs = Array::makei(4096, i => reference(i + 1))
  let report = session.update(frame(0L, rows), 0L, refs)
  assert_eq(report.position_error_m.samples, 4096)
  rows.push(track(4097, 0L))
  invalid(() => {
    ignore(
      @evaluation.EvaluationSession::new("evaluation").update(
        frame(0L, rows),
        0L,
        [],
      ),
    )
  })
  let estimator = @motion.MotionEstimator::new(
    "evaluation",
    @motion.MotionConfig::new(),
  )
  let evaluation = @evaluation.EvaluationSession::new("evaluation")
  let observation = @types.GroundObservation::new(
    1,
    { x: 0.0, y: 0.0, },
    @types.Covariance2::isotropic(0.1),
  )
  for time in [0L, 200000L, 400000L] {
    ignore(
      evaluation.update(estimator.update(time, [observation]), time, [
        reference(1),
      ]),
    )
  }
  assert_eq(evaluation.report().position_error_m.samples, 3)
  assert_eq(evaluation.report().speed_error_mps.samples, 1)
}
