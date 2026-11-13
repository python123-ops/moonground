///|
fn same_evidence_covariance(
  a : @types.Covariance2,
  b : @types.Covariance2,
) -> Bool {
  a.xx == b.xx && a.xy == b.xy && a.yy == b.yy
}

///|
fn validate_evidence_pair(
  motion : @motion.MotionCheckpoint,
  counting : @events.EvidenceGateCheckpoint,
) -> Unit raise @types.GroundError {
  if motion.session_id != counting.session_id ||
    motion.last_timestamp_us != counting.last_timestamp_us {
    raise @types.InvalidInput(
      "evidence analysis checkpoint session or watermark differs",
    )
  }
  let expected : Map[Int32, @motion.TrackCheckpoint] = Map([])
  if motion.last_timestamp_us is Some(timestamp) {
    for track in motion.tracks {
      if track.last_timestamp_us != timestamp {
        continue
      }
      // Preserve the old scalar quality policy and its exact boundary/order.
      // A quality skip must not call the stricter normal-evidence numeric core.
      if counting.config.max_position_std_m is Some(limit) &&
        position_deviation(track) > limit {
        continue
      }
      expected[track.track_id] = track
    }
    if expected.length() != counting.tracks.length() {
      raise @types.InvalidInput(
        "evidence analysis checkpoint accepted gate tracks differ",
      )
    }
    for track in counting.tracks {
      guard expected.get(track.track_id) is Some(accepted) else {
        raise @types.InvalidInput(
          "evidence analysis gate track is not currently accepted",
        )
      }
      if track.segment_id != accepted.segment_id.to_string() {
        raise @types.InvalidInput("evidence analysis gate segment differs")
      }
      // Motion emits the upper position block verbatim, including P01. Do not
      // symmetrize a tolerated round-off difference with P10 on restoration.
      let covariance : @types.Covariance2 = {
        xx: accepted.covariance[0],
        xy: accepted.covariance[1],
        yy: accepted.covariance[5],
      }
      for index, gate in counting.gates {
        let current_side = gate.evidence_side(
          accepted.last_filtered,
          covariance,
          sigma_multiplier=counting.sigma_multiplier,
        )
        match track.anchors[index] {
          None =>
            if current_side != 0 {
              raise @types.InvalidInput(
                "evidence analysis confirmed point lacks its current anchor",
              )
            }
          Some(anchor) => {
            if anchor.timestamp_us < accepted.first_timestamp_us ||
              anchor.timestamp_us > accepted.last_timestamp_us {
              raise @types.InvalidInput(
                "evidence analysis anchor lies outside its motion segment",
              )
            }
            if anchor.timestamp_us == accepted.first_timestamp_us &&
              !same_point(anchor.point_m, accepted.first_filtered) {
              raise @types.InvalidInput(
                "evidence analysis first anchor differs from first filtered position",
              )
            }
            if anchor.timestamp_us == timestamp {
              if current_side == 0 ||
                !same_point(anchor.point_m, accepted.last_filtered) ||
                !same_evidence_covariance(anchor.covariance, covariance) {
                raise @types.InvalidInput(
                  "evidence analysis current anchor differs from current evidence",
                )
              }
            } else if current_side != 0 {
              raise @types.InvalidInput(
                "evidence analysis confirmed point has an outdated anchor",
              )
            }
          }
        }
      }
    }
  }
}

///|
/// Restore each complete engine, then check the shared current state. Historical
/// anchor covariances can be checked for supported stable evidence, not proven
/// to originate in an unauthenticated observation history.
pub fn EvidenceAnalysisSession::from_checkpoint(
  checkpoint : EvidenceAnalysisCheckpoint,
) -> EvidenceAnalysisSession raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput(
      "unsupported evidence analysis checkpoint version",
    )
  }
  let counting = @events.EvidenceGateCounter::from_checkpoint(
    checkpoint.counting,
  )
  let (measurement, motion) = match checkpoint.measurement {
    Pixel(snapshot) => {
      let restored = @moonground.MeasurementSession::from_checkpoint(snapshot)
      (MeasurementEngine::Pixel(restored), restored.checkpoint().motion)
    }
    Ground(snapshot) => {
      let restored = @motion.MotionEstimator::from_checkpoint(snapshot)
      (MeasurementEngine::Ground(restored), restored.checkpoint())
    }
  }
  validate_evidence_pair(motion, counting.checkpoint())
  { measurement, counting, }
}
