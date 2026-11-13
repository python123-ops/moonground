///|
fn instant_gap_config(
  gap~ : Int64 = 100000L,
) -> @health.HealthConfig raise @types.GroundError {
  @health.HealthConfig::new(
    confirmation_us=0L,
    min_observations=1,
    max_gap_us=gap,
  )
}

///|
test "mean guard preserves a reachable instant Healthy motion segment across shorter health gaps" {
  let session = @guarded.GuardedSession::new(
    analysis(),
    monitor(config=instant_gap_config()),
  )
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0), pixel(2, -1.0)]))
  let frame = session.update(100000L, landmarks(), [pixel(1, 1.0)])
  assert_eq(frame.decision, @guarded.Allowed)
  assert_eq(frame.health.streak_since_us, Some(100000L))
  assert_eq(frame.analysis.measurement.motion.tracks[0].accepted_count, 2)
  assert_eq(frame.analysis.measurement.motion.closed_segment_ids, [])
  let restored = @guarded.GuardedSession::from_checkpoint(session.checkpoint())
  assert_eq(
    @debug.to_string(restored.update(150000L, landmarks(), [pixel(1, 2.0)])),
    @debug.to_string(session.update(150000L, landmarks(), [pixel(1, 2.0)])),
  )
}

///|
test "evidence guard preserves instant Healthy continuation and original covariance across a shorter health gap" {
  let session = evidence_fresh(config=instant_gap_config())
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  let gap = session.update(100000L, landmarks(), [pixel(1, 1.0)])
  assert_eq(gap.decision, @guarded.Allowed)
  assert_eq(gap.analysis.counting.counting.counts[0].negative_to_positive, 1L)
  let restored = @guarded.EvidenceGuardedSession::from_checkpoint(
    session.checkpoint(),
  )
  assert_eq(
    @debug.to_string(restored.update(200000L, landmarks(), [pixel(1, -1.0)])),
    @debug.to_string(session.update(200000L, landmarks(), [pixel(1, -1.0)])),
  )
  ignore(
    @guarded.EvidenceGuardedSession::from_checkpoint(restored.checkpoint()),
  )
}

///|
test "guarded transit preserves a real pending entry across instant health restart and completes without a false barrier" {
  let session = guarded_transit(config=instant_gap_config())
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  let entered = session.update(100000L, landmarks(), [pixel(1, 1.0)])
  assert_eq(entered.decision, @guarded.Allowed)
  assert_eq(entered.health.streak_since_us, Some(100000L))
  assert_eq(entered.analysis.transit.pending_count, 1)
  let restored = @guarded.EvidenceGuardedTransitSession::from_checkpoint(
    session.checkpoint(),
  )
  let completed = restored.update(200000L, landmarks(), [pixel(1, 3.0)])
  assert_eq(completed.analysis.transit.passages.length(), 1)
  assert_eq(completed.analysis.measurement.motion.tracks[0].segment_id, "1")
  assert_eq(completed.analysis.measurement.motion.closed_segment_ids, [])
  ignore(
    @guarded.EvidenceGuardedTransitSession::from_checkpoint(
      restored.checkpoint(),
    ),
  )
}

///|
test "instant restart gap boundary allows saved first time exactly one gap earlier but rejects a point inside it" {
  let mean = @guarded.GuardedSession::new(
    analysis(),
    monitor(config=instant_gap_config()),
  )
  ignore(mean.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(mean.update(100000L, landmarks(), [pixel(1, -2.0)]))
  let mean_cp = mean.checkpoint()
  let mean_pixel = pixel_checkpoint(mean_cp)
  ignore(@guarded.GuardedSession::from_checkpoint(mean_cp))
  invalid(() => {
    ignore(
      @guarded.GuardedSession::from_checkpoint({
        ..mean_cp,
        analysis: {
          ..mean_cp.analysis,
          measurement: Pixel({
            ..mean_pixel,
            motion: {
              ..mean_pixel.motion,
              tracks: [
                { ..mean_pixel.motion.tracks[0], first_timestamp_us: 1L, },
              ],
            },
          }),
        },
      }),
    )
  })
  let evidence = evidence_fresh(config=instant_gap_config())
  ignore(evidence.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(evidence.update(100000L, landmarks(), [pixel(1, -2.0)]))
  let evidence_cp = evidence.checkpoint()
  let evidence_pixel = evidence_pixel_checkpoint(evidence_cp)
  ignore(@guarded.EvidenceGuardedSession::from_checkpoint(evidence_cp))
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedSession::from_checkpoint({
        ..evidence_cp,
        analysis: {
          ..evidence_cp.analysis,
          measurement: Pixel({
            ..evidence_pixel,
            motion: {
              ..evidence_pixel.motion,
              tracks: [
                { ..evidence_pixel.motion.tracks[0], first_timestamp_us: 1L, },
              ],
            },
          }),
        },
      }),
    )
  })
  let transit = guarded_transit(config=instant_gap_config())
  ignore(transit.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(transit.update(100000L, landmarks(), [pixel(1, -2.0)]))
  let transit_cp = transit.checkpoint()
  let transit_pixel = guarded_transit_pixel(transit_cp)
  ignore(@guarded.EvidenceGuardedTransitSession::from_checkpoint(transit_cp))
  invalid(() => {
    ignore(
      @guarded.EvidenceGuardedTransitSession::from_checkpoint({
        ..transit_cp,
        analysis: {
          ..transit_cp.analysis,
          measurement: Pixel({
            ..transit_pixel,
            motion: {
              ..transit_pixel.motion,
              tracks: [
                { ..transit_pixel.motion.tracks[0], first_timestamp_us: 1L, },
              ],
            },
          }),
        },
      }),
    )
  })
}

