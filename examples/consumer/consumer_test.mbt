///|
test "packaged gate consumer resumes paired checkpoints across pixel reframing" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.01, 0.0, 0.0, 0.0, 0.01, 0.0, 0.0, 0.0, 1.0],
    [
      @moonground.Point2::new(0.0, 0.0),
      @moonground.Point2::new(640.0, 0.0),
      @moonground.Point2::new(640.0, 480.0),
      @moonground.Point2::new(0.0, 480.0),
    ],
  )
  let session = @moonground.MeasurementSession::new(
    "consumer-gates",
    calibration,
    @moonground.MotionConfig::new(),
  )
  let counter = @events.GateCounter::new(
    "consumer-gates",
    [
      @events.LineGate::new(
        "aisle",
        @moonground.Point2::new(1.25, 0.0),
        @moonground.Point2::new(1.25, 4.0),
        deadband_m=0.01,
      ),
    ],
    @events.GateConfig::new(),
  )
  let observe = (index : Int32) => {
    @moonground.PixelObservation::new(
      7,
      @moonground.Point2::new(100.0 + index.to_double() * 10.0, 200.0),
      @moonground.Covariance2::isotropic(0.25),
    )
  }
  for index in 0..<3 {
    let frame = session.update(index.to_int64() * 200000L, [observe(index)])
    let counted = counter.update(frame.motion)
    assert_eq(counted.crossings.length(), 0)
    if index == 0 {
      assert_true(frame.motion.tracks[0].speed_mps is None)
    }
  }
  // Persist both states after the same accepted measurement frame.
  let measurement_checkpoint = session.checkpoint()
  let gate_checkpoint : @events.GateCheckpoint = counter.checkpoint()
  assert_eq(gate_checkpoint.last_timestamp_us, Some(400000L))
  assert_eq(measurement_checkpoint.motion.last_timestamp_us, Some(400000L))
  let resumed = @moonground.MeasurementSession::from_checkpoint(
    measurement_checkpoint,
  )
  let resumed_counter = @events.GateCounter::from_checkpoint(gate_checkpoint)
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=1.5,
    offset_x=-40.0,
    offset_y=16.0,
  )
  let reframed = session.reframed(transform)
  let reframed_counter = @events.GateCounter::from_checkpoint(gate_checkpoint)
  for index in 3..<5 {
    let timestamp = index.to_int64() * 200000L
    let expected = counter.update(
      session.update(timestamp, [observe(index)]).motion,
    )
    let continued = resumed_counter.update(
      resumed.update(timestamp, [observe(index)]).motion,
    )
    let converted = reframed_counter.update(
      reframed.update(timestamp, [observe(index).reframed(transform)]).motion,
    )
    assert_eq("\{Repr(continued)}", "\{Repr(expected)}")
    assert_eq(converted.crossings.length(), expected.crossings.length())
    assert_eq(converted.counts[0].positive_to_negative, 1L)
    assert_eq(converted.counts[0].negative_to_positive, 0L)
    if index == 3 {
      let crossing = converted.crossings[0]
      assert_eq(crossing.direction, @events.PositiveToNegative)
      assert_eq(crossing.track_id, 7)
      assert_eq(crossing.segment_id, "1")
      assert_eq(crossing.from_timestamp_us, 400000L)
      assert_eq(crossing.to_timestamp_us, 600000L)
      assert_true((crossing.position_m.x - 1.25).abs() < 1.0e-10)
      assert_true((crossing.position_m.y - 2.0).abs() < 1.0e-10)
      assert_true(
        (crossing.crossing_fraction - expected.crossings[0].crossing_fraction).abs() <
        1.0e-10,
      )
    }
  }
  assert_eq(gate_checkpoint.counts[0].positive_to_negative, 0L)
  assert_eq(gate_checkpoint.last_timestamp_us, Some(400000L))
}

