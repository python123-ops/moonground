///|
test "acceptance requires a channel and an explicit error bound" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  invalid(() => ignore(session.assess()))
  invalid(() => {
    ignore(
      @evaluation.AccuracyRequirements::new(min_samples=1, min_coverage=0.0),
    )
  })
}

///|
test "accuracy requirements reject invalid counts coverage and error bounds" {
  for count in [0, -1] {
    invalid(() => {
      ignore(
        @evaluation.AccuracyRequirements::new(
          min_samples=count,
          min_coverage=0.0,
          max_mae=0.0,
        ),
      )
    })
  }
  for coverage in [-0.01, 1.01, 0.0 / 0.0, 1.0 / 0.0] {
    invalid(() => {
      ignore(
        @evaluation.AccuracyRequirements::new(
          min_samples=1,
          min_coverage=coverage,
          max_mae=0.0,
        ),
      )
    })
  }
  for bound in [-1.0, 0.0 / 0.0, 1.0 / 0.0] {
    invalid(() => {
      ignore(
        @evaluation.AccuracyRequirements::new(
          min_samples=1,
          min_coverage=0.0,
          max_mae=bound,
        ),
      )
    })
    invalid(() => {
      ignore(
        @evaluation.AccuracyRequirements::new(
          min_samples=1,
          min_coverage=0.0,
          max_rmse=bound,
        ),
      )
    })
    invalid(() => {
      ignore(
        @evaluation.AccuracyRequirements::new(
          min_samples=1,
          min_coverage=0.0,
          max_error=bound,
        ),
      )
    })
  }
}

///|
test "empty and all missing references cannot pass even zero coverage requirements" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  let limits = @evaluation.AccuracyRequirements::new(
    min_samples=1,
    min_coverage=0.0,
    max_mae=100.0,
  )
  let empty = session.assess(position=limits, speed=limits)
  assert_false(empty.accepted)
  assert_eq(empty.checks.length(), 6)
  assert_eq(empty.checks[0].actual, Some(0.0))
  assert_eq(empty.checks[1].actual, None)
  assert_false(empty.checks[2].passed)
  ignore(session.update(frame(0L, []), 0L, [reference(1)]))
  let missing = session.assess(position=limits, speed=limits)
  assert_false(missing.accepted)
  assert_eq(missing.checks[1].actual, Some(0.0))
  assert_true(missing.checks[1].passed)
  assert_eq(missing.checks[2].actual, None)
}

///|
test "error and coverage equality is inclusive in both quantities" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  ignore(
    session.update(frame(0L, [track(1, 0L, x=3.0, y=4.0, speed=2.0)]), 0L, [
      reference(1),
    ]),
  )
  let p = @evaluation.AccuracyRequirements::new(
    min_samples=1,
    min_coverage=1.0,
    max_mae=5.0,
    max_rmse=5.0,
    max_error=5.0,
  )
  let v = @evaluation.AccuracyRequirements::new(
    min_samples=1,
    min_coverage=1.0,
    max_mae=2.0,
    max_rmse=2.0,
    max_error=2.0,
  )
  let report = session.assess(position=p, speed=v)
  assert_true(report.accepted)
  assert_eq(report.checks.length(), 10)
  assert_eq(report.checks[0].metric, @evaluation.PositionSamples)
  assert_eq(report.checks[7].metric, @evaluation.SpeedMeanAbsoluteError)
  assert_true(report.checks.all(check => check.passed))
}

///|
test "each selected error bound can independently fail" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  ignore(
    session.update(frame(0L, [track(1, 0L, x=2.0, speed=2.0)]), 0L, [
      reference(1),
    ]),
  )
  for
    limits in [
      @evaluation.AccuracyRequirements::new(
        min_samples=1,
        min_coverage=1.0,
        max_mae=1.0,
        max_rmse=3.0,
        max_error=3.0,
      ),
      @evaluation.AccuracyRequirements::new(
        min_samples=1,
        min_coverage=1.0,
        max_mae=3.0,
        max_rmse=1.0,
        max_error=3.0,
      ),
      @evaluation.AccuracyRequirements::new(
        min_samples=1,
        min_coverage=1.0,
        max_mae=3.0,
        max_rmse=3.0,
        max_error=1.0,
      ),
    ] {
    let position = session.assess(position=limits)
    let speed = session.assess(speed=limits)
    assert_false(position.accepted)
    assert_false(speed.accepted)
    assert_eq(position.checks.filter(check => !check.passed).length(), 1)
    assert_eq(speed.checks.filter(check => !check.passed).length(), 1)
  }
}

