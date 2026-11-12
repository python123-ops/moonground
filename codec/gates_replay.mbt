///|
/// Independent, bounded event consumer for schema-0.2 ground measurement frames.
/// Its checkpoint is separate from the measurement session checkpoint.
pub struct GateReplay {
  priv counter : @events.GateCounter
  priv max_tracks : Int32
}

///|
fn new_gate_replay(counter : @events.GateCounter) -> GateReplay {
  { counter, max_tracks: counter.checkpoint().config.max_tracks, }
}

///|
/// Open a gate configuration or {"resume": gate_checkpoint}, preserving tokens.
pub fn GateReplay::open(source : String) -> GateReplay raise @types.GroundError {
  let value = parse_checkpoint_document(source, max_units=8388619)
  let fields = object(value, "gate source")
  if !fields.contains("resume") && source.length() > 1048576 {
    raise invalid("gate configuration exceeds 1048576 UTF-16 code units")
  }
  new_gate_replay(gate_source(value))
}

///|
fn gate_frame_json(frame : @events.GateFrame) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("gate_events"),
    "session_id": Json(frame.session_id),
    "timestamp_us": Json(frame.timestamp_us.to_string()),
    "crossings": Json(
      frame.crossings.map(event => {
        Json::object({
          "gate_id": Json(event.gate_id),
          "track_id": Json(event.track_id),
          "segment_id": Json(event.segment_id),
          "direction": Json(
            match event.direction {
              @events.NegativeToPositive => "negative_to_positive"
              @events.PositiveToNegative => "positive_to_negative"
            },
          ),
          "from_timestamp_us": Json(event.from_timestamp_us.to_string()),
          "to_timestamp_us": Json(event.to_timestamp_us.to_string()),
          "from_position_m": point_json(event.from_position_m),
          "to_position_m": point_json(event.to_position_m),
          "position_m": point_json(event.position_m),
          "crossing_fraction": Json(event.crossing_fraction),
        })
      }),
    ),
    "counts": Json(frame.counts.map(gate_count_json)),
    "event_scope": Json("filtered_ground_positions"),
  })
}

///|
fn GateReplay::gate_process_frame(
  self : GateReplay,
  source : String,
) -> Json raise @types.GroundError {
  gate_frame_json(
    self.counter.update(gate_measurement(source, self.max_tracks)),
  )
}

///|
/// Count only contiguous accepted filtered positions. A failed frame is reusable.
pub fn GateReplay::process_line(
  self : GateReplay,
  source : String,
) -> String raise @types.GroundError {
  self.gate_process_frame(source).stringify()
}

///|
pub fn GateReplay::checkpoint_json(
  self : GateReplay,
) -> String raise @types.GroundError {
  gate_checkpoint_json(self.counter)
}

///|
/// Pure bounded batch, with raw configuration/resume and measurement JSON text.
/// It allocates no persistent browser handle and returns no partial result.
pub fn gates_json(source : String) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid("gate request exceeds 16777216 UTF-16 code units")
  }
  let value = @json.parse(
    source,
    max_nesting_depth=32,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error => raise invalid("invalid gate request JSON: " + error.to_string())
  }
  let fields = object(value, "gate request")
  allowed_fields(fields, ["source", "measurements"], "gate request")
  let replay = GateReplay::open(text(required(fields, "source"), "source"))
  let measurements = text(required(fields, "measurements"), "measurements")
  if measurements.length() > 8388608 {
    raise invalid("gate measurements exceed 8388608 UTF-16 code units")
  }
  let lines = if measurements.length() == 0 {
    []
  } else {
    measurements.split("\n").collect()
  }
  if measurements.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5000 {
    raise invalid("gate batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut output_length = 0
  for line in lines {
    let frame = replay.gate_process_frame(line.to_owned())
    output_length += frame.stringify().length() + 1
    if output_length > 8388608 {
      raise invalid("gate output exceeds 8388608 UTF-16 code units")
    }
    frames.push(frame)
  }
  let result = Json::object({
    "frames": Json(frames),
    "checkpoint": parse_checkpoint_document(replay.checkpoint_json()),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("gate output exceeds 8388608 UTF-16 code units")
  }
  result
}
