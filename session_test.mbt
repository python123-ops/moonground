///|
fn make_test_session(
  max_tracks~ : Int32 = 1000,
  camera? : @moonground.CameraModel,
) -> @moonground.MeasurementSession raise @types.GroundError {
  let roi : Array[@moonground.Point2] = [
    { x: -10.0, y: -10.0, },
    { x: 10.0, y: -10.0, },
    { x: 10.0, y: 10.0, },
    { x: -10.0, y: 10.0, },
  ]
  let calibration = @moonground.GroundCalibration::from_homography(
    [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    roi,
    max_meters_per_pixel=2.0,
  )
  @moonground.MeasurementSession::new(
    "public-api",
    calibration,
    @moonground.MotionConfig::new(max_tracks~),
    camera?,
  )
}

///|
fn pixel(
  id : Int32,
  x : Double,
  y : Double,
) -> @moonground.PixelObservation raise @types.GroundError {
  @moonground.PixelObservation::new(
    id,
    @moonground.Point2::new(x, y),
    @moonground.Covariance2::isotropic(0.1),
  )
}

///|
test "measurement session capacity failures roll back the complete motion frame" {
  let session = make_test_session(max_tracks=2)
  ignore(session.update(0L, [pixel(1, 0.0, 0.0)]))
  try session.update(100000L, [pixel(2, 1.0, 0.0), pixel(3, 2.0, 0.0)]) catch {
    _ => ()
  } noraise {
    _ => fail("active capacity overflow accepted")
  }
  assert_eq(session.active_track_count(), 1)
  // Retrying the same timestamp proves the failed frame did not advance time.
  let result = session.update(100000L, [pixel(1, 0.1, 0.0), pixel(2, 1.0, 0.0)])
  assert_eq(result.motion.tracks[0].accepted_count, 2)
  assert_eq(result.motion.tracks[1].segment_id, "2")
  assert_eq(session.active_track_count(), 2)
}

///|
test "projection failures cannot hide duplicate or lifecycle conflicts" {
  let session = make_test_session()
  try session.update(0L, [pixel(9, 100.0, 0.0), pixel(9, 101.0, 0.0)]) catch {
    _ => ()
  } noraise {
    _ => fail("duplicate out-of-ROI identity accepted")
  }
  try session.update(0L, [pixel(9, 100.0, 0.0)], lost=[9]) catch {
    _ => ()
  } noraise {
    _ => fail("projection rejection hid lost conflict")
  }
  try session.update(0L, [pixel(9, 100.0, 0.0)], removed=[9]) catch {
    _ => ()
  } noraise {
    _ => fail("projection rejection hid removed conflict")
  }
  assert_eq(session.active_track_count(), 0)
  let valid = session.update(0L, [pixel(1, 0.0, 0.0)])
  assert_eq(valid.motion.tracks[0].segment_id, "1")
}

///|
test "mixed measurable and rejected pixel targets commit independently" {
  let session = make_test_session()
  let first = session.update(0L, [pixel(1, 0.0, 0.0), pixel(2, 100.0, 0.0)])
  assert_eq(first.motion.tracks.length(), 1)
  assert_eq(first.motion.tracks[0].track_id, 1)
  assert_eq(first.projection_failures.length(), 1)
  assert_eq(first.projection_failures[0].track_id, 2)
  assert_true(first.projection_failures[0].reason.length() > 0)
  assert_eq(session.active_track_count(), 1)
  let second = session.update(100000L, [pixel(1, 0.1, 0.0), pixel(2, 1.0, 0.0)])
  assert_eq(second.motion.tracks[0].accepted_count, 2)
  assert_eq(second.motion.tracks[1].segment_id, "2")
  assert_eq(second.projection_failures.length(), 0)
}

///|
test "pixel capacity applies before projection can drop observations" {
  let session = make_test_session(max_tracks=1)
  try session.update(0L, [pixel(1, 0.0, 0.0), pixel(2, 100.0, 0.0)]) catch {
    _ => ()
  } noraise {
    _ => fail("projection drop bypassed frame capacity")
  }
  assert_eq(session.active_track_count(), 0)
  let result = session.update(0L, [pixel(1, 0.0, 0.0)])
  assert_eq(result.motion.tracks[0].segment_id, "1")
}

///|
test "invalid pixel covariance rejects the frame before any target changes" {
  let session = make_test_session()
  ignore(session.update(0L, [pixel(1, 0.0, 0.0)]))
  let malformed : @moonground.PixelObservation = {
    track_id: 2,
    position: { x: 1.0, y: 0.0, },
    covariance: { xx: 1.0, xy: 2.0, yy: 1.0, },
  }
  try session.update(100000L, [pixel(1, 0.1, 0.0), malformed]) catch {
    _ => ()
  } noraise {
    _ => fail("indefinite input covariance accepted")
  }
  let result = session.update(100000L, [pixel(1, 0.1, 0.0)])
  assert_eq(result.motion.tracks[0].accepted_count, 2)
  assert_eq(session.active_track_count(), 1)
}

///|
test "microsecond time arithmetic remains valid near Int64 maximum" {
  let session = make_test_session()
  let last = 9223372036854775807L
  ignore(session.update(last - 400000L, [pixel(1, 0.0, 0.0)]))
  ignore(session.update(last - 200000L, [pixel(1, 0.2, 0.0)]))
  let ready = session.update(last, [pixel(1, 0.4, 0.0)]).motion.tracks[0]
  assert_eq(ready.accepted_count, 3)
  assert_eq(ready.last_accepted_timestamp_us, last)
  guard ready.speed_mps is Some(speed) else {
    fail("ready near-max frame has no speed")
  }
  assert_true((speed - 1.0).abs() < 0.1)
  try session.update(last, []) catch {
    _ => ()
  } noraise {
    _ => fail("nonincreasing terminal timestamp accepted")
  }
  assert_eq(session.active_track_count(), 1)
}

///|
test "lost identity reappearance begins a fresh segment and warmup" {
  let session = make_test_session(max_tracks=1)
  ignore(session.update(0L, [pixel(1, 0.0, 0.0)]))
  ignore(session.update(150000L, [pixel(1, 0.15, 0.0)]))
  ignore(session.update(300000L, [pixel(1, 0.3, 0.0)]))
  let lost = session.update(350000L, [], lost=[1])
  assert_eq(lost.motion.closed_segment_ids, ["1"])
  assert_eq(session.active_track_count(), 0)
  let resumed = session.update(400000L, [pixel(1, 0.4, 0.0)]).motion.tracks[0]
  assert_eq(resumed.segment_id, "2")
  assert_eq(resumed.accepted_count, 1)
  assert_eq(resumed.speed_mps, None)
  assert_eq(resumed.observed_path_length_m, 0.0)
}

///|
test "projection-only frames still enforce global frame time" {
  let session = make_test_session()
  let rejected = session.update(200000L, [pixel(1, 100.0, 0.0)])
  assert_eq(rejected.projection_failures.length(), 1)
  assert_eq(rejected.motion.tracks.length(), 0)
  try session.update(200000L, [pixel(1, 0.0, 0.0)]) catch {
    _ => ()
  } noraise {
    _ => fail("projection-only committed frame did not advance clock")
  }
  let valid = session.update(300000L, [pixel(1, 0.0, 0.0)])
  assert_eq(valid.motion.tracks[0].segment_id, "1")
}

///|
test "camera correction precedes the fixed rectified ROI in a measurement session" {
  let camera = @moonground.CameraModel::new(
    fx=10.0,
    fy=10.0,
    cx=0.0,
    cy=0.0,
    k1=0.1,
  )
  let session = make_test_session(camera~)
  let frame = session.update(0L, [
    pixel(1, 10.870299, 0.0),
    pixel(2, 100.0, 0.0),
  ])
  assert_eq(frame.motion.tracks.length(), 1)
  assert_eq(frame.motion.tracks[0].track_id, 1)
  guard frame.motion.tracks[0].position is Some(point) else {
    fail("initial corrected position is absent")
  }
  assert_true((point.x - 9.9).abs() < 1.0e-8)
  assert_eq(frame.projection_failures.length(), 1)
  assert_eq(frame.projection_failures[0].track_id, 2)
  assert_eq(session.active_track_count(), 1)
}

///|
test "camera rejections cannot conceal duplicate identities or advance a failed frame" {
  let camera = @moonground.CameraModel::new(
    fx=10.0,
    fy=20.0,
    cx=0.0,
    cy=0.0,
    k1=0.1,
  )
  let session = make_test_session(camera~)
  try session.update(0L, [pixel(1, 1000.0, 0.0), pixel(1, 1001.0, 0.0)]) catch {
    _ => ()
  } noraise {
    _ => fail("camera failures concealed duplicate identities")
  }
  let first = session.update(0L, [pixel(1, 0.0, 0.0)])
  assert_eq(first.motion.tracks[0].segment_id, "1")
  let invalid_covariance : @moonground.PixelObservation = {
    track_id: 2,
    position: { x: 1000.0, y: 0.0, },
    covariance: { xx: 1.0, xy: 2.0, yy: 1.0, },
  }
  try session.update(100000L, [pixel(1, 0.1, 0.0), invalid_covariance]) catch {
    _ => ()
  } noraise {
    _ => fail("camera rejection concealed malformed covariance")
  }
  let retried = session.update(100000L, [pixel(1, 0.1, 0.0)])
  assert_eq(retried.motion.tracks[0].accepted_count, 2)
  assert_eq(session.active_track_count(), 1)
}

///|
test "a committed camera-only rejection still consumes global frame time" {
  let camera = @moonground.CameraModel::new(fx=10.0, fy=10.0, cx=0.0, cy=0.0)
  let session = make_test_session(camera~)
  let rejected = session.update(200000L, [pixel(1, 1000.0, 0.0)])
  assert_eq(rejected.projection_failures.length(), 1)
  assert_eq(rejected.motion.tracks.length(), 0)
  try session.update(200000L, [pixel(1, 0.0, 0.0)]) catch {
    _ => ()
  } noraise {
    _ => fail("camera-only rejection did not commit time")
  }
  let accepted = session.update(300000L, [pixel(1, 0.0, 0.0)])
  assert_eq(accepted.motion.tracks[0].segment_id, "1")
}
