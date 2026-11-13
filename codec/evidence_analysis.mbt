///|
/// One transactional owner of raw observations and covariance-evidence gates.
pub struct EvidenceAnalysisReplay {
  priv session : @analysis.EvidenceAnalysisSession
  priv configuration : Json
  priv diagnostics : Bool
  priv max_tracks : Int32
  priv pixel : Bool
  priv sigma_multiplier : Double
}

///|
fn joined_evidence_analysis(
  measurement : ReplaySession,
  counting : @events.EvidenceGateCounter,
) -> EvidenceAnalysisReplay raise @types.GroundError {
  let (session, pixel) = match (measurement.pixel, measurement.ground) {
    (Some(pixel), None) =>
      (@analysis.EvidenceAnalysisSession::from_pixel(pixel, counting), true)
    (None, Some(ground)) =>
      (@analysis.EvidenceAnalysisSession::from_ground(ground, counting), false)
    _ => raise invalid("invalid evidence analysis measurement mode")
  }
  {
    session,
    configuration: measurement.configuration,
    diagnostics: measurement.diagnostics,
    max_tracks: measurement.max_tracks,
    pixel,
    sigma_multiplier: counting.checkpoint().sigma_multiplier,
  }
}

///|
fn restore_evidence_analysis(
  value : Json,
) -> EvidenceAnalysisReplay raise @types.GroundError {
  let fields = object(value, "evidence analysis checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "measurement", "counting"],
    "evidence analysis checkpoint",
  )
  if text(required(fields, "format"), "format") !=
    "moonground.evidence-analysis" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid("unsupported evidence analysis checkpoint format or version")
  }
  joined_evidence_analysis(
    restore_checkpoint(required(fields, "measurement")),
    restore_evidence_checkpoint(required(fields, "counting")),
  )
}

///|
/// Raw inner strings preserve integer tokens, duplicate keys and exact times.
pub fn EvidenceAnalysisReplay::open(
  source : String,
) -> EvidenceAnalysisReplay raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=8388619),
    "evidence analysis source",
  )
  if fields.get("resume") is Some(saved) {
    allowed_fields(fields, ["resume"], "evidence analysis resume")
    if saved.stringify().length() > 8388608 {
      raise invalid(
        "evidence analysis checkpoint exceeds 8388608 UTF-16 code units",
      )
    }
    restore_evidence_analysis(saved)
  } else {
    allowed_fields(
      fields,
      ["measurement", "counting"],
      "evidence analysis source",
    )
    joined_evidence_analysis(
      ReplaySession::open(text(required(fields, "measurement"), "measurement")),
      EvidenceGateReplay::open(text(required(fields, "counting"), "counting")).counter,
    )
  }
}

///|
fn EvidenceAnalysisReplay::evidence_analysis_process_frame(
  self : EvidenceAnalysisReplay,
  source : String,
) -> Json raise @types.GroundError {
  let (time, observations, lost, removed) = observation_frame(
    source,
    self.max_tracks,
    self.pixel,
  )
  let result = if self.pixel {
    self.session.update_pixel(
      time,
      observations.map(observation => @moonground.PixelObservation::{
        track_id: observation.track_id,
        position: observation.position,
        covariance: observation.covariance,
      }),
      lost~,
      removed~,
    )
  } else {
    self.session.update_ground(time, observations, lost~, removed~)
  }
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("evidence_analysis_frame"),
    "measurement": measurement_json(
      result.measurement.motion,
      result.measurement.projection_failures,
      self.diagnostics,
    ),
    "counting": gate_evidence_frame_json(result.counting, self.sigma_multiplier),
  })
}

///|
/// A gate failure preserves measured state, watermark and segment allocation.
pub fn EvidenceAnalysisReplay::process_line(
  self : EvidenceAnalysisReplay,
  source : String,
) -> String raise @types.GroundError {
  self.evidence_analysis_process_frame(source).stringify()
}

///|
pub fn EvidenceAnalysisReplay::checkpoint_json(
  self : EvidenceAnalysisReplay,
) -> String raise @types.GroundError {
  let saved = self.session.checkpoint()
  let result = Json::object({
    "format": Json("moonground.evidence-analysis"),
    "checkpoint_version": Json("1"),
    "measurement": analysis_measurement_checkpoint_value(
      saved.measurement,
      self.configuration,
    ),
    "counting": evidence_checkpoint_value(saved.counting),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "evidence analysis checkpoint exceeds 8388608 UTF-16 code units",
    )
  }
  result
}

///|
/// Pure bounded replay of observations. Failed batches expose no partial state.
pub fn evidence_analysis_json(
  source : String,
) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid(
      "evidence analysis request exceeds 16777216 UTF-16 code units",
    )
  }
  let value = @json.parse(
    source,
    max_nesting_depth=32,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error =>
      raise invalid(
        "invalid evidence analysis request JSON: " + error.to_string(),
      )
  }
  let fields = object(value, "evidence analysis request")
  allowed_fields(
    fields,
    ["source", "observations"],
    "evidence analysis request",
  )
  let replay = EvidenceAnalysisReplay::open(
    text(required(fields, "source"), "source"),
  )
  let observations = text(required(fields, "observations"), "observations")
  if observations.length() > 8388608 {
    raise invalid(
      "evidence analysis observations exceed 8388608 UTF-16 code units",
    )
  }
  let lines = if observations.length() == 0 {
    []
  } else {
    observations.split("\n").collect()
  }
  if observations.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5000 {
    raise invalid("evidence analysis batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut output_length = 0
  for line in lines {
    let frame = replay.evidence_analysis_process_frame(line.to_owned())
    output_length += frame.stringify().length() + 1
    if output_length > 8388608 {
      raise invalid(
        "evidence analysis output exceeds 8388608 UTF-16 code units",
      )
    }
    frames.push(frame)
  }
  let result = Json::object({
    "frames": Json(frames),
    "checkpoint": parse_checkpoint_document(replay.checkpoint_json()),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("evidence analysis output exceeds 8388608 UTF-16 code units")
  }
  result
}
