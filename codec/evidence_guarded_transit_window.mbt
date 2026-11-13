///|
/// Paired landmark/object observations and projection barriers share one
/// transaction and one complete confirmation-window checkpoint.
pub struct EvidenceGuardedTransitWindowReplay {
  priv session : @guarded.EvidenceGuardedTransitWindowSession
  priv mut analysis_configuration : Json
  priv mut health_configuration : Json
  priv monitor_id : String
  priv diagnostics : Bool
  priv max_tracks : Int32
  priv sigma_multiplier : Double
}

///|
fn guarded_transit_window_replay(
  guarded : EvidenceGuardedTransitReplay,
  session : @guarded.EvidenceGuardedTransitWindowSession,
) -> EvidenceGuardedTransitWindowReplay {
  {
    session,
    analysis_configuration: guarded.analysis_configuration,
    health_configuration: guarded.health_configuration,
    monitor_id: guarded.monitor_id,
    diagnostics: guarded.diagnostics,
    max_tracks: guarded.max_tracks,
    sigma_multiplier: guarded.sigma_multiplier,
  }
}

///|
fn joined_evidence_guarded_transit_window(
  guarded : EvidenceGuardedTransitReplay,
  windows : String,
) -> EvidenceGuardedTransitWindowReplay raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(windows, max_units=8388619),
    "guarded transit window configuration",
  )
  let session = if fields.contains("resume") {
    let windows = EvidenceTransitWindowReplay::open(windows)
    @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint({
      version: 1,
      guarded: guarded.session.checkpoint(),
      windows: windows.counter.checkpoint(),
    })
  } else {
    if windows.length() > 1048576 {
      raise invalid(
        "guarded transit window configuration exceeds 1048576 UTF-16 code units",
      )
    }
    allowed_fields(
      fields,
      ["window_us", "duration_limits_us", "origin_us"],
      "guarded transit window configuration",
    )
    @guarded.EvidenceGuardedTransitWindowSession::new(
      guarded.session,
      window_us=timestamp(required(fields, "window_us"), "window_us"),
      duration_limits_us=window_limits(required(fields, "duration_limits_us")),
      origin_us=match fields.get("origin_us") {
        Some(value) => timestamp(value, "origin_us")
        None => 0L
      },
    )
  }
  guarded_transit_window_replay(guarded, session)
}

///|
fn restore_evidence_guarded_transit_window(
  value : Json,
) -> EvidenceGuardedTransitWindowReplay raise @types.GroundError {
  let fields = object(value, "evidence guarded transit window checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "guarded", "windows"],
    "evidence guarded transit window checkpoint",
  )
  if text(required(fields, "format"), "format") !=
    "moonground.evidence-guarded-transit-windows" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid(
      "unsupported evidence guarded transit window checkpoint format or version",
    )
  }
  let guarded = restore_evidence_guarded_transit(required(fields, "guarded"))
  let windows = window_restore_checkpoint(required(fields, "windows"))
  guarded_transit_window_replay(
    guarded,
    @guarded.EvidenceGuardedTransitWindowSession::from_checkpoint({
      version: 1,
      guarded: guarded.session.checkpoint(),
      windows: windows.checkpoint(),
    }),
  )
}

///|
/// Both nested documents remain raw until their original strict parsers run.
pub fn EvidenceGuardedTransitWindowReplay::open(
  source : String,
) -> EvidenceGuardedTransitWindowReplay raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=8388619),
    "evidence guarded transit window source",
  )
  if fields.get("resume") is Some(saved) {
    allowed_fields(fields, ["resume"], "evidence guarded transit window resume")
    if saved.stringify().length() > 8388608 {
      raise invalid(
        "evidence guarded transit window checkpoint exceeds 8388608 UTF-16 code units",
      )
    }
    restore_evidence_guarded_transit_window(saved)
  } else {
    allowed_fields(
      fields,
      ["guarded", "windows"],
      "evidence guarded transit window source",
    )
    joined_evidence_guarded_transit_window(
      EvidenceGuardedTransitReplay::open(
        text(required(fields, "guarded"), "guarded"),
      ),
      text(required(fields, "windows"), "windows"),
    )
  }
}

