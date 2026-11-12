///|
fn same_point(a : @types.Point2, b : @types.Point2) -> Bool {
  a.x == b.x && a.y == b.y
}

///|
// Match the estimator's scaled largest-direction standard deviation, including
// its operation order at an exact quality threshold. Input covariance was
// already validated by MotionEstimator::from_checkpoint.
fn position_deviation(track : @motion.TrackCheckpoint) -> Double {
  let covariance = track.covariance
  let scale = covariance[0].max(covariance[5])
  let xx = covariance[0] / scale
  let yy = covariance[5] / scale
  let xy = covariance[1] / scale
  let dx = (xx - yy) / 2.0
  let radial_scale = dx.abs().max(xy.abs())
  let radius = if radial_scale == 0.0 {
    0.0
  } else {
    let nx = dx / radial_scale
    let ny = xy / radial_scale
    radial_scale * (nx * nx + ny * ny).sqrt()
  }
  let eigenvalue = (xx + yy) / 2.0 + radius
  scale.sqrt() * eigenvalue.sqrt()
}

///|
fn validate_pair(
  motion : @motion.MotionCheckpoint,
  counting : @events.GateCheckpoint,
) -> Unit raise @types.GroundError {
  if motion.session_id != counting.session_id ||
    motion.last_timestamp_us != counting.last_timestamp_us {
    raise @types.InvalidInput(
      "analysis checkpoint session or watermark differs",
    )
  }
  let expected : Map[Int32, @motion.TrackCheckpoint] = Map([])
  if motion.last_timestamp_us is Some(timestamp) {
    for track in motion.tracks {
      if track.last_timestamp_us != timestamp {
        continue
      }
      if counting.config.max_position_std_m is Some(limit) &&
        position_deviation(track) > limit {
        continue
      }
      expected[track.track_id] = track
    }
    if expected.length() != counting.tracks.length() {
      raise @types.InvalidInput(
        "analysis checkpoint accepted gate tracks differ",
      )
    }
    for track in counting.tracks {
      guard expected.get(track.track_id) is Some(accepted) else {
        raise @types.InvalidInput(
          "analysis checkpoint gate track is not currently accepted",
        )
      }
      if track.segment_id != accepted.segment_id.to_string() {
        raise @types.InvalidInput("analysis checkpoint gate segment differs")
      }
      for index, gate in counting.gates {
        let current_side = gate.side(accepted.last_filtered)
        match track.anchors[index] {
          None =>
            if current_side != 0 {
              raise @types.InvalidInput(
                "analysis checkpoint stable point lacks its current gate anchor",
              )
            }
          Some(anchor) => {
            if anchor.timestamp_us < accepted.first_timestamp_us ||
              anchor.timestamp_us > accepted.last_timestamp_us {
              raise @types.InvalidInput(
                "analysis checkpoint gate anchor predates its motion segment",
              )
            }
            if anchor.timestamp_us == timestamp {
              if !same_point(anchor.point_m, accepted.last_filtered) {
                raise @types.InvalidInput(
                  "analysis checkpoint current gate anchor differs from filtered position",
                )
              }
            } else if current_side != 0 {
              raise @types.InvalidInput(
                "analysis checkpoint stable point has an outdated gate anchor",
              )
            }
          }
        }
      }
    }
  }
}

///|
/// Restore detached engines only after each checkpoint and their shared
/// watermark, accepted identities, quality and latest anchors validate.
pub fn AnalysisSession::from_checkpoint(
  checkpoint : AnalysisCheckpoint,
) -> AnalysisSession raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput("unsupported analysis checkpoint version")
  }
  let counting = @events.GateCounter::from_checkpoint(checkpoint.counting)
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
  validate_pair(motion, counting.checkpoint())
  { measurement, counting, }
}
