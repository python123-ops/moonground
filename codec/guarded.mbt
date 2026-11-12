///|
/// One explicit owner of calibration evidence, pixel motion and gate counts.
pub struct GuardedReplay {
  priv session : @guarded.GuardedSession
  priv analysis_configuration : Json
  priv health_configuration : Json
  priv monitor_id : String
  priv diagnostics : Bool
  priv max_tracks : Int32
}

///|
fn joined_guarded(
  analysis : AnalysisReplay,
  health : HealthReplay,
) -> GuardedReplay raise @types.GroundError {
  let session = @guarded.GuardedSession::new(analysis.session, health.monitor)
  {
    session,
    analysis_configuration: analysis.configuration,
    health_configuration: health.configuration,
    monitor_id: health.monitor_id,
    diagnostics: analysis.diagnostics,
    max_tracks: analysis.max_tracks,
  }
}

///|
fn restore_guarded(value : Json) -> GuardedReplay raise @types.GroundError {
  let fields = object(value, "guarded checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "analysis", "health"],
    "guarded checkpoint",
  )
  if text(required(fields, "format"), "format") != "moonground.guarded" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid("unsupported guarded checkpoint format or version")
  }
  joined_guarded(
    restore_analysis(required(fields, "analysis")),
    restore_health(required(fields, "health")),
  )
}

///|
/// Preserve both raw source documents and reject incompatible pixel mappings.
pub fn GuardedReplay::open(
  source : String,
) -> GuardedReplay raise @types.GroundError {
  let value = parse_checkpoint_document(source, max_units=8388619)
  let fields = object(value, "guarded source")
  if fields.get("resume") is Some(saved) {
    allowed_fields(fields, ["resume"], "guarded resume envelope")
    if saved.stringify().length() > 8388608 {
      raise invalid("guarded checkpoint exceeds 8388608 UTF-16 code units")
    }
    restore_guarded(saved)
  } else {
    allowed_fields(fields, ["analysis", "health"], "guarded source")
    joined_guarded(
      AnalysisReplay::open(text(required(fields, "analysis"), "analysis")),
      HealthReplay::open(text(required(fields, "health"), "health")),
    )
  }
}

///|
fn GuardedReplay::guarded_process_frame(
  self : GuardedReplay,
  source : String,
) -> Json raise @types.GroundError {
  let fields = object(parse_document(source), "guarded frame")
  allowed_fields(fields, ["measurement", "health"], "guarded frame")
  let (time, observations, lost, removed) = observation_frame(
    text(required(fields, "measurement"), "measurement"),
    self.max_tracks,
    true,
  )
  let (health_time, landmarks) = health_observation_frame(
    text(required(fields, "health"), "health"),
  )
  if time != health_time {
    raise invalid("guarded measurement and landmark timestamps differ")
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
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("guarded_analysis_frame"),
    "decision": Json(
      match result.decision {
        @guarded.Allowed => "allowed"
        @guarded.Blocked => "blocked"
      },
    ),
    "suppressed_track_ids": Json(result.suppressed_track_ids),
    "health": health_report_json(self.monitor_id, result.health),
    "analysis": analysis_frame_json(result.analysis, self.diagnostics),
  })
}

///|
/// A fatal error leaves health evidence, motion, segments and counts unchanged.
pub fn GuardedReplay::process_line(
  self : GuardedReplay,
  source : String,
) -> String raise @types.GroundError {
  self.guarded_process_frame(source).stringify()
}

///|
/// Export one complete bound checkpoint, with no independent watermark pairing.
pub fn GuardedReplay::checkpoint_json(
  self : GuardedReplay,
) -> String raise @types.GroundError {
  let saved = self.session.checkpoint()
  let result = Json::object({
    "format": Json("moonground.guarded"),
    "checkpoint_version": Json("1"),
    "analysis": analysis_checkpoint_value(
      saved.analysis,
      self.analysis_configuration,
    ),
    "health": health_checkpoint_value(saved.health, self.health_configuration),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("guarded checkpoint exceeds 8388608 UTF-16 code units")
  }
  result
}

///|
/// Pure bounded batch of paired raw pixel and fixed-landmark frame documents.
pub fn guarded_json(source : String) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid("guarded request exceeds 16777216 UTF-16 code units")
  }
  let value = @json.parse(
    source,
    max_nesting_depth=32,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error => raise invalid("invalid guarded request JSON: " + error.to_string())
  }
  let fields = object(value, "guarded request")
  allowed_fields(fields, ["source", "observations"], "guarded request")
  let replay = GuardedReplay::open(text(required(fields, "source"), "source"))
  let observations = text(required(fields, "observations"), "observations")
  if observations.length() > 8388608 {
    raise invalid("guarded observations exceed 8388608 UTF-16 code units")
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
    raise invalid("guarded batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut output_length = 0
  for line in lines {
    let frame = replay.guarded_process_frame(line.to_owned())
    output_length += frame.stringify().length() + 1
    if output_length > 8388608 {
      raise invalid("guarded output exceeds 8388608 UTF-16 code units")
    }
    frames.push(frame)
  }
  let result = Json::object({
    "frames": Json(frames),
    "checkpoint": parse_checkpoint_document(replay.checkpoint_json()),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("guarded output exceeds 8388608 UTF-16 code units")
  }
  result
}
