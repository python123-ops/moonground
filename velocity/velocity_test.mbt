///|
fn invalid(action : () -> Unit raise @types.GroundError) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid velocity input accepted")
  }
}

///|
fn close(
  actual : Double,
  expected : Double,
  tolerance~ : Double = 2.0e-14,
) -> Unit raise {
  if expected == 0.0 {
    assert_true(actual.abs() < tolerance)
  } else {
    assert_true((actual / expected - 1.0).abs() < tolerance)
  }
}

///|
fn probe(
  threshold~ : Double = 0.0,
  multiplier~ : Double = 2.0,
) -> @velocity.VelocityProbe raise @types.GroundError {
  @velocity.VelocityProbe::new(
    "forward",
    { x: 1.0, y: 0.0, },
    threshold,
    sigma_multiplier=multiplier,
  )
}

///|
fn projector(
  max_tracks~ : Int32 = 1000,
) -> @velocity.VelocityProjector raise @types.GroundError {
  @velocity.VelocityProjector::new("velocity", [probe()], max_tracks~)
}

///|
fn observation(
  x : Double,
  id~ : Int32 = 1,
) -> @types.GroundObservation raise @types.GroundError {
  @types.GroundObservation::new(
    id,
    { x, y: 0.0, },
    @types.Covariance2::isotropic(0.01),
  )
}

///|
fn ready_frame() -> @motion.FrameResult raise @types.GroundError {
  let estimator = @motion.MotionEstimator::new(
    "velocity",
    @motion.MotionConfig::new(min_observations=2, min_span_us=0L, gate=1.0e12),
  )
  ignore(estimator.update(0L, [observation(0.0)]))
  estimator.update(100000L, [observation(1.0)])
}

///|
test "signed threshold evidence distinguishes complete upper equality lower equality and positive margin" {
  let covariance = @types.Covariance2::isotropic(1.0)
  for
    (mean, threshold, decision) in [
      (4.0, 1.0, @velocity.Above),
      (4.0, 2.0, @velocity.Indeterminate),
      (4.0, 6.0, @velocity.AtOrBelow),
      (-4.0, -6.0, @velocity.Indeterminate),
      (-4.0, -2.0, @velocity.AtOrBelow),
    ] {
    let result = probe(threshold~).evaluate({ x: mean, y: 0.0, }, covariance)
    assert_eq(result.decision, decision)
    assert_eq(result.lower_mps, mean - 2.0)
    assert_eq(result.upper_mps, mean + 2.0)
  }
}

///|
test "k zero still computes covariance diagnostics and the signed threshold has exact equality and adjacent ULP semantics" {
  let covariance = @types.Covariance2::isotropic(0.25)
  let above = (1.0.reinterpret_as_int64() + 1L).reinterpret_as_double()
  let below = (1.0.reinterpret_as_int64() - 1L).reinterpret_as_double()
  for
    (mean, expected) in [
      (below, @velocity.AtOrBelow),
      (1.0, @velocity.AtOrBelow),
      (above, @velocity.Above),
    ] {
    let result = probe(threshold=1.0, multiplier=0.0).evaluate(
      { x: mean, y: 0.0, },
      covariance,
    )
    assert_eq(result.component_mps, mean)
    assert_eq(result.lower_mps, mean)
    assert_eq(result.upper_mps, mean)
    assert_eq(result.axis_std_mps, 0.25)
    assert_eq(result.decision, expected)
  }
  invalid(() => {
    ignore(
      probe(multiplier=0.0).evaluate({ x: 0.0, y: 0.0, }, {
        xx: 1.0,
        xy: 2.0,
        yy: 1.0,
      }),
    )
  })
}

///|
test "normalization handles finite enormous and subnormal directions without changing the intended axis" {
  let reference = @velocity.VelocityProbe::new(
    "reference",
    { x: 3.0, y: 4.0, },
    0.0,
  )
  for
    direction in [
      @types.Point2::{ x: 3.0e307, y: 4.0e307, },
      { x: 3.0e-300, y: 4.0e-300, },
      { x: 3.0, y: 4.0, },
    ] {
    let current = @velocity.VelocityProbe::new("scaled", direction, 0.0)
    close(current.direction.x, reference.direction.x)
    close(current.direction.y, reference.direction.y)
    close(
      current.evaluate({ x: 5.0, y: 0.0, }, @types.Covariance2::isotropic(1.0)).component_mps,
      3.0,
    )
  }
  assert_eq(
    @velocity.VelocityProbe::new(
      "subnormal",
      { x: 4.9406564584124654e-324, y: 0.0, },
      0.0,
    ).direction.x,
    1.0,
  )
}

