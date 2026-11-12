///|
fn health_config(value : Json) -> @health.HealthConfig raise @types.GroundError {
  let fields = object(value, "health limits")
  allowed_fields(
    fields,
    [
      "min_landmarks", "rms_limit_m", "max_error_m", "confirmation_us", "min_observations",
      "max_gap_us", "max_position_std_m",
    ],
    "health limits",
  )
  @health.HealthConfig::new(
    min_landmarks=match fields.get("min_landmarks") {
      Some(value) => positive_int(value, "min_landmarks")
      None => 3
    },
    rms_limit_m=optional_number(fields, "rms_limit_m", 0.1),
    max_error_m=optional_number(fields, "max_error_m", 0.2),
    confirmation_us=match fields.get("confirmation_us") {
      Some(value) => timestamp(value, "confirmation_us")
      None => 300000L
    },
    min_observations=match fields.get("min_observations") {
      Some(value) => positive_int(value, "min_observations")
      None => 3
    },
    max_gap_us=match fields.get("max_gap_us") {
      Some(value) => timestamp(value, "max_gap_us")
      None => 500000L
    },
    max_position_std_m?=optional_limit(fields, "max_position_std_m"),
  )
}

///|
fn health_config_json(config : @health.HealthConfig) -> Json {
  let fields : Map[String, Json] = {
    "min_landmarks": Json(config.min_landmarks),
    "rms_limit_m": Json(config.rms_limit_m),
    "max_error_m": Json(config.max_error_m),
    "confirmation_us": Json(config.confirmation_us.to_string()),
    "min_observations": Json(config.min_observations),
    "max_gap_us": Json(config.max_gap_us.to_string()),
  }
  if config.max_position_std_m is Some(limit) {
    fields["max_position_std_m"] = Json(limit)
  }
  Json::object(fields)
}

///|
/// A separate consumer of fixed reference landmarks, never moving track IDs.
pub struct HealthReplay {
  priv monitor : @health.CalibrationMonitor
  priv monitor_id : String
  priv configuration : Json
}

///|
fn health_configuration(value : Json) -> HealthReplay raise @types.GroundError {
  let fields = object(value, "health configuration")
  allowed_fields(
    fields,
    ["monitor_id", "calibration", "camera", "landmarks", "health"],
    "health configuration",
  )
  let monitor_id = text(required(fields, "monitor_id"), "monitor_id")
  if monitor_id.length() < 1 || monitor_id.length() > 128 {
    raise invalid("monitor_id must contain 1 to 128 UTF-16 code units")
  }
  let (calibration, calibration_value) = calibration_configuration(
    required(fields, "calibration"),
  )
  let camera = optional_camera(fields)
  let landmarks : Array[@health.KnownLandmark] = []
  for value in array(required(fields, "landmarks"), "landmarks", 64) {
    let fields = object(value, "known landmark")
    allowed_fields(fields, ["landmark_id", "ground_m"], "known landmark")
    landmarks.push(
      @health.KnownLandmark::new(
        text(required(fields, "landmark_id"), "landmark_id"),
        point(required(fields, "ground_m"), "ground_m"),
      ),
    )
  }
  let config = health_config(
    match fields.get("health") {
      Some(value) => value
      None => Json::empty_object()
    },
  )
  let monitor = @health.CalibrationMonitor::new(
    calibration,
    landmarks,
    config,
    camera?,
  )
  let effective : Map[String, Json] = {
    "monitor_id": Json(monitor_id),
    "calibration": calibration_value,
    "landmarks": Json(
      landmarks.map(landmark => {
        Json::object({
          "landmark_id": Json(landmark.landmark_id),
          "ground_m": point_json(landmark.ground_m),
        })
      }),
    ),
    "health": health_config_json(config),
  }
  if camera is Some(camera) {
    effective["camera"] = camera_json(camera)
  }
  { monitor, monitor_id, configuration: Json::object(effective), }
}

///|
fn health_evidence_json(evidence : @health.CalibrationEvidence) -> Json {
  Json(
    match evidence {
      @health.CalibrationEvidence::Insufficient => "insufficient"
      @health.CalibrationEvidence::WithinTolerance => "within_tolerance"
      @health.CalibrationEvidence::BeyondTolerance => "beyond_tolerance"
    },
  )
}

