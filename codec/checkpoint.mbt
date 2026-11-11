///|
fn parse_checkpoint_document(
  source : String,
  max_units~ : Int32 = 8388608,
) -> Json raise @types.GroundError {
  if source.length() > max_units {
    raise invalid("checkpoint exceeds \{max_units} UTF-16 code units")
  }
  @json.parse(
    source,
    max_nesting_depth=32,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error => raise invalid("invalid checkpoint JSON: " + error.to_string())
  }
}

///|
fn track_checkpoint_json(track : @motion.TrackCheckpoint) -> Json {
  Json::object({
    "track_id": Json(track.track_id),
    "segment_id": Json(track.segment_id.to_string()),
    "first_timestamp_us": Json(track.first_timestamp_us.to_string()),
    "last_timestamp_us": Json(track.last_timestamp_us.to_string()),
    "accepted_count": Json(track.accepted_count),
    "state": Json(track.state),
    "covariance": Json(track.covariance),
    "first_filtered": point_json(track.first_filtered),
    "last_filtered": point_json(track.last_filtered),
    "observed_path_length_m": Json(track.observed_path_length_m),
  })
}

///|
fn motion_checkpoint_json(checkpoint : @motion.MotionCheckpoint) -> Json {
  Json::object({
    "last_timestamp_us": match checkpoint.last_timestamp_us {
      Some(value) => Json(value.to_string())
      None => Json::null()
    },
    "next_segment_id": Json(checkpoint.next_segment_id.to_string()),
    "tracks": Json(checkpoint.tracks.map(track_checkpoint_json)),
  })
}

