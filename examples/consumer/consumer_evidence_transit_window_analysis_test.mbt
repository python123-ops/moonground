///|
fn consumer_window_analysis(
  name : String,
  origin_us~ : Int64 = 0L,
) -> @analysis.EvidenceTransitWindowSession raise @moonground.GroundError {
  @analysis.EvidenceTransitWindowSession::new(
    @analysis.EvidenceTransitSession::from_ground(
      @motion.MotionEstimator::new(
        name,
        @moonground.MotionConfig::new(q=1000000.0, gate=1.0e12, max_tracks=10),
      ),
      consumer_transit_analysis_counter(name),
    ),
    window_us=1000000L,
    duration_limits_us=[0L, 200000L, 9223372036854775807L],
    origin_us~,
  )
}

///|
test "packaged raw window origin rejection discards a successful upstream candidate" {
  let session = consumer_window_analysis(
    "consumer-window-origin",
    origin_us=100L,
  )
  let before = @debug.to_string(session.checkpoint())
  let objects = [
    consumer_transit_analysis_observation(1, -1.0),
    consumer_transit_analysis_observation(9, -1.0),
  ]
  try session.update_ground(99L, objects) catch {
    _ => ()
  } noraise {
    _ => fail("window origin must discard the already computed measurement")
  }
  assert_eq(@debug.to_string(session.checkpoint()), before)
  let corrected = session.update_ground(100L, objects)
  assert_eq(corrected.analysis.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(corrected.analysis.measurement.motion.tracks[1].segment_id, "2")
  assert_eq(corrected.windows.current_window.input_frames, 1L)
  assert_true(corrected.windows.closed_window is None)
  assert_eq(
    @debug.to_string(
      @analysis.EvidenceTransitWindowSession::from_checkpoint(
        session.checkpoint(),
      ).checkpoint(),
    ),
    @debug.to_string(session.checkpoint()),
  )
}

///|
test "packaged raw window upstream overflow preserves every stage and permits same time correction" {
  let source = consumer_window_analysis("consumer-window-overflow")
  ignore(
    source.update_ground(0L, [consumer_transit_analysis_observation(7, -1.0)]),
  )
  let saved = source.checkpoint()
  let exhausted = @analysis.EvidenceTransitWindowSession::from_checkpoint({
    ..saved,
    analysis: {
      ..saved.analysis,
      transit: {
        ..saved.analysis.transit,
        counting: {
          ..saved.analysis.transit.counting,
          counts: [
            {
              ..saved.analysis.transit.counting.counts[0],
              negative_to_positive: 9223372036854775807L,
            },
            saved.analysis.transit.counting.counts[1],
          ],
        },
      },
    },
  })
  let before = @debug.to_string(exhausted.checkpoint())
  try
    exhausted.update_ground(100000L, [
      consumer_transit_analysis_observation(7, 1.0),
      consumer_transit_analysis_observation(9, -1.0),
    ])
  catch {
    _ => ()
  } noraise {
    _ => fail("upstream gate exhaustion must preserve window samples and IDs")
  }
  assert_eq(@debug.to_string(exhausted.checkpoint()), before)
  let corrected = exhausted.update_ground(100000L, [
    consumer_transit_analysis_observation(7, -2.0),
    consumer_transit_analysis_observation(9, -1.0),
  ])
  assert_eq(corrected.analysis.measurement.motion.tracks[0].accepted_count, 2)
  assert_eq(corrected.analysis.measurement.motion.tracks[1].segment_id, "2")
  assert_eq(corrected.windows.current_window.input_frames, 2L)
  assert_eq(corrected.windows.current_window.sections[0].completed, 0L)
  assert_eq(
    @debug.to_string(source.checkpoint().windows),
    @debug.to_string(saved.windows),
  )
}

///|
test "packaged Brown raw windows preserve pending reframes and bind cancellation budgets" {
  let (guarded, _, left, middle, right) = consumer_guarded_transit(
    @health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  let session = @analysis.EvidenceTransitWindowSession::new(
    @analysis.EvidenceTransitSession::from_checkpoint(
      guarded.checkpoint().analysis,
    ),
    window_us=1000000L,
    duration_limits_us=[0L, 200000L, 9223372036854775807L],
  )
  ignore(session.update_pixel(0L, [left, { ..left, track_id: 9, }]))
  assert_eq(
    session.update_pixel(100000L, [middle]).analysis.transit.pending_count,
    1,
  )
  let saved = session.checkpoint()
  let started = @analysis.EvidenceTransitWindowSession::new(
    @analysis.EvidenceTransitSession::from_checkpoint(saved.analysis),
    window_us=1000000L,
    duration_limits_us=[0L, 200000L, 9223372036854775807L],
  )
  assert_true(started.checkpoint().windows.current_window is None)
  let first_statistics = started.update_pixel(200000L, [right])
  assert_eq(first_statistics.windows.current_window.input_frames, 1L)
  assert_eq(first_statistics.windows.current_window.sections[0].completed, 1L)
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=1.25,
    offset_x=-15.0,
    offset_y=8.0,
  )
  let adapted = session.reframed(transform)
  assert_eq(
    @debug.to_string(adapted.checkpoint().windows),
    @debug.to_string(saved.windows),
  )
  assert_eq(
    @debug.to_string(adapted.checkpoint().analysis.transit),
    @debug.to_string(saved.analysis.transit),
  )
  let restored = @analysis.EvidenceTransitWindowSession::from_checkpoint(
    adapted.checkpoint(),
  )
  let completed = adapted.update_pixel(200000L, [right.reframed(transform)])
  assert_eq(
    @debug.to_string(completed),
    @debug.to_string(
      restored.update_pixel(200000L, [right.reframed(transform)]),
    ),
  )
  assert_eq(completed.windows.current_window.sections[0].completed, 1L)
  let blocked = session.interrupt(150000L)
  assert_eq(blocked.analysis.measurement.motion.closed_segment_ids, ["1", "2"])
  assert_eq(
    blocked.windows.current_window.sections[0].cancellations[0].count,
    1L,
  )
  assert_eq(blocked.windows.current_window.input_frames, 3L)
  let checkpoint = session.checkpoint()
  let current = checkpoint.windows.current_window.unwrap()
  let sections = current.sections.copy()
  let reasons = sections[0].cancellations.copy()
  reasons[0] = { ..reasons[0], count: 2L, }
  sections[0] = { ..sections[0], cancellations: reasons, }
  let impossible = {
    ..checkpoint,
    windows: {
      ..checkpoint.windows,
      current_window: Some({ ..current, sections, }),
    },
  }
  ignore(
    @transit.EvidenceTransitWindowCounter::from_checkpoint(impossible.windows),
  )
  try
    @analysis.EvidenceTransitWindowSession::from_checkpoint(impossible)
  catch {
    _ => ()
  } noraise {
    _ => fail("window cancellations cannot consume one confirmed entry twice")
  }
}