///|
fn health_evidence(
  value : Json,
) -> @health.CalibrationEvidence raise @types.GroundError {
  match text(value, "health evidence") {
    "within_tolerance" => @health.CalibrationEvidence::WithinTolerance
    "beyond_tolerance" => @health.CalibrationEvidence::BeyondTolerance
    _ =>
      raise invalid(
        "health streak requires within_tolerance or beyond_tolerance",
      )
  }
}

///|
// A checkpoint carries effective values, rather than relying on the defaults
// of whichever version restores it.
fn validate_health_checkpoint_configuration(
  value : Json,
) -> Unit raise @types.GroundError {
  let fields = object(value, "health checkpoint configuration")
  for name in ["monitor_id", "calibration", "landmarks", "health"] {
    ignore(required(fields, name))
  }
  let limits = object(required(fields, "health"), "health checkpoint limits")
  for
    name in [
      "min_landmarks", "rms_limit_m", "max_error_m", "confirmation_us", "min_observations",
      "max_gap_us",
    ] {
    ignore(required(limits, name))
  }
  let calibration = object(
    required(fields, "calibration"),
    "health checkpoint calibration",
  )
  for name in ["matrix", "roi", "max_meters_per_pixel", "ground_noise_floor_m"] {
    ignore(required(calibration, name))
  }
  if fields.get("camera") is Some(value) {
    let camera = object(value, "health checkpoint camera")
    for
      name in [
        "fx", "fy", "cx", "cy", "k1", "k2", "p1", "p2", "k3", "max_normalized_radius",
      ] {
      ignore(required(camera, name))
    }
  }
}

///|
fn restore_health(value : Json) -> HealthReplay raise @types.GroundError {
  let fields = object(value, "health checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "configuration", "state"],
    "health checkpoint",
  )
  if text(required(fields, "format"), "format") != "moonground.health" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid("unsupported health checkpoint format or version")
  }
  let configuration = required(fields, "configuration")
  validate_health_checkpoint_configuration(configuration)
  let initial = health_configuration(configuration)
  let state = object(required(fields, "state"), "health state")
  allowed_fields(state, ["last_timestamp_us", "streak"], "health state")
  let last_timestamp_us = match required(state, "last_timestamp_us") {
    Null => None
    value => Some(timestamp(value, "last_timestamp_us"))
  }
  let streak : @health.HealthStreak? = match required(state, "streak") {
    Null => None
    value => {
      let fields = object(value, "health streak")
      allowed_fields(
        fields,
        ["evidence", "since_us", "observations"],
        "health streak",
      )
      Some({
        evidence: health_evidence(required(fields, "evidence")),
        since_us: timestamp(required(fields, "since_us"), "since_us"),
        observations: positive_int(
          required(fields, "observations"),
          "observations",
        ),
      })
    }
  }
  let monitor = @health.CalibrationMonitor::from_checkpoint({
    ..initial.monitor.checkpoint(),
    last_timestamp_us,
    streak,
  })
  { ..initial, monitor, }
}

///|
/// Open raw configuration or exactly {"resume": health_checkpoint}.
pub fn HealthReplay::open(
  source : String,
) -> HealthReplay raise @types.GroundError {
  let value = parse_checkpoint_document(source, max_units=8388619)
  let fields = object(value, "health source")
  if fields.get("resume") is Some(saved) {
    allowed_fields(fields, ["resume"], "health resume envelope")
    if saved.stringify().length() > 8388608 {
      raise invalid("health checkpoint exceeds 8388608 UTF-16 code units")
    }
    restore_health(saved)
  } else {
    if source.length() > 1048576 {
      raise invalid("health configuration exceeds 1048576 UTF-16 code units")
    }
    health_configuration(value)
  }
}

///|
/// Complete effective calibration and fixed references with the evidence state.
pub fn HealthReplay::checkpoint_json(
  self : HealthReplay,
) -> String raise @types.GroundError {
  let saved = self.monitor.checkpoint()
  let result = Json::object({
    "format": Json("moonground.health"),
    "checkpoint_version": Json("1"),
    "configuration": self.configuration,
    "state": Json::object({
      "last_timestamp_us": match saved.last_timestamp_us {
        None => Json::null()
        Some(value) => Json(value.to_string())
      },
      "streak": match saved.streak {
        None => Json::null()
        Some(streak) =>
          Json::object({
            "evidence": health_evidence_json(streak.evidence),
            "since_us": Json(streak.since_us.to_string()),
            "observations": Json(streak.observations),
          })
      },
    }),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("health checkpoint exceeds 8388608 UTF-16 code units")
  }
  result
}
