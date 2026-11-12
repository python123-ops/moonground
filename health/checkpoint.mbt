///|
pub fn CalibrationMonitor::checkpoint(
  self : CalibrationMonitor,
) -> HealthCheckpoint {
  {
    version: 1,
    calibration: self.calibration,
    camera: self.camera,
    landmarks: self.landmarks.copy(),
    config: self.config,
    last_timestamp_us: self.last_timestamp,
    streak: self.streak,
  }
}

///|
/// Restore a detached monitor after validating its complete evidence state.
/// Restoration does not count a sample or advance time.
pub fn CalibrationMonitor::from_checkpoint(
  checkpoint : HealthCheckpoint,
) -> CalibrationMonitor raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput("unsupported landmark health checkpoint version")
  }
  let source = checkpoint.config
  let config = HealthConfig::new(
    min_landmarks=source.min_landmarks,
    rms_limit_m=source.rms_limit_m,
    max_error_m=source.max_error_m,
    confirmation_us=source.confirmation_us,
    min_observations=source.min_observations,
    max_gap_us=source.max_gap_us,
    max_position_std_m?=source.max_position_std_m,
  )
  let restored = CalibrationMonitor::new(
    checkpoint.calibration,
    checkpoint.landmarks,
    config,
    camera?=checkpoint.camera,
  )
  match checkpoint.last_timestamp_us {
    None =>
      if checkpoint.streak is Some(_) {
        raise @types.InvalidInput(
          "unstarted landmark checkpoint contains evidence",
        )
      }
    Some(timestamp) => {
      if timestamp < 0L {
        raise @types.InvalidInput(
          "landmark checkpoint timestamp must be nonnegative",
        )
      }
      if checkpoint.streak is Some(streak) {
        if streak.evidence is Insufficient ||
          streak.since_us < 0L ||
          streak.since_us > timestamp ||
          streak.observations < 1 ||
          streak.observations > config.min_observations ||
          Int64::from_int(streak.observations - 1) > timestamp - streak.since_us ||
          (
            streak.observations == 1 &&
            config.min_observations > 1 &&
            streak.since_us != timestamp
          ) {
          raise @types.InvalidInput(
            "inconsistent landmark checkpoint evidence streak",
          )
        }
        let span = timestamp - streak.since_us
        if config.max_gap_us == 1L && (span != 0L || streak.observations != 1) {
          raise @types.InvalidInput(
            "landmark checkpoint cannot bridge a one-microsecond gap limit",
          )
        }
        if streak.observations > 1 &&
          streak.observations < config.min_observations {
          let intervals = Int64::from_int(streak.observations - 1)
          let maximum_gap = config.max_gap_us - 1L
          let quotient = span / intervals
          if quotient > maximum_gap ||
            (quotient == maximum_gap && span % intervals != 0L) {
            raise @types.InvalidInput(
              "landmark checkpoint evidence span exceeds its sample continuity",
            )
          }
        }
      }
    }
  }
  restored.last_timestamp = checkpoint.last_timestamp_us
  restored.streak = checkpoint.streak
  restored
}

///|
pub fn CalibrationMonitor::fork(
  self : CalibrationMonitor,
) -> CalibrationMonitor {
  {
    calibration: self.calibration,
    camera: self.camera,
    landmarks: self.landmarks.copy(),
    known: self.known.copy(),
    config: self.config,
    last_timestamp: self.last_timestamp,
    streak: self.streak,
  }
}

///|
/// Re-express the same physical calibration in new pixel coordinates. Metric
/// references, sampled evidence and time remain unchanged; future landmark
/// observations must use the same transform.
pub fn CalibrationMonitor::reframed(
  self : CalibrationMonitor,
  transform : @types.PixelTransform,
) -> CalibrationMonitor raise @types.GroundError {
  {
    calibration: self.calibration.reframed(transform),
    camera: self.camera.map(camera => camera.reframed(transform)),
    landmarks: self.landmarks.copy(),
    known: self.known.copy(),
    config: self.config,
    last_timestamp: self.last_timestamp,
    streak: self.streak,
  }
}