///|
test "packaged pixel coordinate adaptation continues warm metric state through root API" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.01, 0.0, 0.0, 0.0, 0.01, 0.0, 0.0, 0.0, 1.0],
    [
      @moonground.Point2::new(0.0, 0.0),
      @moonground.Point2::new(640.0, 0.0),
      @moonground.Point2::new(640.0, 480.0),
      @moonground.Point2::new(0.0, 480.0),
    ],
    ground_noise_floor_m=0.002,
  )
  let original = @moonground.MeasurementSession::new(
    "consumer-pixel-coordinates",
    calibration,
    @moonground.MotionConfig::new(q=0.3),
    camera=@moonground.CameraModel::new(
      fx=600.0,
      fy=580.0,
      cx=320.0,
      cy=240.0,
      k1=-0.1,
      p1=0.001,
      p2=-0.002,
      max_normalized_radius=0.8,
    ),
  )
  let observation = (index : Int32) => {
    @moonground.PixelObservation::new(
      7,
      @moonground.Point2::new(100.0 + index.to_double() * 10.0, 200.0),
      @moonground.Covariance2::new(0.25, 0.05, 0.5),
    )
  }
  for index in 0..<3 {
    ignore(original.update(index.to_int64() * 200000L, [observation(index)]))
  }
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=2.0,
    offset_x=-40.0,
    offset_y=16.0,
  )
  let reframed = original.reframed(transform)
  let before = original.checkpoint().motion
  let after = reframed.checkpoint().motion
  assert_eq(after.last_timestamp_us, before.last_timestamp_us)
  assert_eq(after.next_segment_id, before.next_segment_id)
  assert_eq(after.tracks[0].state, before.tracks[0].state)
  assert_eq(after.tracks[0].covariance, before.tracks[0].covariance)
  assert_eq(after.tracks[0].accepted_count, 3)
  assert_eq(
    after.tracks[0].observed_path_length_m,
    before.tracks[0].observed_path_length_m,
  )
  after.tracks[0].state[0] = 999.0
  after.tracks[0].covariance[0] = 999.0
  assert_eq(
    reframed.checkpoint().motion.tracks[0].state,
    before.tracks[0].state,
  )
  assert_eq(
    original.checkpoint().motion.tracks[0].state,
    before.tracks[0].state,
  )
  for index in 3..<6 {
    let time = index.to_int64() * 200000L
    let expected = original.update(time, [observation(index)])
    let actual = reframed.update(time, [observation(index).reframed(transform)])
    let expected_track = expected.motion.tracks[0]
    let actual_track = actual.motion.tracks[0]
    assert_eq(actual.projection_failures.length(), 0)
    assert_eq(actual_track.status, @motion.Ready)
    assert_eq(actual_track.status, expected_track.status)
    assert_eq(actual_track.segment_id, expected_track.segment_id)
    assert_eq(actual_track.accepted_count, index + 1)
    assert_eq(
      actual_track.last_accepted_timestamp_us,
      expected_track.last_accepted_timestamp_us,
    )
    let expected_state = original.checkpoint().motion.tracks[0]
    let actual_state = reframed.checkpoint().motion.tracks[0]
    for
      (a, b) in [
        (actual_state.state, expected_state.state),
        (actual_state.covariance, expected_state.covariance),
      ] {
      assert_eq(a.length(), b.length())
      for i in 0..<a.length() {
        assert_true((a[i] - b[i]).abs() <= 1.0e-10 * b[i].abs().max(1.0))
      }
    }
    assert_true(
      (actual_track.observed_path_length_m -
      expected_track.observed_path_length_m).abs() <=
      1.0e-10,
    )
    match (actual_track.speed_mps, expected_track.speed_mps) {
      (Some(a), Some(b)) => assert_true((a - b).abs() <= 1.0e-10)
      _ => fail("warm coordinate adaptation lost measured speed")
    }
  }
  let original_closed = original.update(1100000L, [], lost=[7])
  let reframed_closed = reframed.update(1100000L, [], lost=[7])
  assert_eq(reframed_closed.motion.closed_segment_ids, ["1"])
  assert_eq(
    reframed_closed.motion.closed_segment_ids,
    original_closed.motion.closed_segment_ids,
  )
  let restarted = reframed.update(1200000L, [observation(6).reframed(transform)])
  assert_eq(restarted.motion.tracks[0].segment_id, "2")
  assert_eq(restarted.motion.tracks[0].accepted_count, 1)
  assert_true(restarted.motion.tracks[0].speed_mps is None)
}

