///|
fn invalid(action : () -> Unit raise @types.GroundError) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid landmark health input was accepted")
  }
}

///|
fn calibration() -> @calibration.GroundCalibration raise @types.GroundError {
  @calibration.GroundCalibration::from_homography(
    [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    [
      { x: -10.0, y: -10.0, },
      { x: 10.0, y: -10.0, },
      { x: 10.0, y: 10.0, },
      { x: -10.0, y: 10.0, },
    ],
    max_meters_per_pixel=2.0,
  )
}

///|
fn references() -> Array[@health.KnownLandmark] raise @types.GroundError {
  [
    @health.KnownLandmark::new("a", { x: 0.0, y: 0.0, }),
    @health.KnownLandmark::new("b", { x: 1.0, y: 0.0, }),
    @health.KnownLandmark::new("c", { x: 0.0, y: 1.0, }),
  ]
}

///|
fn observation(
  id : String,
  x : Double,
  y : Double,
  covariance~ : @types.Covariance2 = @types.Covariance2::isotropic(0.1),
) -> @health.LandmarkObservation raise @types.GroundError {
  @health.LandmarkObservation::new(id, { x, y, }, covariance)
}

///|
fn observations(
  shift~ : Double = 0.0,
) -> Array[@health.LandmarkObservation] raise @types.GroundError {
  [
    observation("a", shift, 0.0),
    observation("b", 1.0 + shift, 0.0),
    observation("c", shift, 1.0),
  ]
}

///|
fn monitor(
  config~ : @health.HealthConfig = @health.HealthConfig::new(),
  camera? : @camera.CameraModel,
) -> @health.CalibrationMonitor raise @types.GroundError {
  @health.CalibrationMonitor::new(calibration(), references(), config, camera?)
}

///|
fn close(actual : Double, expected : Double) -> Unit raise {
  assert_true((actual - expected).abs() <= 1.0e-10 * expected.abs().max(1.0))
}

///|
test "landmark construction validates identifiers geometry and reference budget" {
  invalid(() => ignore(@health.KnownLandmark::new("", { x: 0.0, y: 0.0, })))
  invalid(() => {
    ignore(@health.KnownLandmark::new("x".repeat(129), { x: 0.0, y: 0.0, }))
  })
  invalid(() => {
    ignore(@health.KnownLandmark::new("finite", { x: 1.0 / 0.0, y: 0.0, }))
  })
  ignore(@health.KnownLandmark::new("x".repeat(128), { x: 0.0, y: 0.0, }))
  invalid(() => {
    ignore(
      @health.CalibrationMonitor::new(
        calibration(),
        [],
        @health.HealthConfig::new(min_landmarks=1),
      ),
    )
  })
  let duplicate = references()
  duplicate[1] = duplicate[0]
  invalid(() => {
    ignore(
      @health.CalibrationMonitor::new(
        calibration(),
        duplicate,
        @health.HealthConfig::new(),
      ),
    )
  })
  invalid(() => {
    ignore(
      @health.CalibrationMonitor::new(
        calibration(),
        references(),
        @health.HealthConfig::new(min_landmarks=4),
      ),
    )
  })
  let too_many = Array::makei(65, index => {
    @health.KnownLandmark::new(index.to_string(), { x: 0.0, y: 0.0, })
  })
  invalid(() => {
    ignore(
      @health.CalibrationMonitor::new(
        calibration(),
        too_many,
        @health.HealthConfig::new(),
      ),
    )
  })
}

///|
test "health configuration validates limits while independent zero tolerances remain usable" {
  for count in [0, 65] {
    invalid(() => ignore(@health.HealthConfig::new(min_landmarks=count)))
  }
  for count in [0, 1000001] {
    invalid(() => ignore(@health.HealthConfig::new(min_observations=count)))
  }
  invalid(() => ignore(@health.HealthConfig::new(confirmation_us=-1L)))
  invalid(() => ignore(@health.HealthConfig::new(max_gap_us=0L)))
  for value in [-1.0, 1.0 / 0.0, 0.0 / 0.0] {
    invalid(() => ignore(@health.HealthConfig::new(rms_limit_m=value)))
    invalid(() => ignore(@health.HealthConfig::new(max_error_m=value)))
  }
  for value in [-1.0, 0.0, 1.0 / 0.0, 0.0 / 0.0] {
    invalid(() => ignore(@health.HealthConfig::new(max_position_std_m=value)))
  }
  ignore(@health.HealthConfig::new(rms_limit_m=1.0, max_error_m=0.0))
  let exact = monitor(
    config=@health.HealthConfig::new(
      rms_limit_m=0.0,
      max_error_m=0.0,
      confirmation_us=0L,
      min_observations=1,
    ),
  )
  assert_eq(exact.update(0L, observations()).status, @health.Healthy)
}

///|
test "landmark diagnostics follow configured order and closed metric tolerances" {
  let engine = monitor(
    config=@health.HealthConfig::new(rms_limit_m=0.125, max_error_m=0.125),
  )
  let shuffled = observations(shift=0.125)
  shuffled.swap(0, 2)
  let report = engine.update(0L, shuffled)
  assert_eq(report.evidence, @health.WithinTolerance)
  assert_eq(report.rms_error_m, Some(0.125))
  assert_eq(report.max_error_m, Some(0.125))
  assert_eq(report.usable_count, 3)
  assert_eq(report.status, @health.Pending)
  for index, item in report.landmarks {
    assert_eq(item.landmark_id, references()[index].landmark_id)
    assert_eq(item.rejection_reason, None)
    guard item.residual_m is Some(residual) else { fail("residual missing") }
    assert_eq(residual.x, 0.125)
    assert_eq(residual.y, 0.0)
  }
  for
    config in [
      @health.HealthConfig::new(rms_limit_m=0.1, max_error_m=1.0),
      @health.HealthConfig::new(rms_limit_m=1.0, max_error_m=0.1),
    ] {
    assert_eq(
      monitor(config~).update(0L, observations(shift=0.125)).evidence,
      @health.BeyondTolerance,
    )
  }
}

///|
test "missing projection and uncertainty failures are per-landmark diagnostics" {
  let engine = monitor(config=@health.HealthConfig::new(max_position_std_m=0.2))
  let report = engine.update(0L, [
    observation("b", 100.0, 0.0),
    observation("c", 0.0, 1.0, covariance=@types.Covariance2::isotropic(1.0)),
  ])
  assert_eq(report.landmarks[0].rejection_reason, Some("missing"))
  guard report.landmarks[1].rejection_reason is Some(reason) else {
    fail("projection reason missing")
  }
  assert_true(reason.has_prefix("projection: "))
  assert_true(report.landmarks[1].projected_position_m is None)
  assert_eq(report.landmarks[2].rejection_reason, Some("position_uncertainty"))
  assert_true(report.landmarks[2].projected_position_m is Some(_))
  assert_true(report.landmarks[2].projected_covariance is Some(_))
  assert_true(report.landmarks[2].position_std_m is Some(_))
  assert_true(report.landmarks[2].residual_m is None)
  assert_eq(report.landmarks[2].error_m, None)
  assert_eq(report.rms_error_m, None)
  assert_eq(report.max_error_m, None)
  assert_eq(report.status, @health.HealthStatus::Insufficient)
}

///|
test "uncertainty uses the worst covariance direction and accepts its exact threshold" {
  let covariance = @types.Covariance2::new(0.04, 0.009, 0.01)
  let obs = [observation("a", 0.0, 0.0, covariance~)]
  let probe = monitor(config=@health.HealthConfig::new(min_landmarks=1)).update(
    0L, obs,
  )
  guard probe.landmarks[0].position_std_m is Some(deviation) else {
    fail("deviation missing")
  }
  let a = 0.040001
  let c = 0.010001
  close(
    deviation,
    ((a + c + ((a - c) * (a - c) + 4.0 * 0.009 * 0.009).sqrt()) / 2.0).sqrt(),
  )
  let exact = monitor(
    config=@health.HealthConfig::new(
      min_landmarks=1,
      max_position_std_m=deviation,
    ),
  )
  assert_eq(exact.update(0L, obs).usable_count, 1)
  let below = monitor(
    config=@health.HealthConfig::new(
      min_landmarks=1,
      max_position_std_m=deviation * 0.999999,
    ),
  )
  assert_eq(below.update(0L, obs).usable_count, 0)
}

///|
test "structural frame failures preserve evidence and permit a same-time retry" {
  let engine = monitor()
  ignore(engine.update(0L, observations()))
  let before = @debug.to_string(engine.checkpoint())
  let malformed : @health.LandmarkObservation = {
    landmark_id: "b",
    pixel: { x: 1.0, y: 0.0, },
    covariance: { xx: 1.0, xy: 2.0, yy: 1.0, },
  }
  for
    bad in [
      [observation("unknown", 0.0, 0.0)],
      [observation("a", 100.0, 0.0), observation("a", 101.0, 0.0)],
      [observation("a", 0.0, 0.0), malformed],
      [
        observation("a", 0.0, 0.0),
        observation("b", 1.0, 0.0),
        observation("c", 0.0, 1.0),
        observation("a", 0.0, 0.0),
      ],
    ] {
    invalid(() => ignore(engine.update(100000L, bad)))
    assert_eq(@debug.to_string(engine.checkpoint()), before)
  }
  assert_eq(engine.update(100000L, observations()).streak_observations, 2)
}

///|
test "confirmation requires both observations and sampled time span" {
  let engine = monitor()
  assert_eq(engine.update(0L, observations()).status, @health.Pending)
  assert_eq(engine.update(1L, observations()).status, @health.Pending)
  assert_eq(engine.update(2L, observations()).status, @health.Pending)
  assert_eq(engine.update(300000L, observations()).status, @health.Healthy)
  let count_bound = monitor(
    config=@health.HealthConfig::new(confirmation_us=0L, min_observations=4),
  )
  for i in 0..<3 {
    assert_eq(
      count_bound.update(i.to_int64(), observations()).status,
      @health.Pending,
    )
  }
  assert_eq(count_bound.update(3L, observations()).status, @health.Healthy)
}

///|
test "changed evidence begins a new pending streak before drift or healthy confirmation" {
  let engine = monitor(
    config=@health.HealthConfig::new(confirmation_us=100L, min_observations=2),
  )
  ignore(engine.update(0L, observations()))
  assert_eq(engine.update(100L, observations()).status, @health.Healthy)
  let changed = engine.update(101L, observations(shift=0.5))
  assert_eq(changed.evidence, @health.BeyondTolerance)
  assert_eq(changed.status, @health.Pending)
  assert_eq(changed.streak_since_us, Some(101L))
  assert_eq(engine.update(201L, observations(shift=0.5)).status, @health.Drift)
  assert_eq(engine.update(202L, observations()).status, @health.Pending)
  assert_eq(engine.update(302L, observations()).status, @health.Healthy)
}

///|
test "insufficient evidence clears confirmed health and retains only current usable diagnostics" {
  let engine = monitor(
    config=@health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  assert_eq(engine.update(0L, observations()).status, @health.Healthy)
  let incomplete = engine.update(1L, [observation("a", 0.5, 0.0)])
  assert_eq(incomplete.evidence, @health.CalibrationEvidence::Insufficient)
  assert_eq(incomplete.status, @health.HealthStatus::Insufficient)
  assert_eq(incomplete.rms_error_m, Some(0.5))
  assert_eq(incomplete.max_error_m, Some(0.5))
  assert_eq(incomplete.streak_since_us, None)
  assert_eq(incomplete.streak_observations, 0)
  assert_true(engine.checkpoint().streak is None)
  assert_eq(engine.update(2L, observations(shift=0.5)).status, @health.Drift)
  assert_eq(engine.update(3L, []).status, @health.HealthStatus::Insufficient)
}

///|
test "the exact maximum gap restarts the observation streak" {
  for gap in [99L, 100L] {
    let engine = monitor(
      config=@health.HealthConfig::new(
        confirmation_us=0L,
        min_observations=2,
        max_gap_us=100L,
      ),
    )
    ignore(engine.update(0L, observations()))
    let next = engine.update(gap, observations())
    assert_eq(
      next.status,
      if gap == 99L {
        @health.Healthy
      } else {
        @health.Pending
      },
    )
    assert_eq(next.streak_since_us, Some(if gap == 99L { 0L } else { 100L }))
  }
}

///|
test "streak observations saturate while timestamps stay exact near Int64 maximum" {
  let engine = monitor(
    config=@health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  let end = 9223372036854775807L
  for i in 0..<10 {
    let time = end - 9L + i.to_int64()
    let report = engine.update(time, observations())
    assert_eq(report.timestamp_us, time)
    assert_eq(report.streak_observations, 1)
    assert_eq(report.streak_since_us, Some(end - 9L))
    assert_eq(report.status, @health.Healthy)
  }
  ignore(@health.CalibrationMonitor::from_checkpoint(engine.checkpoint()))
  invalid(() => ignore(engine.update(end, observations())))
  invalid(() => ignore(monitor().update(-1L, observations())))
}

///|
test "scaled RMS keeps huge finite residuals and rejects an unrepresentable point norm" {
  let refs = [
    @health.KnownLandmark::new("a", { x: -1.0e308, y: 0.0, }),
    @health.KnownLandmark::new("b", { x: -1.0e308, y: 0.0, }),
    @health.KnownLandmark::new("c", { x: -1.3e308, y: -1.3e308, }),
  ]
  let engine = @health.CalibrationMonitor::new(
    calibration(),
    refs,
    @health.HealthConfig::new(
      min_landmarks=2,
      confirmation_us=0L,
      min_observations=1,
    ),
  )
  let report = engine.update(0L, [
    observation("a", 0.0, 0.0),
    observation("b", 0.0, 0.0),
    observation("c", 0.0, 0.0),
  ])
  assert_eq(report.usable_count, 2)
  assert_eq(report.rms_error_m, Some(1.0e308))
  assert_eq(report.max_error_m, Some(1.0e308))
  assert_eq(report.status, @health.Drift)
  guard report.landmarks[2].rejection_reason is Some(reason) else {
    fail("numeric rejection missing")
  }
  assert_true(reason.has_prefix("numerical: "))
  assert_true(report.landmarks[2].residual_m is None)
  assert_eq(report.landmarks[2].error_m, None)
  assert_true(report.landmarks[2].projected_position_m is Some(_))
}

///|
test "scaled residual norms and RMS preserve very small nonzero errors" {
  let engine = @health.CalibrationMonitor::new(
    calibration(),
    [@health.KnownLandmark::new("tiny", { x: -1.0e-200, y: 0.0, })],
    @health.HealthConfig::new(min_landmarks=1, rms_limit_m=0.0, max_error_m=0.0),
  )
  let report = engine.update(0L, [observation("tiny", 0.0, 0.0)])
  assert_eq(report.rms_error_m, Some(1.0e-200))
  assert_eq(report.max_error_m, Some(1.0e-200))
  assert_eq(report.evidence, @health.BeyondTolerance)
}

///|
test "complete checkpoint resumes every evidence change insufficiency and time-gap boundary" {
  let shifts = [0.0, 0.0, 0.0, 0.5, 0.5, 0.5, 0.0, 0.0, 0.0]
  let times = [
    0L, 150000L, 300000L, 400000L, 550000L, 700000L, 800000L, 1300000L, 1450000L,
  ]
  let frames = shifts.map(shift => observations(shift~))
  frames[6] = []
  let full = monitor()
  let expected = Array::makei(frames.length(), i => {
    @debug.to_string(full.update(times[i], frames[i]))
  })
  let expected_checkpoint = @debug.to_string(full.checkpoint())
  for cut in 0..<=frames.length() {
    let prefix = monitor()
    for i in 0..<cut {
      ignore(prefix.update(times[i], frames[i]))
    }
    let restored = @health.CalibrationMonitor::from_checkpoint(
      prefix.checkpoint(),
    )
    for i in cut..<frames.length() {
      assert_eq(
        @debug.to_string(restored.update(times[i], frames[i])),
        expected[i],
      )
    }
    assert_eq(@debug.to_string(restored.checkpoint()), expected_checkpoint)
  }
}

///|
test "checkpoint restoration rejects inconsistent evidence counts times and versions" {
  let engine = monitor()
  ignore(engine.update(100L, observations()))
  ignore(engine.update(200L, observations()))
  let checkpoint = engine.checkpoint()
  guard checkpoint.streak is Some(streak) else { fail("streak missing") }
  let bad = [
    { ..checkpoint, version: 2, },
    { ..checkpoint, last_timestamp_us: None, },
    { ..checkpoint, last_timestamp_us: Some(-1L), },
    {
      ..checkpoint,
      streak: Some({
        ..streak,
        evidence: @health.CalibrationEvidence::Insufficient,
      }),
    },
    { ..checkpoint, streak: Some({ ..streak, since_us: -1L, }), },
    { ..checkpoint, streak: Some({ ..streak, since_us: 201L, }), },
    { ..checkpoint, streak: Some({ ..streak, observations: 0, }), },
    { ..checkpoint, streak: Some({ ..streak, observations: 4, }), },
    { ..checkpoint, streak: Some({ ..streak, observations: 1, }), },
    { ..checkpoint, streak: Some({ ..streak, since_us: 200L, }), },
    { ..checkpoint, last_timestamp_us: Some(1000000000L), },
  ]
  for bad in bad {
    invalid(() => ignore(@health.CalibrationMonitor::from_checkpoint(bad)))
  }
  let insufficient = { ..checkpoint, streak: None, }
  ignore(@health.CalibrationMonitor::from_checkpoint(insufficient))
}

///|
test "restoration applies continuity bounds before count saturation and handles a unit gap" {
  let engine = monitor(
    config=@health.HealthConfig::new(max_gap_us=3L, min_observations=4),
  )
  ignore(engine.update(0L, observations()))
  ignore(engine.update(2L, observations()))
  let valid = engine.checkpoint()
  ignore(@health.CalibrationMonitor::from_checkpoint(valid))
  invalid(() => {
    ignore(
      @health.CalibrationMonitor::from_checkpoint({
        ..valid,
        last_timestamp_us: Some(3L),
      }),
    )
  })
  let saturated = monitor(
    config=@health.HealthConfig::new(max_gap_us=3L, min_observations=2),
  )
  for i in 0..<20 {
    ignore(saturated.update(i.to_int64() * 2L, observations()))
  }
  ignore(@health.CalibrationMonitor::from_checkpoint(saturated.checkpoint()))
  let unit = monitor(
    config=@health.HealthConfig::new(max_gap_us=1L, min_observations=1),
  )
  ignore(unit.update(0L, observations()))
  let next = unit.update(1L, observations())
  assert_eq(next.streak_since_us, Some(1L))
  let snapshot = unit.checkpoint()
  guard snapshot.streak is Some(streak) else { fail("streak missing") }
  invalid(() => {
    ignore(
      @health.CalibrationMonitor::from_checkpoint({
        ..snapshot,
        streak: Some({ ..streak, since_us: 0L, }),
      }),
    )
  })
}

///|
test "constructor checkpoint report and fork arrays cannot mutate another monitor" {
  let refs = references()
  let engine = @health.CalibrationMonitor::new(
    calibration(),
    refs,
    @health.HealthConfig::new(),
  )
  refs.clear()
  let result = engine.update(0L, observations())
  let snapshot = engine.checkpoint()
  let restored = @health.CalibrationMonitor::from_checkpoint(snapshot)
  let branch = engine.fork()
  let before = @debug.to_string(engine.checkpoint())
  snapshot.landmarks.clear()
  result.landmarks.clear()
  ignore(branch.update(100000L, observations(shift=0.5)))
  assert_eq(@debug.to_string(engine.checkpoint()), before)
  assert_eq(@debug.to_string(restored.checkpoint()), before)
  assert_eq(engine.update(100000L, observations()).landmarks.length(), 3)
}

///|
test "Brown-camera warm pixel reframing preserves evidence and independent metric references" {
  let camera = @camera.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let engine = monitor(camera~)
  let raw = (x : Double, y : Double) => {
    let factor = 1.0 + 0.02 * (x / 30.0 * (x / 30.0) + y / 40.0 * (y / 40.0))
    @types.Point2::{ x: x * factor, y: y * factor, }
  }
  let frame = (shift : Double) => {
    references().map(landmark => {
      @health.LandmarkObservation::new(
        landmark.landmark_id,
        raw(landmark.ground_m.x + shift, landmark.ground_m.y),
        @types.Covariance2::new(0.04, 0.009, 0.01),
      )
    })
  }
  ignore(engine.update(0L, frame(0.0)))
  ignore(engine.update(150000L, frame(0.0)))
  let transform = @types.PixelTransform::new(
    scale_x=2.0,
    scale_y=0.5,
    offset_x=4.0,
    offset_y=-2.0,
  )
  let adapted = engine.reframed(transform)
  let checkpoint = adapted.checkpoint()
  assert_eq(
    @debug.to_string(checkpoint.landmarks),
    @debug.to_string(engine.checkpoint().landmarks),
  )
  assert_eq(
    @debug.to_string(checkpoint.streak),
    @debug.to_string(engine.checkpoint().streak),
  )
  let restored = @health.CalibrationMonitor::from_checkpoint(checkpoint)
  for i in 2..<7 {
    let time = i.to_int64() * 150000L
    let input = frame(if i < 4 { 0.0 } else { 0.5 })
    let expected = engine.update(time, input)
    let transformed = input.map(observation => observation.reframed(transform))
    let actual = adapted.update(time, transformed)
    assert_eq(
      @debug.to_string(restored.update(time, transformed)),
      @debug.to_string(actual),
    )
    assert_eq(actual.status, expected.status)
    assert_eq(actual.evidence, expected.evidence)
    assert_eq(actual.streak_since_us, expected.streak_since_us)
    for index, item in actual.landmarks {
      guard (item.error_m, expected.landmarks[index].error_m)
        is (Some(a), Some(b)) else {
        fail("error missing")
      }
      close(a, b)
      guard (
          item.projected_covariance,
          expected.landmarks[index].projected_covariance,
        )
        is (Some(a), Some(b)) else {
        fail("covariance missing")
      }
      close(a.xx, b.xx)
      close(a.xy, b.xy)
      close(a.yy, b.yy)
    }
  }
}
