///|
fn same_report(
  a : @evaluation.EvaluationReport,
  b : @evaluation.EvaluationReport,
) -> Unit raise {
  assert_eq(
    (a.session_id, a.first_timestamp_us, a.last_timestamp_us),
    (b.session_id, b.first_timestamp_us, b.last_timestamp_us),
  )
  let x = a.counts
  let y = b.counts
  assert_eq(x.frames, y.frames)
  assert_eq(
    [
      x.references,
      x.speed_references,
      x.measurements,
      x.without_reference,
      x.missing,
      x.initializing,
      x.ready,
      x.uncertain,
      x.rejected_innovation,
      x.numerical_failure,
      x.rejected_projection,
    ],
    [
      y.references,
      y.speed_references,
      y.measurements,
      y.without_reference,
      y.missing,
      y.initializing,
      y.ready,
      y.uncertain,
      y.rejected_innovation,
      y.numerical_failure,
      y.rejected_projection,
    ],
  )
  for
    (x, y) in [
      (a.position_error_m, b.position_error_m),
      (a.speed_error_mps, b.speed_error_mps),
    ] {
    assert_eq(
      (
        x.samples,
        x.mean_absolute_error,
        x.root_mean_square_error,
        x.maximum_absolute_error,
      ),
      (
        y.samples,
        y.mean_absolute_error,
        y.root_mean_square_error,
        y.maximum_absolute_error,
      ),
    )
  }
  assert_eq(
    a.position_bias_m.map(p => (p.x, p.y)),
    b.position_bias_m.map(p => (p.x, p.y)),
  )
  assert_eq(a.speed_bias_mps, b.speed_bias_mps)
  assert_eq(
    (a.position_coverage, a.speed_coverage),
    (b.position_coverage, b.speed_coverage),
  )
}

///|
test "empty evaluation checkpoint restores null populations and explicit capacities" {
  let session = @evaluation.EvaluationSession::new(
    "evaluation",
    max_tracks=3,
    max_samples=7,
  )
  let cp = session.checkpoint()
  let restored = @evaluation.EvaluationSession::from_checkpoint(cp)
  same_report(restored.report(), session.report())
  assert_eq((cp.version, cp.max_tracks, cp.max_samples), (1, 3, 7))
  let limits = @evaluation.AccuracyRequirements::new(
    min_samples=1,
    min_coverage=0.0,
    max_error=1.0,
  )
  assert_false(restored.assess(position=limits).accepted)
}

///|
test "evaluation checkpoints continue every cut without reconstructing rounded statistics" {
  let expected = @evaluation.EvaluationSession::new("evaluation")
  for i in 0..<20 {
    ignore(
      expected.update(
        frame(Int64::from_int(i), [
          track(1, Int64::from_int(i), x=i.to_double(), y=0.3, speed=0.5),
        ]),
        Int64::from_int(i),
        [reference(1)],
      ),
    )
  }
  for cut in 0..<=20 {
    let first = @evaluation.EvaluationSession::new("evaluation")
    for i in 0..<cut {
      ignore(
        first.update(
          frame(Int64::from_int(i), [
            track(1, Int64::from_int(i), x=i.to_double(), y=0.3, speed=0.5),
          ]),
          Int64::from_int(i),
          [reference(1)],
        ),
      )
    }
    let saved = first.checkpoint()
    let next = @evaluation.EvaluationSession::from_checkpoint(saved)
    for i in cut..<20 {
      ignore(
        next.update(
          frame(Int64::from_int(i), [
            track(1, Int64::from_int(i), x=i.to_double(), y=0.3, speed=0.5),
          ]),
          Int64::from_int(i),
          [reference(1)],
        ),
      )
    }
    same_report(next.report(), expected.report())
    assert_eq(first.checkpoint().counts.frames, Int64::from_int(cut))
  }
}

///|
test "checkpoint preserves scaled moments at extreme and subnormal scales" {
  for scale in [1.0e-200, 1.0e200, 5.0e-324] {
    let session = @evaluation.EvaluationSession::new("evaluation")
    for i in 0..<6 {
      let time = Int64::from_int(i)
      ignore(
        session.update(
          frame(time, [track(1, time, x=if i == 0 { scale } else { 0.0 })]),
          time,
          [reference(1)],
        ),
      )
      same_report(
        @evaluation.EvaluationSession::from_checkpoint(session.checkpoint()).report(),
        session.report(),
      )
    }
  }
}

///|
test "checkpoint rejects version identity and capacity changes" {
  let cp = @evaluation.EvaluationSession::new("evaluation").checkpoint()
  for
    changed in [
      { ..cp, version: 2, },
      { ..cp, session_id: "", },
      { ..cp, max_tracks: 0, },
      { ..cp, max_tracks: 4097, },
      { ..cp, max_samples: 0, },
    ] {
    invalid(() => {
      ignore(@evaluation.EvaluationSession::from_checkpoint(changed))
    })
  }
}

