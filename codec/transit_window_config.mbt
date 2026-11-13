///|
fn window_optional_time(value : Int64?) -> Json {
  match value {
    Some(time) => Json(time.to_string())
    None => Json::null()
  }
}

///|
fn window_time_option(
  value : Json,
  label : String,
) -> Int64? raise @types.GroundError {
  match value {
    Null => None
    value => Some(timestamp(value, label))
  }
}

///|
fn window_reason_json(reason : @transit.CancellationReason) -> Json {
  Json(
    match reason {
      @transit.Discontinuity => "discontinuity"
      @transit.Expired => "expired"
      @transit.Reentered => "reentered"
      @transit.Reversed => "reversed"
      @transit.AmbiguousOrder => "ambiguous_order"
    },
  )
}

///|
fn window_reason(
  value : Json,
) -> @transit.CancellationReason raise @types.GroundError {
  match text(value, "cancellation reason") {
    "discontinuity" => @transit.Discontinuity
    "expired" => @transit.Expired
    "reentered" => @transit.Reentered
    "reversed" => @transit.Reversed
    "ambiguous_order" => @transit.AmbiguousOrder
    _ => raise invalid("unknown transit cancellation reason")
  }
}

///|
fn window_counts(
  value : Json,
) -> Array[@transit.TransitCount] raise @types.GroundError {
  array(value, "window upstream counts", 16).map(value => {
    let fields = object(value, "window upstream count")
    allowed_fields(fields, ["section_id", "completed"], "window upstream count")
    @transit.TransitCount::{
      section_id: text(required(fields, "section_id"), "section_id"),
      completed: timestamp(required(fields, "completed"), "completed"),
    }
  })
}

///|
fn window_limits(value : Json) -> Array[Int64] raise @types.GroundError {
  array(value, "duration limits", 16).map(value => {
    timestamp(value, "duration limit")
  })
}

///|
fn window_value(window : @transit.TransitWindow) -> Json {
  Json::object({
    "start_us": Json(window.start_us.to_string()),
    "end_exclusive_us": window_optional_time(window.end_exclusive_us),
    "first_timestamp_us": Json(window.first_timestamp_us.to_string()),
    "last_timestamp_us": Json(window.last_timestamp_us.to_string()),
    "input_frames": Json(window.input_frames.to_string()),
    "sections": Json(
      window.sections.map(section => {
        Json::object({
          "section_id": Json(section.section_id),
          "completed": Json(section.completed.to_string()),
          "duration_limits": Json(
            section.duration_limits.map(limit => {
              Json::object({
                "limit_us": Json(limit.limit_us.to_string()),
                "within": Json(limit.within.to_string()),
                "exceeded": Json(limit.exceeded.to_string()),
                "indeterminate": Json(limit.indeterminate.to_string()),
              })
            }),
          ),
          "cancellations": Json(
            section.cancellations.map(reason => {
              Json::object({
                "reason": window_reason_json(reason.reason),
                "count": Json(reason.count.to_string()),
              })
            }),
          ),
        })
      }),
    ),
  })
}

///|
fn window_restore_value(
  value : Json,
) -> @transit.TransitWindow raise @types.GroundError {
  let fields = object(value, "transit window")
  allowed_fields(
    fields,
    [
      "start_us", "end_exclusive_us", "first_timestamp_us", "last_timestamp_us",
      "input_frames", "sections",
    ],
    "transit window",
  )
  {
    start_us: timestamp(required(fields, "start_us"), "start_us"),
    end_exclusive_us: window_time_option(
      required(fields, "end_exclusive_us"),
      "end_exclusive_us",
    ),
    first_timestamp_us: timestamp(
      required(fields, "first_timestamp_us"),
      "first_timestamp_us",
    ),
    last_timestamp_us: timestamp(
      required(fields, "last_timestamp_us"),
      "last_timestamp_us",
    ),
    input_frames: timestamp(required(fields, "input_frames"), "input_frames"),
    sections: array(required(fields, "sections"), "window sections", 16).map(value => {
      let fields = object(value, "window section")
      allowed_fields(
        fields,
        ["section_id", "completed", "duration_limits", "cancellations"],
        "window section",
      )
      @transit.TransitWindowSection::{
        section_id: text(required(fields, "section_id"), "section_id"),
        completed: timestamp(required(fields, "completed"), "completed"),
        duration_limits: array(
          required(fields, "duration_limits"),
          "window duration limits",
          16,
        ).map(value => {
          let fields = object(value, "window duration limit")
          allowed_fields(
            fields,
            ["limit_us", "within", "exceeded", "indeterminate"],
            "window duration limit",
          )
          @transit.TransitDurationLimitCount::{
            limit_us: timestamp(required(fields, "limit_us"), "limit_us"),
            within: timestamp(required(fields, "within"), "within"),
            exceeded: timestamp(required(fields, "exceeded"), "exceeded"),
            indeterminate: timestamp(
              required(fields, "indeterminate"),
              "indeterminate",
            ),
          }
        }),
        cancellations: array(
          required(fields, "cancellations"),
          "window cancellation counts",
          5,
        ).map(value => {
          let fields = object(value, "window cancellation count")
          allowed_fields(
            fields,
            ["reason", "count"],
            "window cancellation count",
          )
          @transit.TransitCancellationCount::{
            reason: window_reason(required(fields, "reason")),
            count: timestamp(required(fields, "count"), "count"),
          }
        }),
      }
    }),
  }
}

