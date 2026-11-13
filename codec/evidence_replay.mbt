///|
/// Independent covariance-evidence counting, with no upstream motion ownership.
pub struct EvidenceGateReplay {
  priv counter : @events.EvidenceGateCounter
  priv max_tracks : Int32
  priv sigma_multiplier : Double
}

///|
pub fn EvidenceGateReplay::open(
  source : String,
) -> EvidenceGateReplay raise @types.GroundError {
  let value = parse_checkpoint_document(source, max_units=8388619)
  let fields = object(value, "gate evidence source")
  if !fields.contains("resume") && source.length() > 1048576 {
    raise invalid(
      "gate evidence configuration exceeds 1048576 UTF-16 code units",
    )
  }
  let counter = evidence_source(value)
  let saved = counter.checkpoint()
  {
    counter,
    max_tracks: saved.config.max_tracks,
    sigma_multiplier: saved.sigma_multiplier,
  }
}

///|
fn gate_evidence_frame_json(
  frame : @events.EvidenceGateFrame,
  sigma_multiplier : Double,
) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("gate_evidence_frame"),
    "counting": gate_frame_json(frame.counting),
    "evidence_scope": Json("normal_band_on_filtered_mean_chord"),
    "sigma_multiplier": Json(sigma_multiplier),
    "evidence": Json(
      frame.evidence.map(item => {
        Json::object({
          "track_id": Json(item.track_id),
          "segment_id": Json(item.segment_id),
          "gate_id": Json(item.gate_id),
          "distance_m": Json(item.distance_m),
          "normal_std_m": Json(item.normal_std_m),
          "lower_m": Json(item.lower_m),
          "upper_m": Json(item.upper_m),
          "side": Json(
            if item.side > 0 {
              "positive"
            } else if item.side < 0 {
              "negative"
            } else {
              "unconfirmed"
            },
          ),
        })
      }),
    ),
  })
}

///|
fn EvidenceGateReplay::evidence_process_frame(
  self : EvidenceGateReplay,
  source : String,
) -> Json raise @types.GroundError {
  gate_evidence_frame_json(
    self.counter.update(gate_measurement(source, self.max_tracks)),
    self.sigma_multiplier,
  )
}

///|
/// Keep empty and rejected frames; every failed frame leaves the counter intact.
pub fn EvidenceGateReplay::process_line(
  self : EvidenceGateReplay,
  source : String,
) -> String raise @types.GroundError {
  self.evidence_process_frame(source).stringify()
}

///|
pub fn EvidenceGateReplay::checkpoint_json(
  self : EvidenceGateReplay,
) -> String raise @types.GroundError {
  let result = evidence_checkpoint_value(self.counter.checkpoint()).stringify()
  if result.length() > 8388608 {
    raise invalid("gate evidence checkpoint exceeds 8388608 UTF-16 code units")
  }
  result
}

///|
/// Pure bounded replay; no handle is reserved and failed batches expose no prefix.
pub fn gate_evidence_json(source : String) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid("gate evidence request exceeds 16777216 UTF-16 code units")
  }
  let value = @json.parse(
    source,
    max_nesting_depth=32,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error =>
      raise invalid("invalid gate evidence request JSON: " + error.to_string())
  }
  let fields = object(value, "gate evidence request")
  allowed_fields(fields, ["source", "measurements"], "gate evidence request")
  let replay = EvidenceGateReplay::open(
    text(required(fields, "source"), "source"),
  )
  let measurements = text(required(fields, "measurements"), "measurements")
  if measurements.length() > 8388608 {
    raise invalid("gate evidence measurements exceed 8388608 UTF-16 code units")
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
    raise invalid("gate evidence batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut output_length = 0
  for line in lines {
    let frame = replay.evidence_process_frame(line.to_owned())
    output_length += frame.stringify().length() + 1
    if output_length > 8388608 {
      raise invalid("gate evidence output exceeds 8388608 UTF-16 code units")
    }
    frames.push(frame)
  }
  let result = Json::object({
    "frames": Json(frames),
    "checkpoint": parse_checkpoint_document(replay.checkpoint_json()),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("gate evidence output exceeds 8388608 UTF-16 code units")
  }
  result
}
