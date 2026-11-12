///|
fn reframe_close(actual : Double, expected : Double) -> Unit raise {
  assert_true((actual - expected).abs() <= 1.0e-9 * expected.abs().max(1.0))
}

///|
fn reframe_optional_close(actual : Double?, expected : Double?) -> Unit raise {
  match (actual, expected) {
    (Some(a), Some(b)) => reframe_close(a, b)
    (None, None) => ()
    _ => fail("coordinate adaptation changed result availability")
  }
}

///|
fn reframe_arrays_close(
  actual : Array[Double]?,
  expected : Array[Double]?,
) -> Unit raise {
  match (actual, expected) {
    (Some(a), Some(b)) => {
      assert_eq(a.length(), b.length())
      for i in 0..<a.length() {
        reframe_close(a[i], b[i])
      }
    }
    (None, None) => ()
    _ => fail("coordinate adaptation changed filter state availability")
  }
}

///|
fn compare_reframed_frames(
  actual : @moonground.MeasurementFrame,
  expected : @moonground.MeasurementFrame,
) -> Unit raise {
  assert_eq(actual.motion.session_id, expected.motion.session_id)
  assert_eq(actual.motion.timestamp_us, expected.motion.timestamp_us)
  assert_eq(
    actual.motion.closed_segment_ids,
    expected.motion.closed_segment_ids,
  )
  assert_eq(
    actual.projection_failures.length(),
    expected.projection_failures.length(),
  )
  for i in 0..<actual.projection_failures.length() {
    assert_eq(
      actual.projection_failures[i].track_id,
      expected.projection_failures[i].track_id,
    )
  }
  assert_eq(actual.motion.tracks.length(), expected.motion.tracks.length())
  for i in 0..<actual.motion.tracks.length() {
    let a = actual.motion.tracks[i]
    let b = expected.motion.tracks[i]
    assert_eq(a.track_id, b.track_id)
    assert_eq(a.segment_id, b.segment_id)
    assert_eq(a.status, b.status)
    assert_eq(a.accepted_count, b.accepted_count)
    assert_eq(a.last_accepted_timestamp_us, b.last_accepted_timestamp_us)
    reframe_arrays_close(a.filtered_state, b.filtered_state)
    reframe_arrays_close(a.filtered_covariance, b.filtered_covariance)
    reframe_optional_close(a.position_std_m, b.position_std_m)
    reframe_optional_close(a.velocity_std_mps, b.velocity_std_mps)
    reframe_optional_close(a.speed_mps, b.speed_mps)
    reframe_close(a.observed_path_length_m, b.observed_path_length_m)
    reframe_close(a.net_displacement_m, b.net_displacement_m)
  }
}

///|
fn reframe_session(
  distorted : Bool,
  uncertain : Bool,
) -> @moonground.MeasurementSession raise @types.GroundError {
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.1, 0.02, 1.0, -0.01, 0.08, 2.0, 0.001, -0.0003, 1.0],
    [
      { x: -20.0, y: -20.0, },
      { x: 20.0, y: -20.0, },
      { x: 20.0, y: 20.0, },
      { x: -20.0, y: 20.0, },
    ],
  )
  let camera = if distorted {
    Some(
      @moonground.CameraModel::new(
        fx=30.0,
        fy=40.0,
        cx=0.0,
        cy=0.0,
        k1=0.05,
        k2=-0.004,
        p1=0.001,
        p2=-0.002,
        k3=0.001,
      ),
    )
  } else {
    None
  }
  let limit = if uncertain { Some(1.0e-8) } else { None }
  @moonground.MeasurementSession::new(
    "coordinate-adaptation",
    calibration,
    @moonground.MotionConfig::new(
      min_observations=3,
      min_span_us=200000L,
      q=0.1,
      max_velocity_std_mps?=limit,
    ),
    camera?,
  )
}

///|
fn reframe_fixture_frame(
  session : @moonground.MeasurementSession,
  index : Int32,
  transform? : @types.PixelTransform,
) -> @moonground.MeasurementFrame raise @types.GroundError {
  let samples : Array[(Int32, Double, Double)] = match index {
    0 => [(1, 0.0, 0.0), (2, -2.0, 1.0)]
    1 => [(1, 0.4, 0.1), (2, -1.6, 1.1)]
    2 => [(1, 0.8, 0.2), (2, -1.2, 1.2)]
    3 => [(1, 15.0, 12.0)]
    5 => [(1, 1000.0, 0.0)]
    7 => [(1, 1.2, 0.3), (2, -0.8, 1.3)]
    9 => [(1, 1.6, 0.4), (2, -0.4, 1.4)]
    10 => [(1, 2.0, 0.5)]
    11 => [(1, 2.4, 0.6)]
    _ => []
  }
  let observations : Array[@moonground.PixelObservation] = []
  for sample in samples {
    let observation = @moonground.PixelObservation::new(
      sample.0,
      { x: sample.1, y: sample.2, },
      @moonground.Covariance2::new(0.04, 0.01, 0.09),
    )
    observations.push(
      match transform {
        Some(value) => observation.reframed(value)
        None => observation
      },
    )
  }
  let times = [
    0L, 100000L, 200000L, 300000L, 400000L, 450000L, 500000L, 550000L, 650000L, 700000L,
    1200000L, 1300000L,
  ]
  session.update(
    times[index],
    observations,
    lost=if index == 6 { [2] } else { [] },
    removed=if index == 8 { [1] } else { [] },
  )
}

