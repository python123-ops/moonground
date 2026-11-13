///|
/// Independent current-frame projection, without a watermark or counters.
pub struct VelocityEvidenceReplay {
  priv projector : @velocity.VelocityProjector
  priv max_tracks : Int32
}

///|
/// Preserve raw configuration numbers and reject unknown or duplicate fields.
pub fn VelocityEvidenceReplay::open(
  source : String,
) -> VelocityEvidenceReplay raise @types.GroundError {
  let fields = object(parse_document(source), "velocity evidence configuration")
  allowed_fields(
    fields,
    ["session_id", "probes", "max_tracks"],
    "velocity evidence configuration",
  )
  let probes = array(required(fields, "probes"), "velocity probes", 16).map(value => {
    let fields = object(value, "velocity probe")
    allowed_fields(
      fields,
      ["probe_id", "direction", "threshold_mps", "sigma_multiplier"],
      "velocity probe",
    )
    @velocity.VelocityProbe::new(
      text(required(fields, "probe_id"), "probe_id"),
      point(required(fields, "direction"), "direction"),
      number(required(fields, "threshold_mps"), "threshold_mps"),
      sigma_multiplier=match fields.get("sigma_multiplier") {
        Some(value) => number(value, "sigma_multiplier")
        None => 2.0
      },
    )
  })
  let max_tracks = match fields.get("max_tracks") {
    Some(value) => positive_int(value, "max_tracks")
    None => 1000
  }
  {
    projector: @velocity.VelocityProjector::new(
      text(required(fields, "session_id"), "session_id"),
      probes,
      max_tracks~,
    ),
    max_tracks,
  }
}

///|
fn velocity_decision_json(decision : @velocity.VelocityDecision) -> Json {
  Json(
    match decision {
      @velocity.Above => "above"
      @velocity.AtOrBelow => "at_or_below"
      @velocity.Indeterminate => "indeterminate"
    },
  )
}

///|
fn velocity_unavailable_json(row : @velocity.VelocityUnavailable) -> Json {
  Json::object({
    "track_id": Json(row.track_id),
    "segment_id": match row.segment_id {
      Some(value) => Json(value)
      None => Json::null()
    },
    "reason": Json(
      match row.reason {
        @velocity.Initializing => "initializing"
        @velocity.Uncertain => "uncertain"
        @velocity.RejectedInnovation => "rejected_innovation"
        @velocity.NumericalFailure => "numerical_failure"
        @velocity.RejectedProjection => "rejected_projection"
      },
    ),
  })
}

///|
fn velocity_frame_json(frame : @velocity.VelocityEvidenceFrame) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("velocity_evidence_frame"),
    "evidence_scope": Json("model_velocity_component_band"),
    "session_id": Json(frame.session_id),
    "timestamp_us": Json(frame.timestamp_us.to_string()),
    "evidence": Json(
      frame.evidence.map(row => {
        let band = row.evidence
        Json::object({
          "track_id": Json(row.track_id),
          "segment_id": Json(row.segment_id),
          "probe_id": Json(band.probe_id),
          "component_mps": Json(band.component_mps),
          "axis_std_mps": Json(band.axis_std_mps),
          "lower_mps": Json(band.lower_mps),
          "upper_mps": Json(band.upper_mps),
          "threshold_mps": Json(band.threshold_mps),
          "sigma_multiplier": Json(band.sigma_multiplier),
          "decision": velocity_decision_json(band.decision),
        })
      }),
    ),
    "unavailable": Json(frame.unavailable.map(velocity_unavailable_json)),
  })
}

///|
fn VelocityEvidenceReplay::velocity_process_frame(
  self : VelocityEvidenceReplay,
  source : String,
) -> Json raise @types.GroundError {
  // The original parser validates every status and projection-failure payload.
  let frame = self.projector.evaluate(gate_measurement(source, self.max_tracks))
  let fields = object(parse_document(source), "measurement frame")
  for
    value in array(
      required(fields, "tracks"),
      "measurement tracks",
      self.max_tracks,
    ) {
    let fields = object(value, "measurement track")
    if fields.get("status") is Some(String("rejected_projection")) {
      frame.unavailable.push({
        track_id: positive_int(required(fields, "track_id"), "track_id"),
        segment_id: None,
        reason: @velocity.RejectedProjection,
      })
    }
  }
  frame.unavailable.sort_by((a, b) => a.track_id.compare(b.track_id))
  velocity_frame_json(frame)
}

///|
/// Repeated or reordered internally current frames are independent evaluations.
pub fn VelocityEvidenceReplay::process_line(
  self : VelocityEvidenceReplay,
  source : String,
) -> String raise @types.GroundError {
  self.velocity_process_frame(source).stringify()
}

///|
/// Pure bounded measurements; no checkpoint, handles or failed-batch prefix.
pub fn velocity_evidence_json(
  source : String,
) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid(
      "velocity evidence request exceeds 16777216 UTF-16 code units",
    )
  }
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "velocity evidence request",
  )
  allowed_fields(
    fields,
    ["source", "measurements"],
    "velocity evidence request",
  )
  let replay = VelocityEvidenceReplay::open(
    text(required(fields, "source"), "source"),
  )
  let measurements = text(required(fields, "measurements"), "measurements")
  if measurements.length() > 8388608 {
    raise invalid(
      "velocity evidence measurements exceed 8388608 UTF-16 code units",
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
    raise invalid("velocity evidence batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut length = 0
  for line in lines {
    let frame = replay.velocity_process_frame(line.to_owned())
    length += frame.stringify().length() + 1
    if length > 8388608 {
      raise invalid(
        "velocity evidence output exceeds 8388608 UTF-16 code units",
      )
    }
    frames.push(frame)
  }
  let result = Json::object({ "frames": Json(frames) }).stringify()
  if result.length() > 8388608 {
    raise invalid("velocity evidence output exceeds 8388608 UTF-16 code units")
  }
  result
}
