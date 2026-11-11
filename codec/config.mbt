///|
fn calibration(
  value : Json,
) -> @calibration.GroundCalibration raise @types.GroundError {
  let fields = object(value, "calibration")
  allowed_fields(
    fields,
    ["matrix", "roi", "max_meters_per_pixel", "ground_noise_floor_m"],
    "calibration",
  )
  let matrix = numbers(required(fields, "matrix"), 9, "matrix")
  let roi : Array[@types.Point2] = []
  for value in array(required(fields, "roi"), "roi", 64) {
    roi.push(point(value, "roi point"))
  }
  @calibration.GroundCalibration::from_homography(
    matrix,
    roi,
    max_meters_per_pixel=optional_number(fields, "max_meters_per_pixel", 0.5),
    ground_noise_floor_m=optional_number(fields, "ground_noise_floor_m", 0.001),
  )
}

///|
fn motion_config(value : Json) -> @motion.MotionConfig raise @types.GroundError {
  let fields = object(value, "motion")
  allowed_fields(
    fields,
    [
      "max_gap_us", "min_observations", "min_span_us", "q", "initial_velocity_std",
      "gate", "max_tracks", "max_position_std_m", "max_velocity_std_mps",
    ],
    "motion",
  )
  let max_gap_us = match fields.get("max_gap_us") {
    Some(value) => timestamp(value, "max_gap_us")
    None => 500000L
  }
  let min_span_us = match fields.get("min_span_us") {
    Some(value) => timestamp(value, "min_span_us")
    None => 300000L
  }
  let min_observations = match fields.get("min_observations") {
    Some(value) => positive_int(value, "min_observations")
    None => 3
  }
  let max_tracks = match fields.get("max_tracks") {
    Some(value) => positive_int(value, "max_tracks")
    None => 1000
  }
  let max_position_std_m = optional_limit(fields, "max_position_std_m")
  let max_velocity_std_mps = optional_limit(fields, "max_velocity_std_mps")
  @motion.MotionConfig::new(
    max_gap_us~,
    min_span_us~,
    min_observations~,
    max_tracks~,
    q=optional_number(fields, "q", 1.0),
    initial_velocity_std=optional_number(fields, "initial_velocity_std", 5.0),
    gate=optional_number(fields, "gate", 9.21034),
    max_position_std_m?,
    max_velocity_std_mps?,
  )
}

///|
/// Replay the same strict wire format in a native command or the JavaScript bridge.
pub struct ReplaySession {
  pixel : @moonground.MeasurementSession?
  ground : @motion.MotionEstimator?
  diagnostics : Bool
  max_tracks : Int32
}

///|
/// Parse one immutable session configuration. No frame is consumed by this call.
pub fn ReplaySession::new(
  source : String,
) -> ReplaySession raise @types.GroundError {
  let fields = object(parse_document(source), "configuration")
  allowed_fields(
    fields,
    ["session_id", "mode", "diagnostics", "calibration", "motion", "camera"],
    "configuration",
  )
  let session_id = text(required(fields, "session_id"), "session_id")
  let mode = match fields.get("mode") {
    Some(value) => text(value, "mode")
    None => "pixel"
  }
  let diagnostics = match fields.get("diagnostics") {
    Some(True) => true
    Some(False) => false
    None => false
    _ => raise invalid("diagnostics must be boolean")
  }
  let config = motion_config(
    match fields.get("motion") {
      Some(value) => value
      None => Json::empty_object()
    },
  )
  let camera = optional_camera(fields)
  match mode {
    "pixel" =>
      {
        pixel: Some(
          @moonground.MeasurementSession::new(
            session_id,
            calibration(required(fields, "calibration")),
            config,
            camera?,
          ),
        ),
        ground: None,
        diagnostics,
        max_tracks: config.max_tracks(),
      }
    "ground" => {
      if fields.contains("calibration") || fields.contains("camera") {
        raise invalid("ground mode does not accept pixel calibration or camera")
      }
      {
        pixel: None,
        ground: Some(@motion.MotionEstimator::new(session_id, config)),
        diagnostics,
        max_tracks: config.max_tracks(),
      }
    }
    _ => raise invalid("mode must be pixel or ground")
  }
}