///|
test "accurate small subset still fails scored count and missing-reference coverage" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  ignore(
    session.update(frame(0L, [track(1, 0L)]), 0L, [reference(1), reference(2)]),
  )
  let limits = @evaluation.AccuracyRequirements::new(
    min_samples=2,
    min_coverage=0.75,
    max_error=0.0,
  )
  let report = session.assess(position=limits, speed=limits)
  assert_false(report.accepted)
  assert_eq(report.checks.filter(check => !check.passed).length(), 4)
  assert_true(report.checks[2].passed)
  assert_true(report.checks[5].passed)
}

///|
test "initializing and uncertain speeds do not satisfy ready-speed sample requirements" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  ignore(
    session.update(frame(0L, [track(1, 0L, status=@motion.Initializing)]), 0L, [
      reference(1),
    ]),
  )
  ignore(
    session.update(frame(1L, [track(1, 1L, status=@motion.Uncertain)]), 1L, [
      reference(1),
    ]),
  )
  let limits = @evaluation.AccuracyRequirements::new(
    min_samples=2,
    min_coverage=1.0,
    max_error=0.0,
  )
  assert_true(session.assess(position=limits).accepted)
  assert_false(session.assess(speed=limits).accepted)
  assert_eq(session.assess(speed=limits).checks[0].actual, Some(0.0))
}

///|
test "unreferenced and rejected observations never inflate scored sample counts" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  ignore(
    session.update(frame(0L, [track(1, 0L), track(2, 0L)]), 0L, [reference(1)]),
  )
  ignore(
    session.update(
      frame(1L, [track(1, 1L, status=@motion.RejectedInnovation)]),
      1L,
      [reference(1)],
    ),
  )
  let limits = @evaluation.AccuracyRequirements::new(
    min_samples=1,
    min_coverage=0.5,
    max_error=0.0,
  )
  let result = session.assess(position=limits)
  assert_true(result.accepted)
  assert_eq(result.evaluation.counts.without_reference, 1)
  assert_eq(result.checks[0].actual, Some(1.0))
  assert_eq(result.checks[1].actual, Some(0.5))
}

///|
test "absent speed truth fails speed acceptance while position can pass" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  ignore(
    session.update(frame(0L, [track(1, 0L)]), 0L, [reference(1, speed=None)]),
  )
  let limits = @evaluation.AccuracyRequirements::new(
    min_samples=1,
    min_coverage=1.0,
    max_error=0.0,
  )
  assert_true(session.assess(position=limits).accepted)
  let speed = session.assess(speed=limits)
  assert_false(speed.accepted)
  assert_eq(speed.checks[1].actual, None)
}

///|
test "assessment is repeatable and cannot mutate the session or its fork" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  ignore(session.update(frame(0L, [track(1, 0L)]), 0L, [reference(1)]))
  let limits = @evaluation.AccuracyRequirements::new(
    min_samples=1,
    min_coverage=1.0,
    max_mae=0.0,
  )
  let accepted = session.assess(position=limits)
  accepted.checks.clear()
  assert_true(session.assess(position=limits).accepted)
  assert_eq(session.assess(position=limits).checks.length(), 3)
  assert_true(session.fork().assess(position=limits).accepted)
  assert_eq(session.report().counts.frames, 1L)
}

///|
test "extreme finite error thresholds do not overflow their comparisons" {
  for scale in [1.0e-200, 1.0e200] {
    let session = @evaluation.EvaluationSession::new("evaluation")
    ignore(
      session.update(frame(0L, [track(1, 0L, x=scale, speed=scale)]), 0L, [
        reference(1),
      ]),
    )
    let limits = @evaluation.AccuracyRequirements::new(
      min_samples=1,
      min_coverage=1.0,
      max_mae=scale,
      max_rmse=scale,
      max_error=scale,
    )
    assert_true(session.assess(position=limits, speed=limits).accepted)
  }
}