///|
test "packaged robust calibration rejects mislabeled controls and measures a reusable session" {
  let controls : Array[@moonground.Point2] = [
    { x: 0.0, y: 0.0, },
    { x: 100.0, y: 0.0, },
    { x: 100.0, y: 100.0, },
    { x: 0.0, y: 100.0, },
    { x: 25.0, y: 50.0, },
    { x: 70.0, y: 30.0, },
    { x: 40.0, y: 80.0, },
    { x: 60.0, y: 10.0, },
  ]
  let world = controls.map(p => @moonground.Point2::{
    x: 0.02 * p.x,
    y: 0.02 * p.y,
  })
  world[6] = { x: 1.8, y: 0.6, }
  world[7] = { x: 0.2, y: 2.2, }
  let checks : Array[@moonground.Point2] = [
    { x: 20.0, y: 30.0, },
    { x: 80.0, y: 70.0, },
  ]
  let fitted : @moonground.RobustCalibration = @moonground.GroundCalibration::fit_robust(
    controls,
    world,
    checks,
    checks.map(p => @moonground.Point2::{ x: p.x * 0.02, y: p.y * 0.02, }),
    controls[:4].to_owned(),
    options=@moonground.RobustFitOptions::new(inlier_threshold_m=0.01, seed=17),
    max_check_error_m=0.001,
  )
  assert_eq(fitted.inlier_mask(), [
    true, true, true, true, true, true, false, false,
  ])
  assert_eq(fitted.inlier_count(), 6)
  assert_eq(fitted.calibration().report().fit_count(), 6)
  assert_eq(fitted.control_errors_m().length(), controls.length())
  let session = @moonground.MeasurementSession::new(
    "consumer-robust-fit",
    fitted.calibration(),
    @moonground.MotionConfig::new(),
  )
  let mut measured_speed = None
  for index in 0..<3 {
    let frame = session.update(index.to_int64() * 200000L, [
      @moonground.PixelObservation::new(
        7,
        @moonground.Point2::new(20.0 + index.to_double() * 5.0, 30.0),
        @moonground.Covariance2::isotropic(0.25),
      ),
    ])
    measured_speed = frame.motion.tracks[0].speed_mps
  }
  assert_true(measured_speed is Some(speed) && speed > 0.45 && speed < 0.55)
}

///|
test "packaged camera projection and quality thresholds compose through root API" {
  let camera = @moonground.CameraModel::new(
    fx=100.0,
    fy=80.0,
    cx=50.0,
    cy=50.0,
    k1=-0.1,
  )
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.01, 0.0, 0.0, 0.0, 0.01, 0.0, 0.0, 0.0, 1.0],
    [
      @moonground.Point2::new(0.0, 0.0),
      @moonground.Point2::new(100.0, 0.0),
      @moonground.Point2::new(100.0, 100.0),
      @moonground.Point2::new(0.0, 100.0),
    ],
  )
  let session = @moonground.MeasurementSession::new(
    "packaged-camera",
    calibration,
    @moonground.MotionConfig::new(
      min_observations=2,
      min_span_us=0L,
      max_velocity_std_mps=0.000001,
    ),
    camera~,
  )
  let observation = @moonground.PixelObservation::new(
    1,
    @moonground.Point2::new(50.0, 50.0),
    @moonground.Covariance2::isotropic(1.0),
  )
  ignore(session.update(0L, [observation]))
  let frame = session.update(100000L, [observation])
  assert_eq(frame.motion.tracks[0].status, @motion.Uncertain)
  assert_true(frame.motion.tracks[0].speed_mps is None)
  assert_true(
    frame.motion.tracks[0].velocity_std_mps is Some(value) && value > 0.000001,
  )
  assert_true(frame.motion.tracks[0].velocity is Some(_))
  assert_eq(frame.projection_failures.length(), 0)
}

///|
test "independent consumer measures known contact points and restarts gaps" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.01, 0.0, 0.0, 0.0, 0.01, 0.0, 0.0, 0.0, 1.0],
    [
      @moonground.Point2::new(0.0, 0.0),
      @moonground.Point2::new(640.0, 0.0),
      @moonground.Point2::new(640.0, 480.0),
      @moonground.Point2::new(0.0, 480.0),
    ],
  )
  let session = @moonground.MeasurementSession::new(
    "consumer-contact-points",
    calibration,
    @moonground.MotionConfig::new(),
  )
  let covariance = @moonground.Covariance2::isotropic(0.25)
  let observation = (x : Double) => {
    @moonground.PixelObservation::new(
      7,
      @moonground.Point2::new(x, 200.0),
      covariance,
    )
  }
  let first = session.update(0L, [observation(100.0)])
  assert_true(first.motion.tracks[0].speed_mps is None)
  ignore(session.update(200000L, [observation(110.0)]))
  let ready = session.update(400000L, [observation(120.0)])
  assert_eq(ready.motion.tracks[0].status, @motion.Ready)
  match ready.motion.tracks[0].speed_mps {
    Some(speed) => assert_true(speed > 0.45 && speed < 0.55)
    None => fail("three contact observations should produce a measured speed")
  }
  let restarted = session.update(1000000L, [observation(150.0)])
  assert_eq(restarted.motion.tracks[0].status, @motion.Initializing)
  assert_true(
    restarted.motion.tracks[0].segment_id != ready.motion.tracks[0].segment_id,
  )
  assert_eq(restarted.motion.tracks[0].observed_path_length_m, 0.0)
}

