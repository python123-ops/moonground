///|
/// One explicit owner of calibration evidence, pixel motion and gate counts.
pub struct EvidenceGuardedReplay {
  priv session : @guarded.EvidenceGuardedSession
  priv mut analysis_configuration : Json
  priv mut health_configuration : Json
  priv monitor_id : String
  priv diagnostics : Bool
  priv max_tracks : Int32
  priv sigma_multiplier : Double
}

///|
fn joined_evidence_guarded(
  analysis : EvidenceAnalysisReplay,
  health : HealthReplay,
) -> EvidenceGuardedReplay raise @types.GroundError {
  let session = @guarded.EvidenceGuardedSession::new(
    analysis.session,
    health.monitor,
  )
  {
    session,
    analysis_configuration: analysis.configuration,
    health_configuration: health.configuration,
    monitor_id: health.monitor_id,
    diagnostics: analysis.diagnostics,
    max_tracks: analysis.max_tracks,
    sigma_multiplier: analysis.sigma_multiplier,
  }
}

///|
fn restore_evidence_guarded(
  value : Json,
) -> EvidenceGuardedReplay raise @types.GroundError {
  let fields = object(value, "evidence guarded checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "analysis", "health"],
    "evidence guarded checkpoint",
  )
  if text(required(fields, "format"), "format") != "moonground.evidence-guarded" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid("unsupported evidence guarded checkpoint format or version")
  }
  joined_evidence_guarded(
    restore_evidence_analysis(required(fields, "analysis")),
    restore_health(required(fields, "health")),
  )
}

///|
/// Preserve both raw source documents and reject incompatible pixel mappings.
pub fn EvidenceGuardedReplay::open(
  source : String,
) -> EvidenceGuardedReplay raise @types.GroundError {
  let value = parse_checkpoint_document(source, max_units=8388619)
  let fields = object(value, "evidence guarded source")
  if fields.get("resume") is Some(saved) {
    allowed_fields(fields, ["resume"], "evidence guarded resume envelope")
    if saved.stringify().length() > 8388608 {
      raise invalid(
        "evidence guarded checkpoint exceeds 8388608 UTF-16 code units",
      )
    }
    restore_evidence_guarded(saved)
  } else {
    allowed_fields(fields, ["analysis", "health"], "evidence guarded source")
    joined_evidence_guarded(
      EvidenceAnalysisReplay::open(
        text(required(fields, "analysis"), "analysis"),
      ),
      HealthReplay::open(text(required(fields, "health"), "health")),
    )
  }
}

///|
fn EvidenceGuardedReplay::evidence_guarded_process_frame(
  self : EvidenceGuardedReplay,
  source : String,
) -> Json raise @types.GroundError {
  let fields = object(parse_document(source), "evidence guarded frame")
  if fields.contains("replace_projection") {
    return self.replace_projection_frame(fields)
  }
  allowed_fields(fields, ["measurement", "health"], "evidence guarded frame")
  let (time, observations, lost, removed) = observation_frame(
    text(required(fields, "measurement"), "measurement"),
    self.max_tracks,
    true,
  )
  let (health_time, landmarks) = health_observation_frame(
    text(required(fields, "health"), "health"),
  )
  if time != health_time {
    raise invalid("evidence guarded measurement and landmark timestamps differ")
  }
  let result = self.session.update(
    time,
    landmarks,
    observations.map(observation => @moonground.PixelObservation::{
      track_id: observation.track_id,
      position: observation.position,
      covariance: observation.covariance,
    }),
    lost~,
    removed~,
  )
  evidence_guarded_frame_json(
    result,
    self.monitor_id,
    self.diagnostics,
    self.sigma_multiplier,
  )
}

///|
fn evidence_guarded_frame_json(
  result : @guarded.EvidenceGuardedFrame,
  monitor_id : String,
  diagnostics : Bool,
  sigma_multiplier : Double,
  kind~ : String = "evidence_guarded_frame",
) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json(kind),
    "decision": Json(
      match result.decision {
        @guarded.Allowed => "allowed"
        @guarded.Blocked => "blocked"
      },
    ),
    "suppressed_track_ids": Json(result.suppressed_track_ids),
    "health": health_report_json(monitor_id, result.health),
    "analysis": evidence_analysis_frame_json(
      result.analysis,
      diagnostics,
      sigma_multiplier,
    ),
  })
}

///|
/// A fatal error leaves health evidence, motion, segments and counts unchanged.
pub fn EvidenceGuardedReplay::process_line(
  self : EvidenceGuardedReplay,
  source : String,
) -> String raise @types.GroundError {
  self.evidence_guarded_process_frame(source).stringify()
}

///|
/// Export one complete bound checkpoint, with no independent watermark pairing.
pub fn EvidenceGuardedReplay::checkpoint_json(
  self : EvidenceGuardedReplay,
) -> String raise @types.GroundError {
  let saved = self.session.checkpoint()
  let result = Json::object({
    "format": Json("moonground.evidence-guarded"),
    "checkpoint_version": Json("1"),
    "analysis": evidence_analysis_checkpoint_value(
      saved.analysis,
      self.analysis_configuration,
    ),
    "health": health_checkpoint_value(saved.health, self.health_configuration),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "evidence guarded checkpoint exceeds 8388608 UTF-16 code units",
    )
  }
  result
}

///|
/// Pure bounded batch of paired observations and explicit projection barriers.
pub fn evidence_guarded_json(
  source : String,
) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid("evidence guarded request exceeds 16777216 UTF-16 code units")
  }
  let value = @json.parse(
    source,
    max_nesting_depth=32,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error =>
      raise invalid(
        "invalid evidence guarded request JSON: " + error.to_string(),
      )
  }
  let fields = object(value, "evidence guarded request")
  allowed_fields(fields, ["source", "observations"], "evidence guarded request")
  let replay = EvidenceGuardedReplay::open(
    text(required(fields, "source"), "source"),
  )
  let observations = text(required(fields, "observations"), "observations")
  if observations.length() > 8388608 {
    raise invalid(
      "evidence guarded observations exceed 8388608 UTF-16 code units",
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
    raise invalid("evidence guarded batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut output_length = 0
  for line in lines {
    let frame = replay.evidence_guarded_process_frame(line.to_owned())
    output_length += frame.stringify().length() + 1
    if output_length > 8388608 {
      raise invalid("evidence guarded output exceeds 8388608 UTF-16 code units")
    }
    frames.push(frame)
  }
  let result = Json::object({
    "frames": Json(frames),
    "checkpoint": parse_checkpoint_document(replay.checkpoint_json()),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("evidence guarded output exceeds 8388608 UTF-16 code units")
  }
  result
}