///|
test "direction flip and a rotated covariance keep component evidence in the same metric frame" {
  let covariance = @types.Covariance2::new(4.0, 1.5, 9.0)
  let a = @velocity.VelocityProbe::new("a", { x: 3.0, y: 4.0, }, 0.0).evaluate(
    { x: 5.0, y: 2.0, },
    covariance,
  )
  let b = @velocity.VelocityProbe::new("b", { x: -4.0, y: 3.0, }, 0.0).evaluate(
    { x: -2.0, y: 5.0, },
    @types.Covariance2::new(9.0, -1.5, 4.0),
  )
  let flipped = @velocity.VelocityProbe::new(
    "reverse",
    { x: -3.0, y: -4.0, },
    0.0,
  ).evaluate({ x: 5.0, y: 2.0, }, covariance)
  close(a.component_mps, 4.6)
  close(a.component_mps, b.component_mps)
  close(a.axis_std_mps, b.axis_std_mps)
  close(flipped.component_mps, -a.component_mps)
  close(flipped.lower_mps, -a.upper_mps)
  close(flipped.upper_mps, -a.lower_mps)
}

///|
test "directional uncertainty distinguishes precise forward motion from an uncertain tangent" {
  let covariance = @types.Covariance2::new(0.01, 0.0, 100.0)
  let forward = probe(threshold=1.0).evaluate({ x: 2.0, y: 0.0, }, covariance)
  let tangent = @velocity.VelocityProbe::new(
    "tangent",
    { x: 0.0, y: 1.0, },
    1.0,
  ).evaluate({ x: 2.0, y: 0.0, }, covariance)
  assert_eq(forward.axis_std_mps, 0.1)
  assert_eq(forward.decision, @velocity.Above)
  assert_eq(tangent.axis_std_mps, 10.0)
  assert_eq(tangent.decision, @velocity.Indeterminate)
}

///|
test "correlation sign and tiny or huge covariance scales retain the projected standard deviation" {
  let axis = @velocity.VelocityProbe::new("diagonal", { x: 3.0, y: 4.0, }, 0.0)
  for scale in [1.0e-300, 1.0, 1.0e300] {
    for correlation in [-0.9, 0.9] {
      let result = axis.evaluate(
        { x: 0.0, y: 0.0, },
        @types.Covariance2::new(scale, correlation * scale, scale),
      )
      close(
        result.axis_std_mps / scale.sqrt(),
        (1.0 + 0.96 * correlation).sqrt(),
      )
    }
  }
}

///|
test "zero and exactly perpendicular nonzero velocities remain usable component measurements" {
  let axis = @velocity.VelocityProbe::new("diagonal", { x: 1.0, y: 1.0, }, 0.0)
  for
    velocity in [
      @types.Point2::{ x: 0.0, y: 0.0, },
      { x: 1.0, y: -1.0, },
      { x: 1.0e300, y: -1.0e300, },
    ] {
    let result = axis.evaluate(velocity, @types.Covariance2::isotropic(1.0))
    assert_eq(result.component_mps, 0.0)
    assert_eq(result.decision, @velocity.Indeterminate)
  }
  assert_eq(
    @velocity.VelocityProbe::new(
      "zero",
      { x: 1.0, y: 1.0, },
      0.0,
      sigma_multiplier=0.0,
    ).evaluate({ x: 1.0, y: -1.0, }, @types.Covariance2::isotropic(1.0)).decision,
    @velocity.AtOrBelow,
  )
}