///|
test "published MBMOT output enters a separately calibrated measurement session" {
  let tracker = @mbmot.Tracker::new(@mbmot.TrackerConfig::default())
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.02, 0.0, -1.0, 0.0, 0.02, -2.0, 0.0, 0.0, 1.0],
    [
      @moonground.Point2::new(0.0, 0.0),
      @moonground.Point2::new(640.0, 0.0),
      @moonground.Point2::new(640.0, 480.0),
      @moonground.Point2::new(0.0, 480.0),
    ],
  )
  let session = @moonground.MeasurementSession::new(
    "consumer-mbmot",
    calibration,
    @moonground.MotionConfig::new(),
  )
  let mut last_segment = ""
  for index in 0..<4 {
    let left = 100.0 + index.to_double() * 5.0
    let detection = @mbmot.Detection::new(
      @mbmot.BoundingBox::new(left, 100.0, left + 40.0, 200.0),
      0.95,
      0,
    )
    let tracks = tracker.update(index + 1, [detection])
    assert_eq(tracks.tracks().length(), 1)
    let observations = @consumer.tracker_observations(tracks, 2.0)
    let result = session.update(
      index.to_int64() * 200000L,
      observations,
      lost=tracks.lost(),
      removed=tracks.removed(),
    )
    assert_eq(result.projection_failures.length(), 0)
    assert_eq(result.motion.tracks.length(), 1)
    let estimate = result.motion.tracks[0]
    if index > 0 {
      assert_eq(estimate.segment_id, last_segment)
    }
    last_segment = estimate.segment_id
    if index == 3 {
      assert_eq(estimate.status, @motion.Ready)
      assert_true(estimate.speed_mps is Some(_))
    }
  }
}

///|
/// AP checks the shared bbox coordinates and category only. A perfect detector
/// fixture does not establish ground-plane calibration or speed accuracy.
test "the same detector bbox feeds measurement and MoonDetEval 0.2.1" {
  let bbox = @mbmot.BoundingBox::new(100.0, 100.0, 140.0, 200.0)
  let tracker = @mbmot.Tracker::new(@mbmot.TrackerConfig::default())
  let tracks = tracker.update(1, [@mbmot.Detection::new(bbox, 0.95, 0)])
  let contact = @consumer.tracker_observations(tracks, 2.0)
  assert_eq(contact.length(), 1)
  assert_eq(contact[0].position.x, 120.0)
  assert_eq(contact[0].position.y, 200.0)
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.02, 0.0, -1.0, 0.0, 0.02, -2.0, 0.0, 0.0, 1.0],
    [
      @moonground.Point2::new(0.0, 0.0),
      @moonground.Point2::new(640.0, 0.0),
      @moonground.Point2::new(640.0, 480.0),
      @moonground.Point2::new(0.0, 480.0),
    ],
  )
  let measurement = @moonground.MeasurementSession::new(
    "consumer-detector-coordinate-check",
    calibration,
    @moonground.MotionConfig::new(),
  ).update(0L, contact)
  assert_eq(measurement.projection_failures.length(), 0)
  assert_true(measurement.motion.tracks[0].speed_mps is None)
  let evaluated_box = @moondeteval.Box::new(
    bbox.x1(),
    bbox.y1(),
    bbox.x2(),
    bbox.y2(),
  )
  let dataset = @moondeteval.Dataset::new(
    [@moondeteval.Image::new(1, 640, 480)],
    [@moondeteval.Category::new(7, "person")],
    [@moondeteval.GroundTruth::new(11L, 1, 7, evaluated_box, area=4000.0)],
  )
  let report = @moondeteval.evaluate(dataset, [
    @moondeteval.Detection::new(0, 1, 7, evaluated_box, 0.95),
  ])
  assert_eq(report.summary().ap50(), 1.0)
}

