///|
fn gate_configuration(
  value : Json,
) -> @events.GateCounter raise @types.GroundError {
  let fields = object(value, "gate configuration")
  allowed_fields(
    fields,
    ["session_id", "gates", "max_gap_us", "max_tracks", "max_position_std_m"],
    "gate configuration",
  )
  let gates : Array[@events.LineGate] = []
  for value in array(required(fields, "gates"), "gates", 16) {
    let fields = object(value, "line gate")
    allowed_fields(
      fields,
      ["gate_id", "start_m", "end_m", "deadband_m"],
      "line gate",
    )
    gates.push(
      @events.LineGate::new(
        text(required(fields, "gate_id"), "gate_id"),
        point(required(fields, "start_m"), "start_m"),
        point(required(fields, "end_m"), "end_m"),
        deadband_m=optional_number(fields, "deadband_m", 0.05),
      ),
    )
  }
  let gap = match fields.get("max_gap_us") {
    Some(value) => timestamp(value, "max_gap_us")
    None => 500000L
  }
  let capacity = match fields.get("max_tracks") {
    Some(value) => positive_int(value, "max_tracks")
    None => 1000
  }
  @events.GateCounter::new(
    text(required(fields, "session_id"), "session_id"),
    gates,
    @events.GateConfig::new(
      max_gap_us=gap,
      max_tracks=capacity,
      max_position_std_m?=optional_limit(fields, "max_position_std_m"),
    ),
  )
}

///|
fn gate_configuration_json(checkpoint : @events.GateCheckpoint) -> Json {
  gate_definition_json(
    checkpoint.session_id,
    checkpoint.gates,
    checkpoint.config,
  )
}

///|
fn gate_definition_json(
  session_id : String,
  gates : Array[@events.LineGate],
  config : @events.GateConfig,
) -> Json {
  let fields : Map[String, Json] = {
    "session_id": Json(session_id),
    "gates": Json(
      gates.map(gate => {
        Json::object({
          "gate_id": Json(gate.gate_id),
          "start_m": point_json(gate.start_m),
          "end_m": point_json(gate.end_m),
          "deadband_m": Json(gate.deadband_m),
        })
      }),
    ),
    "max_gap_us": Json(config.max_gap_us.to_string()),
    "max_tracks": Json(config.max_tracks),
  }
  if config.max_position_std_m is Some(value) {
    fields["max_position_std_m"] = Json(value)
  }
  Json::object(fields)
}

///|
fn gate_count_json(count : @events.GateCount) -> Json {
  Json::object({
    "gate_id": Json(count.gate_id),
    "negative_to_positive": Json(count.negative_to_positive.to_string()),
    "positive_to_negative": Json(count.positive_to_negative.to_string()),
  })
}

///|
fn gate_checkpoint_value(saved : @events.GateCheckpoint) -> Json {
  Json::object({
    "format": Json("moonground.gates"),
    "checkpoint_version": Json("1"),
    "configuration": gate_configuration_json(saved),
    "state": Json::object({
      "last_timestamp_us": match saved.last_timestamp_us {
        Some(t) => Json(t.to_string())
        None => Json::null()
      },
      "counts": Json(saved.counts.map(gate_count_json)),
      "tracks": Json(
        saved.tracks.map(track => {
          Json::object({
            "track_id": Json(track.track_id),
            "segment_id": Json(track.segment_id),
            "anchors": Json(
              track.anchors.map(anchor => {
                match anchor {
                  None => Json::null()
                  Some(a) =>
                    Json::object({
                      "timestamp_us": Json(a.timestamp_us.to_string()),
                      "point_m": point_json(a.point_m),
                    })
                }
              }),
            ),
          })
        }),
      ),
    }),
  })
}

///|
fn gate_checkpoint_json(
  counter : @events.GateCounter,
) -> String raise @types.GroundError {
  let result = gate_checkpoint_value(counter.checkpoint()).stringify()
  if result.length() > 8388608 {
    raise invalid("gate checkpoint exceeds 8388608 UTF-16 code units")
  }
  result
}

///|
fn restore_gate_checkpoint(
  value : Json,
) -> @events.GateCounter raise @types.GroundError {
  let fields = object(value, "gate checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "configuration", "state"],
    "gate checkpoint",
  )
  if text(required(fields, "format"), "format") != "moonground.gates" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid("unsupported gate checkpoint format or version")
  }
  let initial = gate_configuration(required(fields, "configuration")).checkpoint()
  let state = object(required(fields, "state"), "gate state")
  allowed_fields(state, ["last_timestamp_us", "counts", "tracks"], "gate state")
  let last_timestamp_us = match required(state, "last_timestamp_us") {
    Null => None
    value => Some(timestamp(value, "last_timestamp_us"))
  }
  let counts : Array[@events.GateCount] = []
  for value in array(required(state, "counts"), "gate counts", 16) {
    let fields = object(value, "gate count")
    allowed_fields(
      fields,
      ["gate_id", "negative_to_positive", "positive_to_negative"],
      "gate count",
    )
    counts.push({
      gate_id: text(required(fields, "gate_id"), "gate_id"),
      negative_to_positive: timestamp(
        required(fields, "negative_to_positive"),
        "negative_to_positive",
      ),
      positive_to_negative: timestamp(
        required(fields, "positive_to_negative"),
        "positive_to_negative",
      ),
    })
  }
  let tracks : Array[@events.GateTrackCheckpoint] = []
  for
    value in array(
      required(state, "tracks"),
      "gate tracks",
      initial.config.max_tracks,
    ) {
    let fields = object(value, "gate track")
    allowed_fields(fields, ["track_id", "segment_id", "anchors"], "gate track")
    let anchors : Array[@events.GateAnchor?] = []
    for value in array(required(fields, "anchors"), "gate anchors", 16) {
      anchors.push(
        match value {
          Null => None
          value => {
            let fields = object(value, "gate anchor")
            allowed_fields(fields, ["timestamp_us", "point_m"], "gate anchor")
            Some({
              timestamp_us: timestamp(
                required(fields, "timestamp_us"),
                "timestamp_us",
              ),
              point_m: point(required(fields, "point_m"), "point_m"),
            })
          }
        },
      )
    }
    tracks.push({
      track_id: positive_int(required(fields, "track_id"), "track_id"),
      segment_id: text(required(fields, "segment_id"), "segment_id"),
      anchors,
    })
  }
  @events.GateCounter::from_checkpoint({
    ..initial,
    last_timestamp_us,
    counts,
    tracks,
  })
}

///|
fn gate_source(value : Json) -> @events.GateCounter raise @types.GroundError {
  let fields = object(value, "gate source")
  if fields.get("resume") is Some(saved) {
    allowed_fields(fields, ["resume"], "gate resume envelope")
    if saved.stringify().length() > 8388608 {
      raise invalid("gate checkpoint exceeds 8388608 UTF-16 code units")
    }
    restore_gate_checkpoint(saved)
  } else {
    if value.stringify().length() > 1048576 {
      raise invalid("gate configuration exceeds 1048576 UTF-16 code units")
    }
    gate_configuration(value)
  }
}