///|
test "compensated dot preserves near orthogonal residuals and the giant binary double counterexample" {
  let axis = @velocity.VelocityProbe::new("binary", { x: 3.0, y: 4.0, }, 0.0)
  // Decimal.from_float at high precision gives these exact-product references.
  let ordinary = axis.evaluate(
    { x: 4.0, y: -3.0, },
    @types.Covariance2::isotropic(1.0),
  )
  assert_eq(ordinary.component_mps, -2.220446049250313e-16)
  let no_radius = @velocity.VelocityProbe::new(
    "binary",
    { x: 3.0, y: 4.0, },
    0.0,
    sigma_multiplier=0.0,
  )
  let giant = no_radius.evaluate(
    { x: 1.0e300, y: -7.5e299, },
    @types.Covariance2::isotropic(1.0),
  )
  close(giant.component_mps, -5.551115123125783e283)
  invalid(() => {
    ignore(
      axis.evaluate(
        { x: 1.0e300, y: -7.5e299, },
        @types.Covariance2::isotropic(1.0),
      ),
    )
  })
}

///|
test "unsupported near SPD and invalid covariance fail even with zero sigma multiplier" {
  let zero = probe(multiplier=0.0)
  for
    covariance in [
      @types.Covariance2::{ xx: 1.0, xy: -0.9999999999999999, yy: 1.0, },
      { xx: 0.0, xy: 0.0, yy: 1.0, },
      { xx: 1.0, xy: 2.0, yy: 1.0, },
      { xx: 1.0 / 0.0, xy: 0.0, yy: 1.0, },
    ] {
    invalid(() => ignore(zero.evaluate({ x: 0.0, y: 0.0, }, covariance)))
  }
}

///|
test "radius overflow underflow and swallowed endpoints reject instead of reporting false certainty" {
  invalid(() => {
    ignore(
      probe(multiplier=1.0e308).evaluate(
        { x: 0.0, y: 0.0, },
        @types.Covariance2::isotropic(10.0),
      ),
    )
  })
  invalid(() => {
    ignore(
      probe(multiplier=1.0e-300).evaluate(
        { x: 0.0, y: 0.0, },
        @types.Covariance2::new(1.0e-300, 0.0, 1.0e-300),
      ),
    )
  })
  invalid(() => {
    ignore(
      probe().evaluate(
        { x: 1.0e300, y: 0.0, },
        @types.Covariance2::isotropic(1.0),
      ),
    )
  })
  let tiny = probe().evaluate(
    { x: 0.0, y: 0.0, },
    @types.Covariance2::new(1.0e-300, 0.0, 1.0e-300),
  )
  assert_eq(tiny.lower_mps, -2.0e-150)
  assert_eq(tiny.upper_mps, 2.0e-150)
}

///|
test "mean scaling product underflow and nonfinite velocity are explicit numeric errors" {
  let covariance = @types.Covariance2::isotropic(1.0)
  invalid(() => ignore(probe().evaluate({ x: 0.0 / 0.0, y: 0.0, }, covariance)))
  invalid(() => {
    ignore(
      @velocity.VelocityProbe::new("diagonal", { x: 1.0, y: 1.0, }, 0.0).evaluate(
        { x: 1.0e308, y: 1.0e-300, },
        covariance,
      ),
    )
  })
  invalid(() => {
    ignore(
      @velocity.VelocityProbe::new("tiny axis", { x: 1.0e-310, y: 1.0, }, 0.0).evaluate(
        { x: 1.0, y: 0.0, },
        covariance,
      ),
    )
  })
  invalid(() => {
    ignore(
      @velocity.VelocityProbe::new("overflow", { x: 1.0, y: 1.0, }, 0.0).evaluate(
        { x: 1.7e308, y: 1.7e308, },
        covariance,
      ),
    )
  })
}

///|
test "probe configuration validates identities finite directions thresholds and nonnegative sigma" {
  for name in ["", Array::make(129, "a").join("")] {
    invalid(() => {
      ignore(@velocity.VelocityProbe::new(name, { x: 1.0, y: 0.0, }, 0.0))
    })
  }
  ignore(
    @velocity.VelocityProbe::new(
      Array::make(128, "a").join(""),
      { x: 1.0, y: 0.0, },
      -10.0,
      sigma_multiplier=0.0,
    ),
  )
  for
    direction in [
      @types.Point2::{ x: 0.0, y: 0.0, },
      { x: 1.0 / 0.0, y: 0.0, },
      { x: 0.0, y: 0.0 / 0.0, },
    ] {
    invalid(() => ignore(@velocity.VelocityProbe::new("p", direction, 0.0)))
  }
  for value in [1.0 / 0.0, 0.0 / 0.0] {
    invalid(() => {
      ignore(@velocity.VelocityProbe::new("p", { x: 1.0, y: 0.0, }, value))
    })
  }
  for value in [-1.0, 1.0 / 0.0, 0.0 / 0.0] {
    invalid(() => {
      ignore(
        @velocity.VelocityProbe::new(
          "p",
          { x: 1.0, y: 0.0, },
          0.0,
          sigma_multiplier=value,
        ),
      )
    })
  }
  invalid(() => {
    ignore(
      @velocity.VelocityProbe::new("lost", { x: 1.0e-300, y: 1.0e300, }, 0.0),
    )
  })
}