///|
test "packaged typed checkpoint resumes measured motion and keeps independent state" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.01, 0.0, 0.0, 0.0, 0.01, 0.0, 0.0, 0.0, 1.0],
    [
      @moonground.Point2::new(0.0, 0.0),
      @moonground.Point2::new(640.0, 0.0),
      @moonground.Point2::new(640.0, 480.0),
      @moonground.Point2::new(0.0, 480.0),
    ],
  )
  let session = @moonground.MeasurementSession::new(
    "consumer-checkpoint",
    calibration,
    @moonground.MotionConfig::new(q=0.3),
  )
  let observation = (x : Double) => {
    @moonground.PixelObservation::new(
      7,
      @moonground.Point2::new(x, 200.0),
      @moonground.Covariance2::isotropic(0.25),
    )
  }
  for index in 0..<3 {
    ignore(
      session.update(index.to_int64() * 200000L, [
        observation(100.0 + index.to_double() * 10.0),
      ]),
    )
  }
  let checkpoint : @moonground.MeasurementCheckpoint = session.checkpoint()
  assert_eq(checkpoint.motion.tracks[0].accepted_count, 3)
  let saved_state = checkpoint.motion.tracks[0].state.copy()
  let saved_covariance = checkpoint.motion.tracks[0].covariance.copy()
  let restored = @moonground.MeasurementSession::from_checkpoint(checkpoint)
  checkpoint.motion.tracks[0].state[0] = 1.0e30
  checkpoint.motion.tracks[0].covariance[0] = 1.0e30
  for independent in [session, restored] {
    let unchanged = independent.checkpoint().motion.tracks[0]
    assert_eq(unchanged.state, saved_state)
    assert_eq(unchanged.covariance, saved_covariance)
  }
  for index in 3..<5 {
    let timestamp = index.to_int64() * 200000L
    let observations = [observation(100.0 + index.to_double() * 10.0)]
    let expected = session.update(timestamp, observations)
    let actual = restored.update(timestamp, observations)
    // FrameResult includes vectors, complete P, uncertainty, path, counts,
    // accepted timestamps and closed segment IDs.
    assert_eq("\{Repr(actual.motion)}", "\{Repr(expected.motion)}")
    assert_eq(actual.projection_failures.length(), 0)
    assert_eq(actual.motion.tracks[0].accepted_count, index + 1)
    assert_eq(actual.motion.tracks[0].status, @motion.Ready)
    assert_eq(actual.motion.tracks[0].segment_id, "1")
    assert_true(actual.motion.tracks[0].observed_path_length_m > 0.2)
  }
  let expected_closed = session.update(900000L, [], lost=[7])
  let actual_closed = restored.update(900000L, [], lost=[7])
  assert_eq("\{Repr(actual_closed.motion)}", "\{Repr(expected_closed.motion)}")
  assert_eq(actual_closed.motion.closed_segment_ids, ["1"])
  let expected_new = session.update(1000000L, [observation(150.0)])
  let actual_new = restored.update(1000000L, [observation(150.0)])
  assert_eq("\{Repr(actual_new.motion)}", "\{Repr(expected_new.motion)}")
  assert_eq(actual_new.motion.tracks[0].segment_id, "2")
  assert_eq(actual_new.motion.tracks[0].accepted_count, 1)
  assert_eq(actual_new.motion.tracks[0].observed_path_length_m, 0.0)
  assert_true(actual_new.motion.tracks[0].speed_mps is None)
}

