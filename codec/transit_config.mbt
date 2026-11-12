///|
fn crossing_direction_json(direction : @events.CrossingDirection) -> Json {
  Json(
    match direction {
      @events.NegativeToPositive => "negative_to_positive"
      @events.PositiveToNegative => "positive_to_negative"
    },
  )
}

///|
fn crossing_direction(
  value : Json,
) -> @events.CrossingDirection raise @types.GroundError {
  match text(value, "crossing direction") {
    "negative_to_positive" => @events.NegativeToPositive
    "positive_to_negative" => @events.PositiveToNegative
    _ => raise invalid("unknown crossing direction")
  }
}

///|
fn gate_crossing_json(event : @events.GateCrossing) -> Json {
  Json::object({
    "gate_id": Json(event.gate_id),
    "track_id": Json(event.track_id),
    "segment_id": Json(event.segment_id),
    "direction": crossing_direction_json(event.direction),
    "from_timestamp_us": Json(event.from_timestamp_us.to_string()),
    "to_timestamp_us": Json(event.to_timestamp_us.to_string()),
    "from_position_m": point_json(event.from_position_m),
    "to_position_m": point_json(event.to_position_m),
    "position_m": point_json(event.position_m),
    "crossing_fraction": Json(event.crossing_fraction),
  })
}

///|
fn transit_crossing(
  value : Json,
) -> @events.GateCrossing raise @types.GroundError {
  let fields = object(value, "transit entry crossing")
  allowed_fields(
    fields,
    [
      "gate_id", "track_id", "segment_id", "direction", "from_timestamp_us", "to_timestamp_us",
      "from_position_m", "to_position_m", "position_m", "crossing_fraction",
    ],
    "transit entry crossing",
  )
  {
    gate_id: text(required(fields, "gate_id"), "gate_id"),
    track_id: positive_int(required(fields, "track_id"), "track_id"),
    segment_id: text(required(fields, "segment_id"), "segment_id"),
    direction: crossing_direction(required(fields, "direction")),
    from_timestamp_us: timestamp(
      required(fields, "from_timestamp_us"),
      "from_timestamp_us",
    ),
    to_timestamp_us: timestamp(
      required(fields, "to_timestamp_us"),
      "to_timestamp_us",
    ),
    from_position_m: point(
      required(fields, "from_position_m"),
      "from_position_m",
    ),
    to_position_m: point(required(fields, "to_position_m"), "to_position_m"),
    position_m: point(required(fields, "position_m"), "position_m"),
    crossing_fraction: number(
      required(fields, "crossing_fraction"),
      "crossing_fraction",
    ),
  }
}

///|
fn transit_sections(
  value : Json,
) -> Array[@transit.Section] raise @types.GroundError {
  array(value, "sections", 16).map(value => {
    let fields = object(value, "transit section")
    allowed_fields(
      fields,
      [
        "section_id", "entry_gate_id", "entry_direction", "exit_gate_id", "exit_direction",
      ],
      "transit section",
    )
    @transit.Section::new(
      text(required(fields, "section_id"), "section_id"),
      text(required(fields, "entry_gate_id"), "entry_gate_id"),
      crossing_direction(required(fields, "entry_direction")),
      text(required(fields, "exit_gate_id"), "exit_gate_id"),
      crossing_direction(required(fields, "exit_direction")),
    )
  })
}

///|
fn transit_sections_json(sections : Array[@transit.Section]) -> Json {
  Json(
    sections.map(section => {
      Json::object({
        "section_id": Json(section.section_id),
        "entry_gate_id": Json(section.entry_gate_id),
        "entry_direction": crossing_direction_json(section.entry_direction),
        "exit_gate_id": Json(section.exit_gate_id),
        "exit_direction": crossing_direction_json(section.exit_direction),
      })
    }),
  )
}

///|
fn transit_counts_json(counts : Array[@transit.TransitCount]) -> Json {
  Json(
    counts.map(count => {
      Json::object({
        "section_id": Json(count.section_id),
        "completed": Json(count.completed.to_string()),
      })
    }),
  )
}

///|
fn transit_checkpoint_value(saved : @transit.TransitCheckpoint) -> Json {
  Json::object({
    "format": Json("moonground.transit"),
    "checkpoint_version": Json("1"),
    "counting": gate_checkpoint_value(saved.counting),
    "sections": transit_sections_json(saved.sections),
    "max_duration_us": Json(saved.max_duration_us.to_string()),
    "counts": transit_counts_json(saved.counts),
    "pending": Json(
      saved.pending.map(pending => {
        Json::object({
          "section_id": Json(pending.section_id),
          "entry": gate_crossing_json(pending.entry),
        })
      }),
    ),
  })
}

///|
fn restore_transit_checkpoint(
  value : Json,
) -> @transit.TransitCounter raise @types.GroundError {
  let fields = object(value, "transit checkpoint")
  allowed_fields(
    fields,
    [
      "format", "checkpoint_version", "counting", "sections", "max_duration_us",
      "counts", "pending",
    ],
    "transit checkpoint",
  )
  if text(required(fields, "format"), "format") != "moonground.transit" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid("unsupported transit checkpoint format or version")
  }
  let counts = array(required(fields, "counts"), "transit counts", 16).map(value => {
    let fields = object(value, "transit count")
    allowed_fields(fields, ["section_id", "completed"], "transit count")
    @transit.TransitCount::{
      section_id: text(required(fields, "section_id"), "section_id"),
      completed: timestamp(required(fields, "completed"), "completed"),
    }
  })
  let pending = array(required(fields, "pending"), "transit pending", 65536).map(value => {
      let fields = object(value, "transit pending entry")
      allowed_fields(fields, ["section_id", "entry"], "transit pending entry")
      @transit.TransitPending::{
        section_id: text(required(fields, "section_id"), "section_id"),
        entry: transit_crossing(required(fields, "entry")),
      }
    },
  )
  @transit.TransitCounter::from_checkpoint({
    version: 1,
    counting: restore_gate_checkpoint(required(fields, "counting")).checkpoint(),
    sections: transit_sections(required(fields, "sections")),
    max_duration_us: timestamp(
      required(fields, "max_duration_us"),
      "max_duration_us",
    ),
    counts,
    pending,
  })
}

///|
fn transit_source(
  value : Json,
) -> @transit.TransitCounter raise @types.GroundError {
  let fields = object(value, "transit source")
  if fields.contains("resume") {
    allowed_fields(fields, ["resume"], "transit resume source")
    return restore_transit_checkpoint(required(fields, "resume"))
  }
  allowed_fields(
    fields,
    ["counting", "sections", "max_duration_us"],
    "transit source",
  )
  let counting = text(required(fields, "counting"), "counting")
  let duration = match fields.get("max_duration_us") {
    Some(value) => timestamp(value, "max_duration_us")
    None => 300000000L
  }
  @transit.TransitCounter::new(
    gate_source(parse_checkpoint_document(counting, max_units=8388619)),
    transit_sections(required(fields, "sections")),
    max_duration_us=duration,
  )
}