///|
test "session coordinate adaptation preserves warm uncertain rejected missing and closed-segment continuation" {
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=1.75,
    offset_x=-13.0,
    offset_y=21.0,
  )
  for distorted in [false, true] {
    for uncertain in [false, true] {
      for cut in [0, 1, 3, 4, 5, 6, 7, 8, 10] {
        let original = reframe_session(distorted, uncertain)
        for i in 0..<cut {
          ignore(reframe_fixture_frame(original, i))
        }
        let before = original.checkpoint().motion
        let adapted = original.reframed(transform)
        let copied = adapted.checkpoint().motion
        assert_eq(copied.last_timestamp_us, before.last_timestamp_us)
        assert_eq(copied.next_segment_id, before.next_segment_id)
        assert_eq(copied.tracks.length(), before.tracks.length())
        for i in 0..<before.tracks.length() {
          assert_eq(copied.tracks[i].state, before.tracks[i].state)
          assert_eq(copied.tracks[i].covariance, before.tracks[i].covariance)
          assert_eq(
            copied.tracks[i].accepted_count,
            before.tracks[i].accepted_count,
          )
          assert_eq(
            copied.tracks[i].observed_path_length_m,
            before.tracks[i].observed_path_length_m,
          )
        }
        for i in cut..<12 {
          let expected = reframe_fixture_frame(original, i)
          let actual = reframe_fixture_frame(adapted, i, transform~)
          compare_reframed_frames(actual, expected)
          if i == 0 {
            assert_eq(expected.motion.tracks[0].status, @motion.Initializing)
          }
          if i == 2 {
            assert_eq(
              expected.motion.tracks[0].status,
              if uncertain {
                @motion.Uncertain
              } else {
                @motion.Ready
              },
            )
          }
          if i == 3 {
            assert_eq(
              expected.motion.tracks[0].status,
              @motion.RejectedInnovation,
            )
          }
          if i == 4 {
            assert_eq(expected.motion.tracks.length(), 0)
          }
          if i == 5 {
            assert_eq(expected.projection_failures.length(), 1)
          }
          if i == 6 {
            assert_eq(expected.motion.closed_segment_ids, ["2"])
          }
          if i == 7 {
            assert_eq(expected.motion.tracks[1].segment_id, "3")
          }
          if i == 9 {
            assert_eq(expected.motion.tracks[0].segment_id, "4")
          }
          if i == 10 {
            assert_eq(expected.motion.tracks[0].segment_id, "5")
          }
        }
      }
    }
  }
}

///|
test "sequential inverse and composed session coordinate adaptations retain independent SI state" {
  let original = reframe_session(true, false)
  for i in 0..<3 {
    ignore(reframe_fixture_frame(original, i))
  }
  let first = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=2.0,
    offset_x=-10.0,
    offset_y=13.0,
  )
  let next = @moonground.PixelTransform::new(
    scale_x=3.0,
    scale_y=0.75,
    offset_x=9.0,
    offset_y=-4.0,
  )
  let sequential = original.reframed(first).reframed(next)
  let combined = original.reframed(first.then(next))
  let recovered = original.reframed(first).reframed(first.inverse())
  let exported = sequential.checkpoint()
  exported.motion.tracks[0].state[0] = 999.0
  exported.motion.tracks[0].covariance[0] = 999.0
  assert_true(sequential.checkpoint().motion.tracks[0].state[0] != 999.0)
  assert_true(original.checkpoint().motion.tracks[0].state[0] != 999.0)
  for i in 3..<12 {
    let expected = reframe_fixture_frame(original, i)
    compare_reframed_frames(reframe_fixture_frame(recovered, i), expected)
    compare_reframed_frames(
      reframe_fixture_frame(sequential, i, transform=first.then(next)),
      expected,
    )
    compare_reframed_frames(
      reframe_fixture_frame(combined, i, transform=first.then(next)),
      expected,
    )
  }
}

///|
test "failed session coordinate adaptation leaves the source clock calibration and motion intact" {
  let original = reframe_session(true, false)
  for i in 0..<3 {
    ignore(reframe_fixture_frame(original, i))
  }
  let before = original.checkpoint()
  for
    transform in [
      @moonground.PixelTransform::new(scale_x=1.0e308),
      @moonground.PixelTransform::new(offset_y=1.0e300),
    ] {
    try original.reframed(transform) catch {
      @types.InvalidInput(_) => ()
    } noraise {
      _ => fail("unrepresentable coordinate adaptation was accepted")
    }
  }
  let after = original.checkpoint()
  assert_eq(after.calibration.matrix(), before.calibration.matrix())
  assert_eq(after.motion.last_timestamp_us, before.motion.last_timestamp_us)
  assert_eq(after.motion.next_segment_id, before.motion.next_segment_id)
  assert_eq(after.motion.tracks[0].state, before.motion.tracks[0].state)
  assert_eq(
    after.motion.tracks[0].covariance,
    before.motion.tracks[0].covariance,
  )
  let independent = @moonground.MeasurementSession::from_checkpoint(before)
  compare_reframed_frames(
    reframe_fixture_frame(original, 3),
    reframe_fixture_frame(independent, 3),
  )
}

///|
test "observation adaptation revalidates public identity and covariance fields" {
  let malformed : @moonground.PixelObservation = {
    track_id: 0,
    position: { x: 2.0, y: 3.0, },
    covariance: { xx: 1.0, xy: 0.0, yy: 1.0, },
  }
  try malformed.reframed(@moonground.PixelTransform::new()) catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid identity was accepted by observation adaptation")
  }
  let invalid_covariance : @moonground.PixelObservation = {
    ..malformed,
    track_id: 1,
    covariance: { xx: 1.0, xy: 2.0, yy: 1.0, },
  }
  try invalid_covariance.reframed(@moonground.PixelTransform::new()) catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid covariance was accepted by observation adaptation")
  }
}