///|
fn window_checkpoint_value(
  saved : @transit.EvidenceTransitWindowCheckpoint,
) -> Json {
  let config : Map[String, Json] = {
    "max_gap_us": Json(saved.config.max_gap_us.to_string()),
    "max_tracks": Json(saved.config.max_tracks),
  }
  if saved.config.max_position_std_m is Some(limit) {
    config["max_position_std_m"] = Json(limit)
  }
  Json::object({
    "format": Json("moonground.evidence-transit-windows"),
    "checkpoint_version": Json("1"),
    "session_id": Json(saved.session_id),
    "gates": Json(
      saved.gates.map(gate => {
        Json::object({
          "gate_id": Json(gate.gate_id),
          "start_m": point_json(gate.start_m),
          "end_m": point_json(gate.end_m),
          "deadband_m": Json(gate.deadband_m),
        })
      }),
    ),
    "sections": transit_sections_json(saved.sections),
    "config": Json::object(config),
    "sigma_multiplier": Json(saved.sigma_multiplier),
    "window_us": Json(saved.window_us.to_string()),
    "origin_us": Json(saved.origin_us.to_string()),
    "duration_limits_us": Json(
      saved.duration_limits_us.map(limit => Json(limit.to_string())),
    ),
    "baseline_timestamp_us": window_optional_time(saved.baseline_timestamp_us),
    "baseline_counts": transit_counts_json(saved.baseline_counts),
    "last_timestamp_us": window_optional_time(saved.last_timestamp_us),
    "counts": transit_counts_json(saved.counts),
    "current_window": match saved.current_window {
      Some(window) => window_value(window)
      None => Json::null()
    },
  })
}

///|
fn window_restore_checkpoint(
  value : Json,
) -> @transit.EvidenceTransitWindowCounter raise @types.GroundError {
  let fields = object(value, "transit windows checkpoint")
  allowed_fields(
    fields,
    [
      "format", "checkpoint_version", "session_id", "gates", "sections", "config",
      "sigma_multiplier", "window_us", "origin_us", "duration_limits_us", "baseline_timestamp_us",
      "baseline_counts", "last_timestamp_us", "counts", "current_window",
    ],
    "transit windows checkpoint",
  )
  if text(required(fields, "format"), "format") !=
    "moonground.evidence-transit-windows" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid("unsupported transit windows checkpoint format or version")
  }
  let config = object(required(fields, "config"), "window gate configuration")
  for gate in array(required(fields, "gates"), "saved window gates", 16) {
    ignore(required(object(gate, "saved window gate"), "deadband_m"))
  }
  allowed_fields(
    config,
    ["max_gap_us", "max_tracks", "max_position_std_m"],
    "window gate configuration",
  )
  let definition = gate_configuration(
    Json::object({
      "session_id": required(fields, "session_id"),
      "gates": required(fields, "gates"),
      "max_gap_us": required(config, "max_gap_us"),
      "max_tracks": required(config, "max_tracks"),
    }),
  ).checkpoint()
  @transit.EvidenceTransitWindowCounter::from_checkpoint({
    version: 1,
    session_id: definition.session_id,
    gates: definition.gates,
    sections: transit_sections(required(fields, "sections")),
    config: @events.GateConfig::new(
      max_gap_us=definition.config.max_gap_us,
      max_tracks=definition.config.max_tracks,
      max_position_std_m?=optional_limit(config, "max_position_std_m"),
    ),
    sigma_multiplier: number(
      required(fields, "sigma_multiplier"),
      "sigma_multiplier",
    ),
    window_us: timestamp(required(fields, "window_us"), "window_us"),
    origin_us: timestamp(required(fields, "origin_us"), "origin_us"),
    duration_limits_us: window_limits(required(fields, "duration_limits_us")),
    baseline_timestamp_us: window_time_option(
      required(fields, "baseline_timestamp_us"),
      "baseline_timestamp_us",
    ),
    baseline_counts: window_counts(required(fields, "baseline_counts")),
    last_timestamp_us: window_time_option(
      required(fields, "last_timestamp_us"),
      "last_timestamp_us",
    ),
    counts: window_counts(required(fields, "counts")),
    current_window: match required(fields, "current_window") {
      Null => None
      value => Some(window_restore_value(value))
    },
  })
}