///|
test "checkpoint rejects inconsistent populations without integer overflow" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  ignore(session.update(frame(0L, [track(1, 0L)]), 0L, [reference(1)]))
  let cp = session.checkpoint()
  for
    counts in [
      { ..cp.counts, references: 2, },
      { ..cp.counts, speed_references: 2, },
      { ..cp.counts, measurements: 2, },
      { ..cp.counts, without_reference: -1, },
      { ..cp.counts, missing: 1, },
      { ..cp.counts, initializing: 1, },
      { ..cp.counts, ready: 2147483647, },
      { ..cp.counts, uncertain: 1, },
      { ..cp.counts, rejected_innovation: 1, },
      { ..cp.counts, numerical_failure: 1, },
      { ..cp.counts, rejected_projection: 1, },
    ] {
    invalid(() => {
      ignore(@evaluation.EvaluationSession::from_checkpoint({ ..cp, counts, }))
    })
  }
  invalid(() => {
    ignore(
      @evaluation.EvaluationSession::from_checkpoint({
        ..cp,
        position: { ..cp.position, samples: 2, },
      }),
    )
  })
  invalid(() => {
    ignore(
      @evaluation.EvaluationSession::from_checkpoint({
        ..cp,
        speed: { ..cp.speed, samples: 0, },
      }),
    )
  })
}

///|
test "checkpoint time range matches frame population and exact Int64 watermarks" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  ignore(session.update(frame(9007199254740993L, []), 9007199254740993L, []))
  let cp = session.checkpoint()
  for
    bad in [
      { ..cp, first_timestamp_us: None, },
      { ..cp, last_timestamp_us: None, },
      { ..cp, first_timestamp_us: Some(-1L), },
      { ..cp, last_timestamp_us: Some(0L), },
      { ..cp, counts: { ..cp.counts, frames: 2L, }, },
    ] {
    invalid(() => ignore(@evaluation.EvaluationSession::from_checkpoint(bad)))
  }
  let restored = @evaluation.EvaluationSession::from_checkpoint(cp)
  invalid(() => {
    ignore(restored.update(frame(9007199254740993L, []), 9007199254740993L, []))
  })
  ignore(restored.update(frame(9007199254740994L, []), 9007199254740994L, []))
  assert_eq(restored.checkpoint().last_timestamp_us, Some(9007199254740994L))
}

///|
test "checkpoint validates accumulator domains and empty bias" {
  let cp = @evaluation.EvaluationSession::new("evaluation").checkpoint()
  for
    state in [
      { ..cp.position, scale: 1.0, },
      { ..cp.position, mean_absolute: 1.0, },
      { ..cp.position, scaled_squares: 1.0, },
      { ..cp.position, maximum: 1.0, },
      { ..cp.position, mean_absolute: 0.0 / 0.0, },
      { ..cp.position, scale: 1.0 / 0.0, },
    ] {
    invalid(() => {
      ignore(
        @evaluation.EvaluationSession::from_checkpoint({
          ..cp,
          position: state,
        }),
      )
    })
  }
  invalid(() => {
    ignore(
      @evaluation.EvaluationSession::from_checkpoint({
        ..cp,
        position_bias_m: { x: 1.0, y: 0.0, },
      }),
    )
  })
  invalid(() => {
    ignore(
      @evaluation.EvaluationSession::from_checkpoint({
        ..cp,
        speed_bias_mps: 0.0 / 0.0,
      }),
    )
  })
}

///|
test "checkpoint rejects impossible nonempty moments and bias" {
  let session = @evaluation.EvaluationSession::new("evaluation")
  ignore(
    session.update(frame(0L, [track(1, 0L, x=2.0, speed=2.0)]), 0L, [
      reference(1),
    ]),
  )
  let cp = session.checkpoint()
  for
    state in [
      { ..cp.position, mean_absolute: -1.0, },
      { ..cp.position, mean_absolute: 3.0, },
      { ..cp.position, scaled_squares: 0.0, },
      { ..cp.position, scaled_squares: 2.0, },
      { ..cp.position, maximum: 1.0, },
    ] {
    invalid(() => {
      ignore(
        @evaluation.EvaluationSession::from_checkpoint({
          ..cp,
          position: state,
        }),
      )
    })
  }
  invalid(() => {
    ignore(
      @evaluation.EvaluationSession::from_checkpoint({
        ..cp,
        speed_bias_mps: 3.0,
      }),
    )
  })
}

///|
test "restored capacities and failed updates preserve the saved state" {
  let session = @evaluation.EvaluationSession::new(
    "evaluation",
    max_tracks=1,
    max_samples=1,
  )
  ignore(session.update(frame(0L, [track(1, 0L)]), 0L, [reference(1)]))
  let restored = @evaluation.EvaluationSession::from_checkpoint(
    session.checkpoint(),
  )
  invalid(() => {
    ignore(restored.update(frame(1L, [track(1, 1L)]), 1L, [reference(1)]))
  })
  same_report(session.report(), restored.report())
  let empty = @evaluation.EvaluationSession::from_checkpoint(
    session.checkpoint(),
  )
  ignore(empty.update(frame(1L, []), 1L, []))
  assert_eq(empty.report().counts.frames, 2L)
  assert_eq(session.report().counts.frames, 1L)
}