///|
/// Export complete effective configuration and accepted state. Checkpoints
/// have an independent version and never change the ordinary frame schema.
pub fn ReplaySession::checkpoint_json(
  self : ReplaySession,
) -> String raise @types.GroundError {
  let count = match (self.pixel, self.ground) {
    (Some(session), None) => session.active_track_count()
    (None, Some(estimator)) => estimator.active_track_count()
    _ => raise invalid("invalid replay session")
  }
  if count > 10000 {
    raise invalid("checkpoint exceeds 10000 active tracks")
  }
  let motion = match (self.pixel, self.ground) {
    (Some(session), None) => session.checkpoint().motion
    (None, Some(estimator)) => estimator.checkpoint()
    _ => raise invalid("invalid replay session")
  }
  let result = Json::object({
    "format": Json("moonground.session"),
    "checkpoint_version": Json("1"),
    "configuration": self.configuration,
    "motion": motion_checkpoint_json(motion),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("checkpoint exceeds 8388608 UTF-16 code units")
  }
  result
}

///|
fn parse_track_checkpoint(
  value : Json,
) -> @motion.TrackCheckpoint raise @types.GroundError {
  let fields = object(value, "checkpoint track")
  allowed_fields(
    fields,
    [
      "track_id", "segment_id", "first_timestamp_us", "last_timestamp_us", "accepted_count",
      "state", "covariance", "first_filtered", "last_filtered", "observed_path_length_m",
    ],
    "checkpoint track",
  )
  {
    track_id: positive_int(required(fields, "track_id"), "track_id"),
    segment_id: timestamp(required(fields, "segment_id"), "segment_id"),
    first_timestamp_us: timestamp(
      required(fields, "first_timestamp_us"),
      "first_timestamp_us",
    ),
    last_timestamp_us: timestamp(
      required(fields, "last_timestamp_us"),
      "last_timestamp_us",
    ),
    accepted_count: positive_int(
      required(fields, "accepted_count"),
      "accepted_count",
    ),
    state: numbers(required(fields, "state"), 4, "state"),
    covariance: numbers(required(fields, "covariance"), 16, "covariance"),
    first_filtered: point(required(fields, "first_filtered"), "first_filtered"),
    last_filtered: point(required(fields, "last_filtered"), "last_filtered"),
    observed_path_length_m: number(
      required(fields, "observed_path_length_m"),
      "observed_path_length_m",
    ),
  }
}

///|
// A checkpoint must carry every effective value, rather than silently applying
// today's defaults to a partial historical configuration.
fn validate_checkpoint_configuration(
  value : Json,
) -> Unit raise @types.GroundError {
  let fields = object(value, "checkpoint configuration")
  for name in ["session_id", "mode", "diagnostics", "motion"] {
    ignore(required(fields, name))
  }
  let motion = object(
    required(fields, "motion"),
    "checkpoint motion configuration",
  )
  for
    name in [
      "max_gap_us", "min_observations", "min_span_us", "q", "initial_velocity_std",
      "gate", "max_tracks",
    ] {
    ignore(required(motion, name))
  }
  if text(required(fields, "mode"), "mode") == "pixel" {
    let calibration = object(
      required(fields, "calibration"),
      "checkpoint calibration",
    )
    for
      name in ["matrix", "roi", "max_meters_per_pixel", "ground_noise_floor_m"] {
      ignore(required(calibration, name))
    }
  }
  if fields.get("camera") is Some(value) {
    let camera = object(value, "checkpoint camera")
    for
      name in [
        "fx", "fy", "cx", "cy", "k1", "k2", "p1", "p2", "k3", "max_normalized_radius",
      ] {
      ignore(required(camera, name))
    }
  }
}

///|
fn restore_checkpoint(value : Json) -> ReplaySession raise @types.GroundError {
  let fields = object(value, "checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "configuration", "motion"],
    "checkpoint",
  )
  if text(required(fields, "format"), "format") != "moonground.session" {
    raise invalid("unsupported checkpoint format")
  }
  if text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid("unsupported checkpoint version")
  }
  let configuration = required(fields, "configuration")
  validate_checkpoint_configuration(configuration)
  let initial = replay_configuration(configuration)
  let effective = object(initial.configuration, "configuration")
  let state = object(required(fields, "motion"), "checkpoint motion")
  allowed_fields(
    state,
    ["last_timestamp_us", "next_segment_id", "tracks"],
    "checkpoint motion",
  )
  let last_timestamp_us = match required(state, "last_timestamp_us") {
    Null => None
    value => Some(timestamp(value, "last_timestamp_us"))
  }
  let tracks = array(required(state, "tracks"), "checkpoint tracks", 10000).map(
    parse_track_checkpoint,
  )
  let motion : @motion.MotionCheckpoint = {
    version: 1,
    session_id: text(required(effective, "session_id"), "session_id"),
    config: motion_config(required(effective, "motion")),
    last_timestamp_us,
    next_segment_id: timestamp(
      required(state, "next_segment_id"),
      "next_segment_id",
    ),
    tracks,
  }
  match (initial.pixel, initial.ground) {
    (Some(session), None) => {
      let checkpoint = session.checkpoint()
      {
        pixel: Some(
          @moonground.MeasurementSession::from_checkpoint({
            ..checkpoint,
            motion,
          }),
        ),
        ground: None,
        diagnostics: initial.diagnostics,
        max_tracks: initial.max_tracks,
        configuration: initial.configuration,
      }
    }
    (None, Some(_)) =>
      {
        pixel: None,
        ground: Some(@motion.MotionEstimator::from_checkpoint(motion)),
        diagnostics: initial.diagnostics,
        max_tracks: initial.max_tracks,
        configuration: initial.configuration,
      }
    _ => raise invalid("invalid replay session")
  }
}

///|
/// Restore only the embedded configuration, without overrides or mutation of
/// an existing session. All state is validated before the new session escapes.
pub fn ReplaySession::from_checkpoint_json(
  source : String,
) -> ReplaySession raise @types.GroundError {
  restore_checkpoint(parse_checkpoint_document(source))
}

///|
/// Open an ordinary configuration or an exact {"resume": checkpoint} envelope.
/// Ordinary configurations retain their one-Mi-code-unit input limit.
pub fn ReplaySession::open(
  source : String,
) -> ReplaySession raise @types.GroundError {
  // The minimal {"resume":...} envelope adds eleven code units. Reserving
  // these permits every maximum-size raw checkpoint while keeping its actual
  // embedded source bounded by eight Mi code units.
  let value = parse_checkpoint_document(source, max_units=8388619)
  let fields = object(value, "session input")
  if fields.get("resume") is Some(checkpoint) {
    allowed_fields(fields, ["resume"], "resume envelope")
    restore_checkpoint(checkpoint)
  } else {
    if source.length() > 1048576 {
      raise invalid("JSON text exceeds 1048576 UTF-16 code units")
    }
    replay_configuration(value)
  }
}
