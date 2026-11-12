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