///|
test "packaged joint analysis restores reframes and rolls back counting failures" {
  let measurement = @moonground.MeasurementSession::new(
    "consumer-analysis",
    @moonground.GroundCalibration::from_homography(
      [0.01, 0.0, 0.0, 0.0, 0.01, 0.0, 0.0, 0.0, 1.0],
      [
        { x: 0.0, y: 0.0, },
        { x: 640.0, y: 0.0, },
        { x: 640.0, y: 480.0, },
        { x: 0.0, y: 480.0, },
      ],
    ),
    @moonground.MotionConfig::new(gate=1.0e12),
  )
  let counting = @events.GateCounter::new(
    "consumer-analysis",
    [
      @events.LineGate::new(
        "aisle",
        { x: 1.15, y: 0.0, },
        { x: 1.15, y: 4.0, },
        deadband_m=0.01,
      ),
    ],
    @events.GateConfig::new(),
  )
  let session = @analysis.AnalysisSession::from_pixel(measurement, counting)
  let observe = (x : Double) => {
    @moonground.PixelObservation::new(
      7,
      { x, y: 200.0, },
      @moonground.Covariance2::isotropic(0.25),
    )
  }
  for index in 0..<3 {
    ignore(
      session.update_pixel(index.to_int64() * 200000L, [
        observe(100.0 + 10.0 * index.to_double()),
      ]),
    )
  }
  let checkpoint = session.checkpoint()
  assert_eq(checkpoint.counting.counts[0].positive_to_negative, 1L)
  checkpoint.counting.counts[0] = {
    ..checkpoint.counting.counts[0],
    negative_to_positive: 9223372036854775807L,
  }
  let expected = @analysis.AnalysisSession::from_checkpoint(checkpoint)
  let restored = @analysis.AnalysisSession::from_checkpoint(checkpoint)
  let transform = @moonground.PixelTransform::new(
    scale_x=2.0,
    scale_y=0.5,
    offset_x=4.0,
    offset_y=-2.0,
  )
  let adapted = restored.reframed(transform)
  let next = adapted.update_pixel(600000L, [observe(130.0).reframed(transform)])
  let original = expected.update_pixel(600000L, [observe(130.0)])
  assert_eq(next.counting.counts[0].positive_to_negative, 1L)
  assert_eq(
    next.measurement.motion.tracks[0].filtered_state,
    original.measurement.motion.tracks[0].filtered_state,
  )
  let before = adapted.checkpoint()
  try adapted.update_pixel(800000L, [observe(90.0).reframed(transform)]) catch {
    _ => ()
  } noraise {
    _ => fail("exhausted joint counter accepted a crossing")
  }
  let after = adapted.checkpoint()
  assert_eq(after.counting.last_timestamp_us, before.counting.last_timestamp_us)
  assert_eq(
    after.counting.counts[0].negative_to_positive,
    before.counting.counts[0].negative_to_positive,
  )
  guard (before.measurement, after.measurement) is (Pixel(before), Pixel(after)) else {
    fail("pixel analysis lost its measurement mode")
  }
  assert_eq(after.motion.last_timestamp_us, Some(600000L))
  assert_eq(after.motion.next_segment_id, before.motion.next_segment_id)
  assert_eq(after.motion.tracks[0].state, before.motion.tracks[0].state)
  assert_eq(
    after.motion.tracks[0].covariance,
    before.motion.tracks[0].covariance,
  )
  let retry = adapted.update_pixel(800000L, [observe(140.0).reframed(transform)])
  assert_eq(retry.measurement.motion.tracks[0].accepted_count, 5)
  assert_eq(retry.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(restored.checkpoint().counting.last_timestamp_us, Some(400000L))
}

///|
test "packaged Brown fixed landmarks confirm health restore and reframe independently" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.02, 0.0, 0.0, 0.0, 0.02, 0.0, 0.0, 0.0, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 640.0, y: 0.0, },
      { x: 640.0, y: 480.0, },
      { x: 0.0, y: 480.0, },
    ],
    ground_noise_floor_m=0.01,
  )
  let camera = @moonground.CameraModel::new(
    fx=600.0,
    fy=580.0,
    cx=320.0,
    cy=240.0,
    k1=-0.12,
    k2=0.015,
    p1=0.001,
    p2=-0.002,
    k3=0.001,
    max_normalized_radius=0.8,
  )
  let ids = ["A", "B", "C"]
  let references = [
    @health.KnownLandmark::new("A", { x: 3.2, y: 3.2, }),
    @health.KnownLandmark::new("B", { x: 6.4, y: 2.4, }),
    @health.KnownLandmark::new("C", { x: 9.6, y: 6.4, }),
  ]
  // These original-image coordinates come from examples/health.ndjson;
  // the second set projects 0.3 m to the right of each independent reference.
  let original_pixels : Array[@moonground.Point2] = [
    { x: 161.47630472780403, y: 160.84451293993584, },
    { x: 319.9486325802616, y: 120.68758411830997, },
    { x: 478.05431120560854, y: 319.13351617883814, },
  ]
  let shifted_pixels : Array[@moonground.Point2] = [
    { x: 176.14105629796143, y: 160.7257189052479, },
    { x: 334.8624251931698, y: 120.70884918294097, },
    { x: 492.5618541503113, y: 319.0028970224668, },
  ]
  let observe = (points : Array[@moonground.Point2]) => {
    Array::makei(points.length(), index => {
      @health.LandmarkObservation::new(
        ids[index],
        points[index],
        @moonground.Covariance2::isotropic(2.0),
      )
    })
  }
  let monitor = @health.CalibrationMonitor::new(
    calibration,
    references,
    @health.HealthConfig::new(max_position_std_m=0.1),
    camera~,
  )
  assert_eq(
    monitor.update(0L, observe(original_pixels)).status,
    @health.Pending,
  )
  ignore(monitor.update(150000L, observe(original_pixels)))
  let healthy = monitor.update(300000L, observe(original_pixels))
  assert_eq(healthy.status, @health.Healthy)
  guard healthy.max_error_m is Some(error) else {
    fail("missing health residual")
  }
  assert_true(error < 1.0e-8)
  let saved = monitor.checkpoint()
  let restored = @health.CalibrationMonitor::from_checkpoint(saved)
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=0.75,
    offset_x=-40.0,
    offset_y=16.0,
  )
  let adapted = restored.reframed(transform)
  for time in [400000L, 550000L, 700000L] {
    let original = monitor.update(time, observe(shifted_pixels))
    let next = adapted.update(
      time,
      observe(shifted_pixels).map(item => item.reframed(transform)),
    )
    assert_eq(next.status, original.status)
    assert_eq(next.evidence, @health.BeyondTolerance)
    assert_eq(next.streak_since_us, Some(400000L))
    guard next.rms_error_m is Some(rms) else {
      fail("missing shifted residual")
    }
    assert_true((rms - 0.3).abs() < 1.0e-8)
  }
  let confirmed = @health.CalibrationMonitor::from_checkpoint(
    adapted.checkpoint(),
  )
  let baseline = observe(original_pixels).map(item => item.reframed(transform))
  let incomplete = confirmed.update(800000L, [baseline[0]])
  assert_eq(incomplete.usable_count, 1)
  assert_eq(incomplete.status, @health.HealthStatus::Insufficient)
  assert_eq(incomplete.streak_since_us, None)
  assert_eq(adapted.checkpoint().last_timestamp_us, Some(700000L))
  assert_eq(restored.checkpoint().last_timestamp_us, Some(300000L))
  assert_eq(confirmed.update(900000L, baseline).status, @health.Pending)
  let unknown = @health.LandmarkObservation::new(
    "unknown",
    original_pixels[0],
    @moonground.Covariance2::isotropic(2.0),
  )
  try confirmed.update(1050000L, [unknown]) catch {
    _ => ()
  } noraise {
    _ => fail("unknown fixed landmark accepted")
  }
  assert_eq(confirmed.checkpoint().last_timestamp_us, Some(900000L))
  ignore(confirmed.update(1050000L, baseline))
  assert_eq(confirmed.update(1200000L, baseline).status, @health.Healthy)
}