///|
test "projector bounds immutable probe configuration and rejects duplicate identities" {
  invalid(() => ignore(@velocity.VelocityProjector::new("", [probe()])))
  invalid(() => ignore(@velocity.VelocityProjector::new("velocity", [])))
  invalid(() => {
    ignore(@velocity.VelocityProjector::new("velocity", [probe(), probe()]))
  })
  for capacity in [0, 10001] {
    invalid(() => ignore(projector(max_tracks=capacity)))
  }
  ignore(projector(max_tracks=10000))
  let probes = Array::makei(16, i => {
    @velocity.VelocityProbe::new(i.to_string(), { x: 1.0, y: 0.0, }, 0.0)
  })
  let current = @velocity.VelocityProjector::new("velocity", probes)
  assert_eq(current.evaluate(ready_frame()).evidence.length(), 16)
  probes.push(@velocity.VelocityProbe::new("extra", { x: 1.0, y: 0.0, }, 0.0))
  invalid(() => ignore(@velocity.VelocityProjector::new("velocity", probes)))
  probes.clear()
  assert_eq(current.evaluate(ready_frame()).evidence.length(), 16)
}

///|
test "frame evaluation sorts object identities then keeps the caller configured probe order" {
  let source = ready_frame()
  let track = source.tracks[0]
  let probes = [
    @velocity.VelocityProbe::new("second", { x: 0.0, y: 1.0, }, 0.0),
    @velocity.VelocityProbe::new("first", { x: 1.0, y: 0.0, }, 0.0),
  ]
  let result = @velocity.VelocityProjector::new("velocity", probes).evaluate({
    ..source,
    tracks: [
      { ..track, track_id: 9, segment_id: "9", },
      { ..track, track_id: 2, segment_id: "2", },
    ],
  })
  assert_eq(result.evidence.map(row => row.track_id), [2, 2, 9, 9])
  assert_eq(result.evidence.map(row => row.evidence.probe_id), [
    "second", "first", "second", "first",
  ])
  assert_eq(source.tracks[0].track_id, 1)
}

///|
test "only Ready generates evidence and retained uncertain or diagnostic velocities are not revived" {
  let source = ready_frame()
  let track = source.tracks[0]
  let result = projector().evaluate({
    ..source,
    tracks: [
      track,
      { ..track, track_id: 2, segment_id: "2", status: @motion.Initializing, },
      { ..track, track_id: 3, segment_id: "3", status: @motion.Uncertain, },
      {
        ..track,
        track_id: 4,
        segment_id: "4",
        status: @motion.RejectedInnovation,
      },
      {
        ..track,
        track_id: 5,
        segment_id: "5",
        status: @motion.NumericalFailure,
      },
    ],
  })
  assert_eq(result.evidence.length(), 1)
  assert_eq(result.unavailable.map(row => row.reason), [
    @velocity.Initializing,
    @velocity.Uncertain,
    @velocity.RejectedInnovation,
    @velocity.NumericalFailure,
  ])
  let unavailable = projector().evaluate({
    ..source,
    tracks: [
      {
        ..track,
        status: @motion.Uncertain,
        velocity: Some({ x: 1.0 / 0.0, y: 0.0, }),
      },
    ],
  })
  assert_eq(unavailable.evidence.length(), 0)
  assert_eq(unavailable.unavailable[0].segment_id, Some("1"))
  assert_true(
    probe().evaluate(
      track.velocity.unwrap(),
      track.velocity_covariance.unwrap(),
    ).axis_std_mps >
    0.0,
  )
}

