///|
fn gate_nullable_point(
  value : Json,
  label : String,
) -> @types.Point2? raise @types.GroundError {
  match value {
    Null => None
    value => Some(point(value, label))
  }
}

///|
fn gate_nullable_covariance(
  value : Json,
) -> @types.Covariance2? raise @types.GroundError {
  match value {
    Null => None
    value => Some(covariance(value))
  }
}

///|
fn gate_nullable_number(
  value : Json,
  label : String,
  positive~ : Bool = false,
) -> Double? raise @types.GroundError {
  match value {
    Null => None
    value => {
      let value = number(value, label)
      if value < 0.0 || (positive && value == 0.0) {
        raise invalid(label + " has an invalid sign")
      }
      Some(value)
    }
  }
}

///|
fn gate_nonnegative_number(
  value : Json,
  label : String,
) -> Double raise @types.GroundError {
  let value = number(value, label)
  if value < 0.0 {
    raise invalid(label + " must be nonnegative")
  }
  value
}

///|
fn gate_diagnostic_array(
  fields : Map[String, Json],
  name : String,
  count : Int32,
) -> Array[Double]? raise @types.GroundError {
  match fields.get(name) {
    None | Some(Null) => None
    Some(value) => Some(numbers(value, count, name))
  }
}

///|
fn gate_measurement_track(
  value : Json,
) -> @motion.TrackEstimate? raise @types.GroundError {
  let fields = object(value, "measurement track")
  let status = text(required(fields, "status"), "status")
  let track_id = positive_int(required(fields, "track_id"), "track_id")
  if status == "rejected_projection" {
    allowed_fields(
      fields,
      [
        "track_id", "segment_id", "status", "reason", "position_m", "position_covariance",
        "velocity_mps", "velocity_covariance", "position_std_m", "velocity_std_mps",
        "speed_mps",
      ],
      "rejected projection",
    )
    ignore(text(required(fields, "reason"), "reason"))
    for
      field in [
        "segment_id", "position_m", "position_covariance", "velocity_mps", "velocity_covariance",
        "position_std_m", "velocity_std_mps", "speed_mps",
      ] {
      if !(required(fields, field) is Null) {
        raise invalid("rejected_projection requires null " + field)
      }
    }
    return None
  }
  allowed_fields(
    fields,
    [
      "track_id", "segment_id", "status", "position_m", "position_covariance", "velocity_mps",
      "velocity_covariance", "position_std_m", "velocity_std_mps", "speed_mps", "observed_path_length_m",
      "net_displacement_m", "accepted_count", "last_accepted_timestamp_us", "filter_state",
      "filter_covariance",
    ],
    "measurement track",
  )
  let status = match status {
    "initializing" => @motion.Initializing
    "ready" => @motion.Ready
    "uncertain" => @motion.Uncertain
    "rejected_innovation" => @motion.RejectedInnovation
    "numerical_failure" => @motion.NumericalFailure
    _ => raise invalid("unknown measurement status")
  }
  let accepted = status is @motion.Initializing ||
    status is @motion.Ready ||
    status is @motion.Uncertain
  let observable = status is @motion.Ready || status is @motion.Uncertain
  let position = gate_nullable_point(
    required(fields, "position_m"),
    "position_m",
  )
  let position_covariance = gate_nullable_covariance(
    required(fields, "position_covariance"),
  )
  let position_std_m = gate_nullable_number(
    required(fields, "position_std_m"),
    "position_std_m",
    positive=true,
  )
  let velocity = gate_nullable_point(
    required(fields, "velocity_mps"),
    "velocity_mps",
  )
  let velocity_covariance = gate_nullable_covariance(
    required(fields, "velocity_covariance"),
  )
  let velocity_std_mps = gate_nullable_number(
    required(fields, "velocity_std_mps"),
    "velocity_std_mps",
    positive=true,
  )
  let speed_mps = gate_nullable_number(
    required(fields, "speed_mps"),
    "speed_mps",
  )
  if (position is Some(_)) != accepted ||
    (position_covariance is Some(_)) != accepted ||
    (position_std_m is Some(_)) != accepted ||
    (velocity is Some(_)) != observable ||
    (velocity_covariance is Some(_)) != observable ||
    (velocity_std_mps is Some(_)) != observable ||
    (speed_mps is Some(_)) != (status is @motion.Ready) {
    raise invalid("measurement availability contradicts its status")
  }
  let filtered_state = gate_diagnostic_array(fields, "filter_state", 4)
  let filtered_covariance = gate_diagnostic_array(
    fields, "filter_covariance", 16,
  )
  if fields.contains("filter_state") != fields.contains("filter_covariance") ||
    (
      fields.contains("filter_state") &&
      (
        (filtered_state is Some(_)) != accepted ||
        (filtered_covariance is Some(_)) != accepted
      )
    ) {
    raise invalid("inconsistent measurement diagnostics")
  }
  Some({
    track_id,
    segment_id: text(required(fields, "segment_id"), "segment_id"),
    status,
    position,
    position_covariance,
    velocity,
    velocity_covariance,
    position_std_m,
    velocity_std_mps,
    speed_mps,
    observed_path_length_m: gate_nonnegative_number(
      required(fields, "observed_path_length_m"),
      "observed_path_length_m",
    ),
    net_displacement_m: gate_nonnegative_number(
      required(fields, "net_displacement_m"),
      "net_displacement_m",
    ),
    accepted_count: positive_int(
      required(fields, "accepted_count"),
      "accepted_count",
    ),
    last_accepted_timestamp_us: timestamp(
      required(fields, "last_accepted_timestamp_us"),
      "last_accepted_timestamp_us",
    ),
    filtered_state,
    filtered_covariance,
  })
}

///|
fn gate_measurement(
  source : String,
  limit : Int32,
) -> @motion.FrameResult raise @types.GroundError {
  let fields = object(parse_document(source), "measurement frame")
  allowed_fields(
    fields,
    [
      "schema_version", "session_id", "timestamp_us", "tracks", "closed_segment_ids",
      "uncertainty_scope",
    ],
    "measurement frame",
  )
  if text(required(fields, "schema_version"), "schema_version") != "0.2.0" ||
    text(required(fields, "uncertainty_scope"), "uncertainty_scope") !=
    "conditional_on_fixed_calibration_camera_and_anchor" {
    raise invalid("unsupported measurement schema or uncertainty scope")
  }
  let tracks : Array[@motion.TrackEstimate] = []
  let identities : Map[Int32, Bool] = Map([])
  for value in array(required(fields, "tracks"), "measurement tracks", limit) {
    let fields = object(value, "measurement track")
    let id = positive_int(required(fields, "track_id"), "track_id")
    if identities.contains(id) {
      raise invalid("duplicate measurement track identity")
    }
    identities[id] = true
    if gate_measurement_track(value) is Some(track) {
      tracks.push(track)
    }
  }
  let closed_segment_ids : Array[String] = []
  for
    value in array(
      required(fields, "closed_segment_ids"),
      "closed_segment_ids",
      limit,
    ) {
    closed_segment_ids.push(text(value, "closed_segment_id"))
  }
  {
    session_id: text(required(fields, "session_id"), "session_id"),
    timestamp_us: timestamp(required(fields, "timestamp_us"), "timestamp_us"),
    tracks,
    closed_segment_ids,
  }
}