///|
fn evidence_guarded_transit_window_frame_json(
  result : @guarded.EvidenceGuardedTransitWindowFrame,
  monitor_id : String,
  diagnostics : Bool,
  sigma_multiplier : Double,
  replaced~ : Bool = false,
) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("evidence_guarded_transit_window_frame"),
    "guarded": evidence_guarded_transit_frame_json(
      result.guarded,
      monitor_id,
      diagnostics,
      sigma_multiplier,
      kind=if replaced {
        "evidence_guarded_transit_projection_replaced"
      } else {
        "evidence_guarded_transit_frame"
      },
    ),
    "windows": window_frame_json(result.windows),
  })
}

///|
fn EvidenceGuardedTransitWindowReplay::evidence_guarded_transit_window_process_frame(
  self : EvidenceGuardedTransitWindowReplay,
  source : String,
) -> Json raise @types.GroundError {
  let fields = object(
    parse_document(source),
    "evidence guarded transit window frame",
  )
  let result = if fields.contains("replace_projection") {
    let (time, calibration, effective, camera) = projection_replacement(fields)
    let analysis_configuration = replaced_projection_configuration(
      self.analysis_configuration,
      effective,
      camera,
      measurement=true,
    )
    let health_configuration = replaced_projection_configuration(
      self.health_configuration,
      effective,
      camera,
    )
    let result = self.session.replace_projection(time, calibration, camera~)
    self.analysis_configuration = analysis_configuration
    self.health_configuration = health_configuration
    result
  } else {
    allowed_fields(
      fields,
      ["measurement", "health"],
      "evidence guarded transit window frame",
    )
    let (time, observations, lost, removed) = observation_frame(
      text(required(fields, "measurement"), "measurement"),
      self.max_tracks,
      true,
    )
    let (health_time, landmarks) = health_observation_frame(
      text(required(fields, "health"), "health"),
    )
    if time != health_time {
      raise invalid(
        "guarded transit window measurement and landmark timestamps differ",
      )
    }
    self.session.update(
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
  }
  evidence_guarded_transit_window_frame_json(
    result,
    self.monitor_id,
    self.diagnostics,
    self.sigma_multiplier,
    replaced=fields.contains("replace_projection"),
  )
}

///|
pub fn EvidenceGuardedTransitWindowReplay::process_line(
  self : EvidenceGuardedTransitWindowReplay,
  source : String,
) -> String raise @types.GroundError {
  self.evidence_guarded_transit_window_process_frame(source).stringify()
}

///|
pub fn EvidenceGuardedTransitWindowReplay::checkpoint_json(
  self : EvidenceGuardedTransitWindowReplay,
) -> String raise @types.GroundError {
  let saved = self.session.checkpoint()
  let result = Json::object({
    "format": Json("moonground.evidence-guarded-transit-windows"),
    "checkpoint_version": Json("1"),
    "guarded": Json::object({
      "format": Json("moonground.evidence-guarded-transit"),
      "checkpoint_version": Json("1"),
      "analysis": evidence_transit_analysis_checkpoint_value(
        saved.guarded.analysis,
        self.analysis_configuration,
      ),
      "health": health_checkpoint_value(
        saved.guarded.health,
        self.health_configuration,
      ),
    }),
    "windows": window_checkpoint_value(saved.windows),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "evidence guarded transit window checkpoint exceeds 8388608 UTF-16 code units",
    )
  }
  result
}

///|
/// Bounded batch without handles or partial output when a frame fails.
pub fn evidence_guarded_transit_window_json(
  source : String,
) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid(
      "evidence guarded transit window request exceeds 16777216 UTF-16 code units",
    )
  }
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "evidence guarded transit window request",
  )
  allowed_fields(
    fields,
    ["source", "observations"],
    "evidence guarded transit window request",
  )
  let replay = EvidenceGuardedTransitWindowReplay::open(
    text(required(fields, "source"), "source"),
  )
  let observations = text(required(fields, "observations"), "observations")
  if observations.length() > 8388608 {
    raise invalid(
      "evidence guarded transit window observations exceed 8388608 UTF-16 code units",
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
    raise invalid("evidence guarded transit window batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut output_length = 0
  for line in lines {
    let frame = replay.evidence_guarded_transit_window_process_frame(
      line.to_owned(),
    )
    output_length += frame.stringify().length() + 1
    if output_length > 8388608 {
      raise invalid(
        "evidence guarded transit window output exceeds 8388608 UTF-16 code units",
      )
    }
    frames.push(frame)
  }
  let result = Json::object({
    "frames": Json(frames),
    "checkpoint": parse_checkpoint_document(replay.checkpoint_json()),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "evidence guarded transit window output exceeds 8388608 UTF-16 code units",
    )
  }
  result
}
