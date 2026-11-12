///|
test "interrupt ends pixel paths and anchors without consuming a new segment identity" {
  let session = @analysis.AnalysisSession::from_pixel(
    pixel_session(),
    counter(),
  )
  ignore(session.update_pixel(0L, [pixel(0.0, -1.0)]))
  ignore(session.update_pixel(100000L, [pixel(0.0, 1.0)]))
  let branch = session.fork()
  let count = session.checkpoint().counting.counts[0].negative_to_positive
  assert_eq(count, 1L)
  let closed = session.interrupt(200000L)
  assert_eq(closed.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(closed.measurement.motion.tracks.length(), 0)
  assert_eq(closed.counting.crossings.length(), 0)
  assert_eq(closed.counting.counts[0].negative_to_positive, count)
  let checkpoint = session.checkpoint()
  assert_eq(motion_checkpoint(checkpoint).tracks.length(), 0)
  assert_eq(checkpoint.counting.tracks.length(), 0)
  assert_eq(motion_checkpoint(checkpoint).next_segment_id, 2L)
  let before = @debug.to_string(checkpoint)
  invalid(() => ignore(session.interrupt(200000L)))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let next = session.update_pixel(300000L, [pixel(0.0, -1.0)])
  assert_eq(next.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(next.measurement.motion.tracks[0].accepted_count, 1)
  assert_eq(branch.checkpoint().counting.tracks.length(), 1)
}

///|
test "interrupt supports metric streams and reports all closed segments deterministically" {
  let session = fresh_ground()
  ignore(
    session.update_ground(0L, [ground(0.0, -1.0, id=2), ground(1.0, -1.0, id=1)]),
  )
  let closed = session.interrupt(1L)
  assert_eq(closed.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(closed.measurement.projection_failures.length(), 0)
  assert_eq(motion_checkpoint(session.checkpoint()).next_segment_id, 3L)
  assert_eq(session.interrupt(2L).measurement.motion.closed_segment_ids, [])
}

///|
test "interrupt retains atomicity when an independent gate capacity is too small" {
  let session = fresh_ground(max_tracks=2, counter_tracks=1)
  ignore(session.update_ground(0L, [ground(0.0, -1.0)]))
  ignore(session.update_ground(1L, [ground(1.0, -1.0, id=2)]))
  let before = @debug.to_string(session.checkpoint())
  invalid(() => ignore(session.interrupt(2L)))
  assert_eq(@debug.to_string(session.checkpoint()), before)
  ignore(session.update_ground(2L, [], removed=[1]))
  assert_eq(session.interrupt(3L).measurement.motion.closed_segment_ids, ["2"])
}