///|
test "packaged Brown guarded analysis closes hidden active state and recovers with a new segment" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.02, 0.0, 0.0, 0.0, 0.02, 0.0, 0.0, 0.0, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 640.0, y: 0.0, },
      { x: 640.0, y: 480.0, },
      { x: 0.0, y: 480.0, },
    ],
    ground_noise_floor_m=0.01,
  )
  let camera = @moonground.CameraModel::new(
    fx=600.0,
    fy=580.0,
    cx=320.0,
    cy=240.0,
    k1=-0.12,
    k2=0.015,
    p1=0.001,
    p2=-0.002,
    k3=0.001,
    max_normalized_radius=0.8,
  )
  let analysis = @analysis.AnalysisSession::from_pixel(
    @moonground.MeasurementSession::new(
      "consumer-guarded",
      calibration,
      @moonground.MotionConfig::new(q=1000000.0, gate=1.0e12, max_tracks=10),
      camera~,
    ),
    @events.GateCounter::new(
      "consumer-guarded",
      [
        @events.LineGate::new(
          "aisle",
          { x: 6.0, y: 0.0, },
          { x: 6.0, y: 9.0, },
          deadband_m=0.05,
        ),
      ],
      @events.GateConfig::new(max_tracks=10),
    ),
  )
  let health = @health.CalibrationMonitor::new(
    calibration,
    [
      @health.KnownLandmark::new("A", { x: 3.2, y: 3.2, }),
      @health.KnownLandmark::new("B", { x: 6.4, y: 2.4, }),
      @health.KnownLandmark::new("C", { x: 9.6, y: 6.4, }),
    ],
    @health.HealthConfig::new(max_position_std_m=0.1),
    camera~,
  )
  let covariance = @moonground.Covariance2::isotropic(2.0)
  // Original-image fixture coordinates, kept separate from the metric rule.
  let landmarks = [
    @health.LandmarkObservation::new(
      "A",
      { x: 161.47630472780403, y: 160.84451293993584, },
      covariance,
    ),
    @health.LandmarkObservation::new(
      "B",
      { x: 319.9486325802616, y: 120.68758411830997, },
      covariance,
    ),
    @health.LandmarkObservation::new(
      "C",
      { x: 478.05431120560854, y: 319.13351617883814, },
      covariance,
    ),
  ]
  let left = @moonground.PixelObservation::new(
    7,
    { x: 280.035445256476, y: 299.92835400721356, },
    covariance,
  )
  let right = @moonground.PixelObservation::new(
    7,
    { x: 319.9871581450654, y: 299.9416727043558, },
    covariance,
  )
  let session = @guarded.GuardedSession::new(analysis, health)
  for time in [0L, 150000L] {
    assert_eq(
      session.update(time, landmarks, [left]).decision,
      @guarded.Blocked,
    )
  }
  let allowed = session.update(300000L, landmarks, [left])
  assert_eq(allowed.decision, @guarded.Allowed)
  assert_eq(allowed.analysis.measurement.motion.tracks[0].segment_id, "1")
  let crossed = session.update(350000L, landmarks, [right])
  assert_eq(crossed.analysis.counting.counts[0].positive_to_negative, 1L)
  let restored = @guarded.GuardedSession::from_checkpoint(session.checkpoint())
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=0.75,
    offset_x=-40.0,
    offset_y=16.0,
  )
  let adapted = restored.reframed(transform)
  // No object is submitted now: the previously accepted hidden filter must
  // still be ended, while suppression lists only this frame's observations.
  let blocked = adapted.update(400000L, [], [])
  assert_eq(blocked.decision, @guarded.Blocked)
  assert_eq(blocked.suppressed_track_ids, [])
  assert_eq(blocked.analysis.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(blocked.analysis.measurement.motion.tracks.length(), 0)
  assert_eq(blocked.analysis.counting.counts[0].positive_to_negative, 1L)
  let snapshot = adapted.checkpoint()
  guard snapshot.analysis.measurement is Pixel(pixel) else {
    fail("guarded mode changed")
  }
  assert_eq(pixel.motion.tracks.length(), 0)
  assert_eq(pixel.motion.next_segment_id, 2L)
  assert_eq(snapshot.analysis.counting.tracks.length(), 0)
  assert_eq(snapshot.health.last_timestamp_us, Some(400000L))
  let continuation = @guarded.GuardedSession::from_checkpoint(snapshot)
  let transformed_landmarks = landmarks.map(item => item.reframed(transform))
  for time in [500000L, 650000L] {
    assert_eq(
      continuation.update(time, transformed_landmarks, [
        left.reframed(transform),
      ]).decision,
      @guarded.Blocked,
    )
  }
  let recovery = continuation.update(800000L, transformed_landmarks, [
    left.reframed(transform),
  ])
  assert_eq(recovery.decision, @guarded.Allowed)
  assert_eq(recovery.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(recovery.analysis.measurement.motion.tracks[0].accepted_count, 1)
  assert_eq(
    recovery.analysis.measurement.motion.tracks[0].observed_path_length_m,
    0.0,
  )
  assert_eq(recovery.analysis.measurement.motion.tracks[0].speed_mps, None)
  assert_eq(recovery.analysis.counting.crossings.length(), 0)
  let recrossed = continuation.update(850000L, transformed_landmarks, [
    right.reframed(transform),
  ])
  assert_eq(recrossed.analysis.counting.counts[0].positive_to_negative, 2L)
  assert_eq(recrossed.analysis.counting.counts[0].negative_to_positive, 0L)
  assert_eq(restored.checkpoint().health.last_timestamp_us, Some(350000L))
}
