///|
fn health_report_json(
  monitor_id : String,
  report : @health.HealthReport,
) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("calibration_health"),
    "monitor_id": Json(monitor_id),
    "timestamp_us": Json(report.timestamp_us.to_string()),
    "scope": Json("observed_fixed_landmarks_under_fixed_calibration"),
    "landmarks": Json(
      report.landmarks.map(result => {
        Json::object({
          "landmark_id": Json(result.landmark_id),
          "projected_position_m": match result.projected_position_m {
            Some(value) => point_json(value)
            None => Json::null()
          },
          "projected_covariance": match result.projected_covariance {
            Some(value) => covariance_json(value)
            None => Json::null()
          },
          "residual_m": match result.residual_m {
            Some(value) => point_json(value)
            None => Json::null()
          },
          "error_m": match result.error_m {
            Some(value) => Json(value)
            None => Json::null()
          },
          "position_std_m": match result.position_std_m {
            Some(value) => Json(value)
            None => Json::null()
          },
          "rejection_reason": match result.rejection_reason {
            Some(value) => Json(value)
            None => Json::null()
          },
        })
      }),
    ),
    "usable_count": Json(report.usable_count),
    "rms_error_m": match report.rms_error_m {
      Some(value) => Json(value)
      None => Json::null()
    },
    "max_error_m": match report.max_error_m {
      Some(value) => Json(value)
      None => Json::null()
    },
    "evidence": health_evidence_json(report.evidence),
    "status": Json(
      match report.status {
        @health.HealthStatus::Insufficient => "insufficient"
        @health.HealthStatus::Pending => "pending"
        @health.HealthStatus::Healthy => "healthy"
        @health.HealthStatus::Drift => "drift"
      },
    ),
    "streak_since_us": match report.streak_since_us {
      Some(value) => Json(value.to_string())
      None => Json::null()
    },
    "streak_observations": Json(report.streak_observations),
  })
}

///|
fn HealthReplay::health_process_frame(
  self : HealthReplay,
  source : String,
) -> Json raise @types.GroundError {
  let fields = object(parse_document(source), "health observation frame")
  allowed_fields(
    fields,
    ["timestamp_us", "observations"],
    "health observation frame",
  )
  let observations : Array[@health.LandmarkObservation] = []
  for
    value in array(
      required(fields, "observations"),
      "landmark observations",
      64,
    ) {
    let fields = object(value, "landmark observation")
    allowed_fields(
      fields,
      ["landmark_id", "point", "covariance"],
      "landmark observation",
    )
    observations.push(
      @health.LandmarkObservation::new(
        text(required(fields, "landmark_id"), "landmark_id"),
        point(required(fields, "point"), "point"),
        match fields.get("covariance") {
          Some(value) => covariance(value)
          None => @types.Covariance2::isotropic(2.0)
        },
      ),
    )
  }
  health_report_json(
    self.monitor_id,
    self.monitor.update(
      timestamp(required(fields, "timestamp_us"), "timestamp_us"),
      observations,
    ),
  )
}

///|
/// Recheck a frame of fixed landmark observations. Fatal errors leave its time reusable.
pub fn HealthReplay::process_line(
  self : HealthReplay,
  source : String,
) -> String raise @types.GroundError {
  self.health_process_frame(source).stringify()
}

///|
/// Pure bounded batch. Both embedded documents keep their original JSON tokens.
pub fn health_json(source : String) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid("health request exceeds 16777216 UTF-16 code units")
  }
  let value = @json.parse(
    source,
    max_nesting_depth=32,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error => raise invalid("invalid health request JSON: " + error.to_string())
  }
  let fields = object(value, "health request")
  allowed_fields(fields, ["source", "observations"], "health request")
  let replay = HealthReplay::open(text(required(fields, "source"), "source"))
  let observations = text(required(fields, "observations"), "observations")
  if observations.length() > 8388608 {
    raise invalid("health observations exceed 8388608 UTF-16 code units")
  }
  let lines = if observations.length() == 0 {
    []
  } else {
    observations.split("\n").collect()
  }
  if observations.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5000 {
    raise invalid("health batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut output_length = 0
  for line in lines {
    let frame = replay.health_process_frame(line.to_owned())
    output_length += frame.stringify().length() + 1
    if output_length > 8388608 {
      raise invalid("health output exceeds 8388608 UTF-16 code units")
    }
    frames.push(frame)
  }
  let result = Json::object({
    "frames": Json(frames),
    "checkpoint": parse_checkpoint_document(replay.checkpoint_json()),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("health output exceeds 8388608 UTF-16 code units")
  }
  result
}