///|
test "Ready public records require actual vector covariance and current accepted timestamp without filter fallback" {
  let source = ready_frame()
  let track = source.tracks[0]
  for
    changed in [
      { ..track, velocity: None, },
      { ..track, velocity_covariance: None, },
      { ..track, last_accepted_timestamp_us: 99999L, },
      { ..track, velocity_covariance: Some({ xx: 1.0, xy: 2.0, yy: 1.0, }), },
      { ..track, velocity: Some({ x: 1.0 / 0.0, y: 0.0, }), },
    ] {
    invalid(() => ignore(projector().evaluate({ ..source, tracks: [changed], })))
  }
  assert_eq(projector().evaluate(source).evidence.length(), 1)
}

///|
test "frame session time identity capacity and canonical segment constraints are enforced for every source status" {
  let source = ready_frame()
  let track = source.tracks[0]
  invalid(() => ignore(projector().evaluate({ ..source, session_id: "other", })))
  invalid(() => ignore(projector().evaluate({ ..source, timestamp_us: -1L, })))
  invalid(() => {
    ignore(
      projector(max_tracks=1).evaluate({
        ..source,
        tracks: [track, { ..track, track_id: 2, segment_id: "2", }],
      }),
    )
  })
  for
    tracks in [
      [track, track],
      [track, { ..track, track_id: 2, }],
      [{ ..track, track_id: 0, }],
      [{ ..track, status: @motion.Uncertain, last_accepted_timestamp_us: -1L, }],
      [
        {
          ..track,
          status: @motion.RejectedInnovation,
          last_accepted_timestamp_us: 100001L,
        },
      ],
    ] {
    invalid(() => ignore(projector().evaluate({ ..source, tracks, })))
  }
  for segment_id in ["", "0", "01", "+1", "-1", "9223372036854775808"] {
    invalid(() => {
      ignore(
        projector().evaluate({ ..source, tracks: [{ ..track, segment_id, }], }),
      )
    })
  }
  assert_eq(
    projector().evaluate({
      ..source,
      tracks: [{ ..track, segment_id: "9223372036854775807", }],
    }).evidence.length(),
    1,
  )
}

///|
test "closed identities are canonical and unique and cannot also be currently accepted" {
  let source = ready_frame()
  for ids in [["0"], ["01"], ["2", "2"], ["1"]] {
    invalid(() => {
      ignore(projector().evaluate({ ..source, closed_segment_ids: ids, }))
    })
  }
  let rejected = { ..source.tracks[0], status: @motion.RejectedInnovation, }
  assert_eq(
    projector().evaluate({
      ..source,
      tracks: [rejected],
      closed_segment_ids: ["1"],
    }).unavailable.length(),
    1,
  )
}

///|
test "a numeric failure after earlier rows cannot change subsequent stateless evaluation" {
  let source = ready_frame()
  let evaluator = projector()
  let before = @debug.to_string(evaluator.evaluate(source))
  let track = source.tracks[0]
  let invalid_track = {
    ..track,
    track_id: 2,
    segment_id: "2",
    velocity_covariance: Some({ xx: 1.0, xy: -0.9999999999999999, yy: 1.0, }),
  }
  invalid(() => {
    ignore(evaluator.evaluate({ ..source, tracks: [track, invalid_track], }))
  })
  assert_eq(@debug.to_string(evaluator.evaluate(source)), before)
}

///|
test "independent repeated reordered missing and closed frames do not create a hidden freshness clock" {
  let source = ready_frame()
  let evaluator = projector()
  let expected = @debug.to_string(evaluator.evaluate(source))
  let earlier = {
    ..source,
    timestamp_us: 0L,
    tracks: [{ ..source.tracks[0], last_accepted_timestamp_us: 0L, }],
  }
  ignore(evaluator.evaluate(earlier))
  assert_eq(@debug.to_string(evaluator.evaluate(source)), expected)
  assert_eq(@debug.to_string(evaluator.evaluate(source)), expected)
  let missing = evaluator.evaluate({
    ..source,
    tracks: [],
    closed_segment_ids: ["1"],
  })
  assert_eq(missing.evidence.length(), 0)
  assert_eq(missing.unavailable.length(), 0)
  assert_eq(@debug.to_string(evaluator.evaluate(source)), expected)
}

///|
test "returned rows and caller input arrays cannot mutate the immutable projector" {
  let probes = [probe()]
  let evaluator = @velocity.VelocityProjector::new("velocity", probes)
  let frame = ready_frame()
  let before = @debug.to_string(frame)
  let result = evaluator.evaluate(frame)
  let expected = @debug.to_string(result)
  probes.clear()
  result.evidence.clear()
  result.unavailable.clear()
  assert_eq(@debug.to_string(evaluator.evaluate(frame)), expected)
  assert_eq(@debug.to_string(frame), before)
}

