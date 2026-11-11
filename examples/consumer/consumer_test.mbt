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