///|
test "same or longer health gap keeps the original strict healthy segment chronology" {
  for gap in [500000L, 600000L] {
    let session = @guarded.GuardedSession::new(
      analysis(),
      monitor(config=instant_gap_config(gap~)),
    )
    ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
    ignore(session.update(100000L, landmarks(), [pixel(1, -2.0)]))
    let saved = session.checkpoint()
    invalid(() => {
      ignore(
        @guarded.GuardedSession::from_checkpoint({
          ..saved,
          health: {
            ..saved.health,
            streak: Some({ ..saved.health.streak.unwrap(), since_us: 100000L, }),
          },
        }),
      )
    })
  }
}

///|
test "historical mean and covariance anchors cannot occupy the instant health restart gap" {
  let mean = @guarded.GuardedSession::new(
    analysis(),
    monitor(config=instant_gap_config(gap=150000L)),
  )
  ignore(mean.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(mean.update(100000L, landmarks(), [pixel(1, -1.0)]))
  ignore(mean.update(200000L, landmarks(), [pixel(1, 0.0)]))
  let saved = mean.checkpoint()
  assert_eq(
    saved.analysis.counting.tracks[0].anchors[0].unwrap().timestamp_us,
    100000L,
  )
  let bad_mean = {
    ..saved,
    health: {
      ..saved.health,
      streak: Some({ ..saved.health.streak.unwrap(), since_us: 200000L, }),
    },
  }
  ignore(@analysis.AnalysisSession::from_checkpoint(bad_mean.analysis))
  ignore(@health.CalibrationMonitor::from_checkpoint(bad_mean.health))
  invalid(() => ignore(@guarded.GuardedSession::from_checkpoint(bad_mean)))
  let evidence = evidence_fresh(config=instant_gap_config(gap=150000L))
  ignore(evidence.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(evidence.update(100000L, landmarks(), [pixel(1, -1.0)]))
  ignore(evidence.update(200000L, landmarks(), [pixel(1, 0.0)]))
  let saved = evidence.checkpoint()
  assert_eq(
    saved.analysis.counting.tracks[0].anchors[0].unwrap().timestamp_us,
    100000L,
  )
  let bad_evidence = {
    ..saved,
    health: {
      ..saved.health,
      streak: Some({ ..saved.health.streak.unwrap(), since_us: 200000L, }),
    },
  }
  ignore(
    @analysis.EvidenceAnalysisSession::from_checkpoint(bad_evidence.analysis),
  )
  ignore(@health.CalibrationMonitor::from_checkpoint(bad_evidence.health))
  invalid(() => {
    ignore(@guarded.EvidenceGuardedSession::from_checkpoint(bad_evidence))
  })
}

///|
test "historical pending confirmation cannot occupy the instant health restart gap even after current anchors refresh" {
  let session = guarded_transit(config=instant_gap_config(gap=150000L))
  ignore(session.update(0L, landmarks(), [pixel(1, -1.0)]))
  ignore(session.update(100000L, landmarks(), [pixel(1, 1.0)]))
  ignore(session.update(200000L, landmarks(), [pixel(1, 1.5)]))
  let saved = session.checkpoint()
  assert_eq(saved.analysis.transit.pending[0].entry.to_timestamp_us, 100000L)
  let bad = {
    ..saved,
    health: {
      ..saved.health,
      streak: Some({ ..saved.health.streak.unwrap(), since_us: 200000L, }),
    },
  }
  ignore(@analysis.EvidenceTransitSession::from_checkpoint(bad.analysis))
  ignore(@health.CalibrationMonitor::from_checkpoint(bad.health))
  invalid(() => {
    ignore(@guarded.EvidenceGuardedTransitSession::from_checkpoint(bad))
  })
}
