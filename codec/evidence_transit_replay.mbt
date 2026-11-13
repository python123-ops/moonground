///|
/// A downstream consumer of original schema-0.2 measurement frames. Its state
/// includes its own gates and pending entries, but never restores upstream motion.
pub struct EvidenceTransitReplay {
  priv counter : @transit.EvidenceTransitCounter
  priv max_tracks : Int32
  priv sigma_multiplier : Double
}

///|
pub fn EvidenceTransitReplay::open(
  source : String,
) -> EvidenceTransitReplay raise @types.GroundError {
  let value = parse_checkpoint_document(source, max_units=8388619)
  let fields = object(value, "evidence transit source")
  if !fields.contains("resume") && source.length() > 1048576 {
    raise invalid(
      "evidence transit configuration exceeds 1048576 UTF-16 code units",
    )
  }
  let counter = evidence_transit_source(value)
  let saved = counter.checkpoint()
  {
    counter,
    max_tracks: saved.counting.config.max_tracks,
    sigma_multiplier: saved.counting.sigma_multiplier,
  }
}

///|
fn evidence_transit_frame_json(
  frame : @transit.EvidenceTransitFrame,
  sigma_multiplier : Double,
) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("evidence_transit_frame"),
    "counting": gate_evidence_frame_json(frame.counting, sigma_multiplier),
    "passages": Json(
      frame.passages.map(passage => {
        Json::object({
          "section_id": Json(passage.section_id),
          "track_id": Json(passage.track_id),
          "segment_id": Json(passage.segment_id),
          "entry": gate_crossing_json(passage.entry),
          "exit": gate_crossing_json(passage.exit),
          "elapsed_lower_us": Json(passage.elapsed_lower_us.to_string()),
          "elapsed_upper_us": Json(passage.elapsed_upper_us.to_string()),
          "estimated_elapsed_us": Json(passage.estimated_elapsed_us),
        })
      }),
    ),
    "cancellations": Json(
      frame.cancellations.map(cancellation => {
        Json::object({
          "section_id": Json(cancellation.section_id),
          "track_id": Json(cancellation.track_id),
          "segment_id": Json(cancellation.segment_id),
          "reason": Json(
            match cancellation.reason {
              @transit.Discontinuity => "discontinuity"
              @transit.Expired => "expired"
              @transit.Reentered => "reentered"
              @transit.Reversed => "reversed"
              @transit.AmbiguousOrder => "ambiguous_order"
            },
          ),
          "entry": gate_crossing_json(cancellation.entry),
        })
      }),
    ),
    "counts": transit_counts_json(frame.counts),
    "pending_count": Json(frame.pending_count),
  })
}

///|
fn EvidenceTransitReplay::evidence_transit_process_frame(
  self : EvidenceTransitReplay,
  source : String,
) -> Json raise @types.GroundError {
  evidence_transit_frame_json(
    self.counter.update(gate_measurement(source, self.max_tracks)),
    self.sigma_multiplier,
  )
}

///|
/// Commit a valid measurement atomically. Keep every input frame, including
/// empty and rejected frames, so a pending entry cannot bridge a data gap.
pub fn EvidenceTransitReplay::process_line(
  self : EvidenceTransitReplay,
  source : String,
) -> String raise @types.GroundError {
  self.evidence_transit_process_frame(source).stringify()
}

///|
pub fn EvidenceTransitReplay::checkpoint_json(
  self : EvidenceTransitReplay,
) -> String raise @types.GroundError {
  let result = evidence_transit_checkpoint_value(self.counter.checkpoint()).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "evidence transit checkpoint exceeds 8388608 UTF-16 code units",
    )
  }
  result
}

///|
/// Pure bounded replay without persistent handles. Failure returns no prefix.
pub fn evidence_transit_json(
  source : String,
) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid("evidence transit request exceeds 16777216 UTF-16 code units")
  }
  let value = @json.parse(
    source,
    max_nesting_depth=32,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error =>
      raise invalid(
        "invalid evidence transit request JSON: " + error.to_string(),
      )
  }
  let fields = object(value, "evidence transit request")
  allowed_fields(fields, ["source", "measurements"], "evidence transit request")
  let replay = EvidenceTransitReplay::open(
    text(required(fields, "source"), "source"),
  )
  let measurements = text(required(fields, "measurements"), "measurements")
  if measurements.length() > 8388608 {
    raise invalid(
      "evidence transit measurements exceed 8388608 UTF-16 code units",
    )
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
    raise invalid("evidence transit batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut output_length = 0
  for line in lines {
    let frame = replay.evidence_transit_process_frame(line.to_owned())
    output_length += frame.stringify().length() + 1
    if output_length > 8388608 {
      raise invalid("evidence transit output exceeds 8388608 UTF-16 code units")
    }
    frames.push(frame)
  }
  let result = Json::object({
    "frames": Json(frames),
    "checkpoint": parse_checkpoint_document(replay.checkpoint_json()),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("evidence transit output exceeds 8388608 UTF-16 code units")
  }
  result
}
