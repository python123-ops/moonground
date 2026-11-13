///|
fn evidence_configuration(
  value : Json,
) -> @events.EvidenceGateCounter raise @types.GroundError {
  let fields = object(value, "gate evidence configuration")
  allowed_fields(
    fields,
    ["counting", "sigma_multiplier"],
    "gate evidence configuration",
  )
  let raw = text(required(fields, "counting"), "counting")
  // A legacy checkpoint cannot supply the covariance of an old anchor. Only a
  // fresh gate definition is accepted here; restoration uses the new format.
  let initial = gate_configuration(parse_document(raw)).checkpoint()
  @events.EvidenceGateCounter::new(
    initial.session_id,
    initial.gates,
    initial.config,
    sigma_multiplier=optional_number(fields, "sigma_multiplier", 2.0),
  )
}

///|
fn evidence_checkpoint_value(saved : @events.EvidenceGateCheckpoint) -> Json {
  Json::object({
    "format": Json("moonground.gate-evidence"),
    "checkpoint_version": Json("1"),
    "configuration": Json::object({
      "counting": gate_definition_json(
        saved.session_id,
        saved.gates,
        saved.config,
      ),
      "sigma_multiplier": Json(saved.sigma_multiplier),
    }),
    "state": Json::object({
      "last_timestamp_us": match saved.last_timestamp_us {
        Some(time) => Json(time.to_string())
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
                  Some(anchor) =>
                    Json::object({
                      "timestamp_us": Json(anchor.timestamp_us.to_string()),
                      "point_m": point_json(anchor.point_m),
                      "covariance": covariance_json(anchor.covariance),
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
fn restore_evidence_checkpoint(
  value : Json,
) -> @events.EvidenceGateCounter raise @types.GroundError {
  let fields = object(value, "gate evidence checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "configuration", "state"],
    "gate evidence checkpoint",
  )
  if text(required(fields, "format"), "format") != "moonground.gate-evidence" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid("unsupported gate evidence checkpoint format or version")
  }
  let configuration = object(
    required(fields, "configuration"),
    "gate evidence configuration",
  )
  allowed_fields(
    configuration,
    ["counting", "sigma_multiplier"],
    "gate evidence configuration",
  )
  let counting = required(configuration, "counting")
  let effective = object(counting, "saved gate configuration")
  // Fresh sources may use defaults. A checkpoint records the effective policy
  // explicitly, so restoring an incomplete policy must not silently reset it.
  ignore(required(effective, "max_gap_us"))
  ignore(required(effective, "max_tracks"))
  for value in array(required(effective, "gates"), "gates", 16) {
    ignore(required(object(value, "saved line gate"), "deadband_m"))
  }
  let initial = gate_configuration(counting).checkpoint()
  let state = object(required(fields, "state"), "gate evidence state")
  allowed_fields(
    state,
    ["last_timestamp_us", "counts", "tracks"],
    "gate evidence state",
  )
  let last_timestamp_us = match required(state, "last_timestamp_us") {
    Null => None
    value => Some(timestamp(value, "last_timestamp_us"))
  }
  let counts : Array[@events.GateCount] = []
  for value in array(required(state, "counts"), "evidence counts", 16) {
    let fields = object(value, "evidence count")
    allowed_fields(
      fields,
      ["gate_id", "negative_to_positive", "positive_to_negative"],
      "evidence count",
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
  let tracks : Array[@events.EvidenceGateTrackCheckpoint] = []
  for
    value in array(
      required(state, "tracks"),
      "evidence tracks",
      initial.config.max_tracks,
    ) {
    let fields = object(value, "evidence track")
    allowed_fields(
      fields,
      ["track_id", "segment_id", "anchors"],
      "evidence track",
    )
    let anchors : Array[@events.EvidenceGateAnchor?] = []
    for value in array(required(fields, "anchors"), "evidence anchors", 16) {
      anchors.push(
        match value {
          Null => None
          value => {
            let fields = object(value, "evidence anchor")
            allowed_fields(
              fields,
              ["timestamp_us", "point_m", "covariance"],
              "evidence anchor",
            )
            Some({
              timestamp_us: timestamp(
                required(fields, "timestamp_us"),
                "timestamp_us",
              ),
              point_m: point(required(fields, "point_m"), "point_m"),
              covariance: covariance(required(fields, "covariance")),
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
  @events.EvidenceGateCounter::from_checkpoint({
    version: 1,
    session_id: initial.session_id,
    gates: initial.gates,
    config: initial.config,
    sigma_multiplier: number(
      required(configuration, "sigma_multiplier"),
      "sigma_multiplier",
    ),
    last_timestamp_us,
    counts,
    tracks,
  })
}

///|
fn evidence_source(
  value : Json,
) -> @events.EvidenceGateCounter raise @types.GroundError {
  let fields = object(value, "gate evidence source")
  if fields.contains("resume") {
    allowed_fields(fields, ["resume"], "gate evidence resume")
    let saved = required(fields, "resume")
    if saved.stringify().length() > 8388608 {
      raise invalid(
        "gate evidence checkpoint exceeds 8388608 UTF-16 code units",
      )
    }
    restore_evidence_checkpoint(saved)
  } else {
    evidence_configuration(value)
  }
}