///|
test "old motion checkpoint recovery reproduces original velocity evidence without a new checkpoint format" {
  let estimator = @motion.MotionEstimator::new(
    "velocity",
    @motion.MotionConfig::new(min_observations=2, min_span_us=0L, gate=1.0e12),
  )
  ignore(estimator.update(9007199254740993L, [observation(0.0)]))
  ignore(estimator.update(9007199254840993L, [observation(1.0)]))
  let restored = @motion.MotionEstimator::from_checkpoint(
    estimator.checkpoint(),
  )
  let evaluator = projector()
  for index, x in [2.0, 3.0, 4.0] {
    let time = 9007199254940993L + index.to_int64() * 100000L
    assert_eq(
      @debug.to_string(
        evaluator.evaluate(restored.update(time, [observation(x)])),
      ),
      @debug.to_string(
        evaluator.evaluate(estimator.update(time, [observation(x)])),
      ),
    )
  }
}

///|
test "actual initialization uncertainty and innovation rejection keep the original speed availability policy" {
  let estimator = @motion.MotionEstimator::new(
    "velocity",
    @motion.MotionConfig::new(
      min_observations=2,
      min_span_us=0L,
      max_velocity_std_mps=1.0e-8,
    ),
  )
  assert_eq(
    projector().evaluate(estimator.update(0L, [observation(0.0)])).unavailable[0].reason,
    @velocity.Initializing,
  )
  let uncertain = estimator.update(100000L, [observation(0.0)])
  assert_eq(uncertain.tracks[0].speed_mps, None)
  assert_eq(
    projector().evaluate(uncertain).unavailable[0].reason,
    @velocity.Uncertain,
  )
  let rejected = estimator.update(200000L, [observation(100000.0)])
  assert_eq(
    projector().evaluate(rejected).unavailable[0].reason,
    @velocity.RejectedInnovation,
  )
}

///|
test "warm Brown pixel reframing and complete old checkpoint continuation preserve the metric velocity band" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    [
      { x: -10.0, y: -10.0, },
      { x: 10.0, y: -10.0, },
      { x: 10.0, y: 10.0, },
      { x: -10.0, y: 10.0, },
    ],
    max_meters_per_pixel=2.0,
  )
  let camera = @moonground.CameraModel::new(
    fx=30.0,
    fy=40.0,
    cx=0.0,
    cy=0.0,
    k1=0.02,
  )
  let original = @moonground.MeasurementSession::new(
    "velocity",
    calibration,
    @motion.MotionConfig::new(min_observations=2, min_span_us=0L, gate=1.0e12),
    camera~,
  )
  let pixel = (x : Double) => {
    @moonground.PixelObservation::new(
      1,
      { x, y: 0.0, },
      @types.Covariance2::isotropic(0.01),
    )
  }
  ignore(original.update(0L, [pixel(0.0)]))
  ignore(original.update(100000L, [pixel(1.0)]))
  let transform = @types.PixelTransform::new(
    scale_x=2.0,
    scale_y=0.5,
    offset_x=4.0,
    offset_y=-2.0,
  )
  let adapted = original.reframed(transform)
  let restored = @moonground.MeasurementSession::from_checkpoint(
    adapted.checkpoint(),
  )
  let evaluator = projector()
  for index, x in [2.0, 3.0, 4.0] {
    let time = (index + 2).to_int64() * 100000L
    let actual = evaluator.evaluate(
      adapted.update(time, [pixel(x).reframed(transform)]).motion,
    )
    let expected = evaluator.evaluate(original.update(time, [pixel(x)]).motion)
    assert_eq(
      @debug.to_string(actual),
      @debug.to_string(
        evaluator.evaluate(
          restored.update(time, [pixel(x).reframed(transform)]).motion,
        ),
      ),
    )
    close(
      actual.evidence[0].evidence.component_mps,
      expected.evidence[0].evidence.component_mps,
      tolerance=1.0e-9,
    )
    close(
      actual.evidence[0].evidence.axis_std_mps,
      expected.evidence[0].evidence.axis_std_mps,
      tolerance=1.0e-9,
    )
  }
}
