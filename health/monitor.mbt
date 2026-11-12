///|
pub fn CalibrationMonitor::new(
  calibration : @calibration.GroundCalibration,
  landmarks : Array[KnownLandmark],
  config : HealthConfig,
  camera? : @camera.CameraModel,
) -> CalibrationMonitor raise @types.GroundError {
  if landmarks.length() < 1 ||
    landmarks.length() > 64 ||
    config.min_landmarks > landmarks.length() {
    raise @types.InvalidInput(
      "landmark health monitor requires 1 to 64 references and enough landmarks",
    )
  }
  let known : Map[String, @types.Point2] = Map([])
  for landmark in landmarks {
    ignore(KnownLandmark::new(landmark.landmark_id, landmark.ground_m))
    if known.contains(landmark.landmark_id) {
      raise @types.InvalidInput("duplicate configured landmark identity")
    }
    known[landmark.landmark_id] = landmark.ground_m
  }
  {
    calibration,
    camera,
    landmarks: landmarks.copy(),
    known,
    config,
    last_timestamp: None,
    streak: None,
  }
}

///|
fn checked(value : Double) -> Double raise @types.GroundError {
  if !@types.is_finite(value) {
    raise @types.InvalidInput("landmark residual is not representable")
  }
  value
}

///|
fn norm2(x : Double, y : Double) -> Double {
  let scale = x.abs().max(y.abs())
  if scale == 0.0 {
    return 0.0
  }
  let nx = x / scale
  let ny = y / scale
  scale * (nx * nx + ny * ny).sqrt()
}

///|
fn position_deviation(covariance : @types.Covariance2) -> Double {
  let scale = covariance.xx.max(covariance.yy)
  let xx = covariance.xx / scale
  let yy = covariance.yy / scale
  let xy = covariance.xy / scale
  let eigenvalue = (xx + yy) / 2.0 + norm2((xx - yy) / 2.0, xy)
  scale.sqrt() * eigenvalue.sqrt()
}

///|
fn rejected(id : String, reason : String) -> LandmarkResult {
  {
    landmark_id: id,
    projected_position_m: None,
    projected_covariance: None,
    residual_m: None,
    error_m: None,
    position_std_m: None,
    rejection_reason: Some(reason),
  }
}

///|
fn CalibrationMonitor::evaluate(
  self : CalibrationMonitor,
  landmark : KnownLandmark,
  observation : LandmarkObservation,
) -> LandmarkResult {
  let projected = try {
    match self.camera {
      Some(camera) =>
        camera.project(
          self.calibration,
          observation.pixel,
          observation.covariance,
        )
      None =>
        self.calibration.project(observation.pixel, observation.covariance)
    }
  } catch {
    error =>
      return rejected(landmark.landmark_id, "projection: " + error.message())
  }
  let point = projected.position()
  let covariance = projected.covariance()
  let deviation = position_deviation(covariance)
  let result : LandmarkResult = {
    landmark_id: landmark.landmark_id,
    projected_position_m: Some(point),
    projected_covariance: Some(covariance),
    residual_m: None,
    error_m: None,
    position_std_m: Some(deviation),
    rejection_reason: None,
  }
  if self.config.max_position_std_m is Some(limit) && deviation > limit {
    return { ..result, rejection_reason: Some("position_uncertainty"), }
  }
  let residual = @types.Point2::new(
    point.x - landmark.ground_m.x,
    point.y - landmark.ground_m.y,
  ) catch {
    error =>
      return {
        ..result,
        rejection_reason: Some("numerical: " + error.message()),
      }
  }
  let error = checked(norm2(residual.x, residual.y)) catch {
    error =>
      return {
        ..result,
        rejection_reason: Some("numerical: " + error.message()),
      }
  }
  { ..result, residual_m: Some(residual), error_m: Some(error), }
}

///|
fn current_status(
  streak : HealthStreak?,
  timestamp : Int64,
  config : HealthConfig,
) -> HealthStatus {
  match streak {
    None => Insufficient
    Some(streak) => {
      if streak.observations < config.min_observations ||
        timestamp - streak.since_us < config.confirmation_us {
        return Pending
      }
      match streak.evidence {
        WithinTolerance => Healthy
        BeyondTolerance => Drift
        Insufficient => Insufficient
      }
    }
  }
}

///|
/// Commit a complete structurally valid landmark frame. Projection, quality
/// and unrepresentable residual failures reject individual landmarks; identity,
/// covariance and time errors leave the previous watermark reusable.
pub fn CalibrationMonitor::update(
  self : CalibrationMonitor,
  timestamp_us : Int64,
  observations : Array[LandmarkObservation],
) -> HealthReport raise @types.GroundError {
  if timestamp_us < 0L ||
    (self.last_timestamp is Some(previous) && timestamp_us <= previous) {
    raise @types.InvalidInput(
      "landmark frame timestamps must be nonnegative and strictly increase",
    )
  }
  if observations.length() > self.landmarks.length() {
    raise @types.InvalidInput(
      "landmark frame exceeds configured reference count",
    )
  }
  let seen : Map[String, LandmarkObservation] = Map([])
  for observation in observations {
    ignore(
      LandmarkObservation::new(
        observation.landmark_id,
        observation.pixel,
        observation.covariance,
      ),
    )
    if !self.known.contains(observation.landmark_id) {
      raise @types.InvalidInput("unknown landmark identity")
    }
    if seen.contains(observation.landmark_id) {
      raise @types.InvalidInput("duplicate landmark observation identity")
    }
    seen[observation.landmark_id] = observation
  }
  let landmarks = self.landmarks.map(landmark => {
    match seen.get(landmark.landmark_id) {
      Some(observation) => self.evaluate(landmark, observation)
      None => rejected(landmark.landmark_id, "missing")
    }
  })
  let errors : Array[Double] = []
  let mut maximum = 0.0
  for result in landmarks {
    if result.error_m is Some(error) {
      errors.push(error)
      maximum = maximum.max(error)
    }
  }
  let (rms_error_m, max_error_m) = if errors.length() == 0 {
    (None, None)
  } else {
    let mut sum = 0.0
    if maximum > 0.0 {
      for error in errors {
        let normalized = error / maximum
        sum += normalized * normalized
      }
    }
    (Some(maximum * (sum / errors.length().to_double()).sqrt()), Some(maximum))
  }
  let evidence : CalibrationEvidence = if errors.length() <
    self.config.min_landmarks {
    Insufficient
  } else {
    match (rms_error_m, max_error_m) {
      (Some(rms), Some(maximum)) if rms <= self.config.rms_limit_m &&
        maximum <= self.config.max_error_m => WithinTolerance
      _ => BeyondTolerance
    }
  }
  let streak = if evidence is Insufficient {
    None
  } else {
    let continuous = self.last_timestamp is Some(previous) &&
      timestamp_us - previous < self.config.max_gap_us
    match self.streak {
      Some(previous) if continuous && previous.evidence == evidence =>
        Some({
          ..previous,
          observations: if previous.observations < self.config.min_observations {
            previous.observations + 1
          } else {
            previous.observations
          },
        })
      _ => Some({ evidence, since_us: timestamp_us, observations: 1, })
    }
  }
  let status = current_status(streak, timestamp_us, self.config)
  self.streak = streak
  self.last_timestamp = Some(timestamp_us)
  {
    timestamp_us,
    landmarks,
    usable_count: errors.length(),
    rms_error_m,
    max_error_m,
    evidence,
    status,
    streak_since_us: streak.map(streak => streak.since_us),
    streak_observations: match streak {
      Some(streak) => streak.observations
      None => 0
    },
  }
}
