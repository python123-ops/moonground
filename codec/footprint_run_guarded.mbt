///|
/// Fixed-landmark health, raw pixel motion and explicitly bound footprint runs.
pub struct FootprintRunGuardedReplay {
  priv session : @guarded.FootprintRunGuardedSession
  priv mut analysis_configuration : Json
  priv mut health_configuration : Json
  priv monitor_id : String
  priv diagnostics : Bool
  priv max_tracks : Int32
  priv run_capacity : Int32
}

///|
fn joined_footprint_run_guarded(
  analysis : FootprintRunAnalysisReplay,
  health : HealthReplay,
) -> FootprintRunGuardedReplay raise @types.GroundError {
  {
    session: @guarded.FootprintRunGuardedSession::new(
      analysis.session,
      health.monitor,
    ),
    analysis_configuration: analysis.configuration,
    health_configuration: health.configuration,
    monitor_id: health.monitor_id,
    diagnostics: analysis.diagnostics,
    max_tracks: analysis.max_tracks,
    run_capacity: analysis.run_capacity,
  }
}

///|
fn restore_footprint_run_guarded(
  value : Json,
) -> FootprintRunGuardedReplay raise @types.GroundError {
  let fields = object(value, "footprint run guarded checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "analysis", "health"],
    "footprint run guarded checkpoint",
  )
  if text(required(fields, "format"), "format") !=
    "moonground.footprint-run-guarded" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid(
      "unsupported footprint run guarded checkpoint format or version",
    )
  }
  joined_footprint_run_guarded(
    restore_footprint_run_analysis(required(fields, "analysis")),
    restore_health(required(fields, "health")),
  )
}

///|
pub fn FootprintRunGuardedReplay::open(
  source : String,
) -> FootprintRunGuardedReplay raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=8388619),
    "footprint run guarded source",
  )
  if fields.get("resume") is Some(saved) {
    allowed_fields(fields, ["resume"], "footprint run guarded resume")
    if saved.stringify().length() > 8388608 {
      raise invalid(
        "footprint run guarded checkpoint exceeds 8388608 UTF-16 code units",
      )
    }
    restore_footprint_run_guarded(saved)
  } else {
    allowed_fields(
      fields,
      ["analysis", "health"],
      "footprint run guarded source",
    )
    joined_footprint_run_guarded(
      FootprintRunAnalysisReplay::open(
        text(required(fields, "analysis"), "analysis"),
      ),
      HealthReplay::open(text(required(fields, "health"), "health")),
    )
  }
}

///|
fn FootprintRunGuardedReplay::prepare_pair(
  self : FootprintRunGuardedReplay,
  fields : Map[String, Json],
) -> @guarded.FootprintRunGuardedPreparation raise @types.GroundError {
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
      "footprint run guarded measurement and landmark timestamps differ",
    )
  }
  self.session.prepare(
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

///|
fn footprint_run_guarded_frame_json(
  result : @guarded.FootprintRunGuardedFrame,
  monitor_id : String,
  diagnostics : Bool,
  kind~ : String = "footprint_run_guarded_frame",
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
    "health": health_report_json(monitor_id, result.health),
    "suppressed_track_ids": Json(result.suppressed_track_ids),
    "analysis": footprint_run_analysis_frame_json(result.analysis, diagnostics),
  })
}

///|
fn footprint_run_guarded_preview_value(
  preview : @guarded.FootprintRunGuardedPreview,
  monitor_id : String,
  diagnostics : Bool,
) -> Json {
  Json::object({
    "decision": Json(
      match preview.decision {
        @guarded.Allowed => "allowed"
        @guarded.Blocked => "blocked"
      },
    ),
    "health": health_report_json(monitor_id, preview.health),
    "suppressed_track_ids": Json(preview.suppressed_track_ids),
    "measurement": measurement_json(
      preview.measurement.motion,
      preview.measurement.projection_failures,
      diagnostics,
    ),
  })
}

///|
fn FootprintRunGuardedReplay::replace_projection(
  self : FootprintRunGuardedReplay,
  fields : Map[String, Json],
) -> @guarded.FootprintRunGuardedFrame raise @types.GroundError {
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
}

///|
fn FootprintRunGuardedReplay::process_frame(
  self : FootprintRunGuardedReplay,
  source : String,
) -> Json raise @types.GroundError {
  let fields = object(parse_document(source), "footprint run guarded frame")
  if fields.contains("replace_projection") {
    return footprint_run_guarded_frame_json(
      self.replace_projection(fields),
      self.monitor_id,
      self.diagnostics,
      kind="footprint_run_guarded_projection_replaced",
    )
  }
  allowed_fields(
    fields,
    ["measurement", "health", "assignments"],
    "footprint run guarded frame",
  )
  let prepared = self.prepare_pair(fields)
  let assignments = assigned_footprints(
    text(required(fields, "assignments"), "assignments"),
    self.run_capacity,
  )
  footprint_run_guarded_frame_json(
    prepared.commit(assignments),
    self.monitor_id,
    self.diagnostics,
  )
}

///|
pub fn FootprintRunGuardedReplay::process_line(
  self : FootprintRunGuardedReplay,
  source : String,
) -> String raise @types.GroundError {
  self.process_frame(source).stringify()
}

///|
/// Read one real candidate at the committed baseline without installing it.
pub fn FootprintRunGuardedReplay::preview_line(
  self : FootprintRunGuardedReplay,
  source : String,
) -> String raise @types.GroundError {
  let fields = object(
    parse_document(source),
    "footprint run guarded preview frame",
  )
  allowed_fields(
    fields,
    ["measurement", "health"],
    "footprint run guarded preview frame",
  )
  let output = footprint_run_guarded_preview_value(
    self.prepare_pair(fields).preview(),
    self.monitor_id,
    self.diagnostics,
  ).stringify()
  if output.length() > 8388608 {
    raise invalid(
      "footprint run guarded preview output exceeds 8388608 UTF-16 code units",
    )
  }
  output
}

///|
pub fn FootprintRunGuardedReplay::checkpoint_json(
  self : FootprintRunGuardedReplay,
) -> String raise @types.GroundError {
  let saved = self.session.checkpoint()
  let output = Json::object({
    "format": Json("moonground.footprint-run-guarded"),
    "checkpoint_version": Json("1"),
    "analysis": footprint_run_analysis_checkpoint_value(
      saved.analysis,
      self.analysis_configuration,
    ),
    "health": health_checkpoint_value(saved.health, self.health_configuration),
  }).stringify()
  if output.length() > 8388608 {
    raise invalid(
      "footprint run guarded checkpoint exceeds 8388608 UTF-16 code units",
    )
  }
  output
}

///|
// Only a private, newly opened replay is advanced during identity discovery.
// Empty assignments suppress geometry, never alter the health/motion identities.
fn FootprintRunGuardedReplay::discover_frame(
  self : FootprintRunGuardedReplay,
  source : String,
) -> Json raise @types.GroundError {
  let fields = object(
    parse_document(source),
    "footprint run guarded discovery frame",
  )
  if fields.contains("replace_projection") {
    let result = self.replace_projection(fields)
    return footprint_run_guarded_preview_value(
      {
        decision: result.decision,
        health: result.health,
        measurement: result.analysis.measurement,
        suppressed_track_ids: result.suppressed_track_ids,
      },
      self.monitor_id,
      self.diagnostics,
    )
  }
  allowed_fields(
    fields,
    ["measurement", "health"],
    "footprint run guarded discovery frame",
  )
  let prepared = self.prepare_pair(fields)
  let preview = prepared.preview()
  ignore(
    prepared.commit(
      @zones.FootprintAssignments::new(
        preview.measurement.motion.timestamp_us,
        [],
      ),
    ),
  )
  footprint_run_guarded_preview_value(
    preview,
    self.monitor_id,
    self.diagnostics,
  )
}

///|
fn footprint_run_guarded_batch(
  source : String,
  preview : Bool,
) -> String raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "footprint run guarded request",
  )
  allowed_fields(fields, ["source", "frames"], "footprint run guarded request")
  let replay = FootprintRunGuardedReplay::open(
    text(required(fields, "source"), "source"),
  )
  let input = text(required(fields, "frames"), "frames")
  if input.length() > 8388608 {
    raise invalid(
      "footprint run guarded frames exceed 8388608 UTF-16 code units",
    )
  }
  let lines = if input.length() == 0 { [] } else { input.split("\n").collect() }
  if input.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5000 {
    raise invalid("footprint run guarded batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut units = 0
  for line in lines {
    let frame = if preview {
      replay.discover_frame(line.to_owned())
    } else {
      replay.process_frame(line.to_owned())
    }
    units += frame.stringify().length() + 1
    if units > 8388608 {
      raise invalid(
        "footprint run guarded output exceeds 8388608 UTF-16 code units",
      )
    }
    frames.push(frame)
  }
  let value = if preview {
    Json::object({ "frames": Json(frames) })
  } else {
    Json::object({
      "frames": Json(frames),
      "checkpoint": parse_checkpoint_document(replay.checkpoint_json()),
    })
  }
  let output = value.stringify()
  if output.length() > 8388608 {
    raise invalid(
      "footprint run guarded output exceeds 8388608 UTF-16 code units",
    )
  }
  output
}

///|
pub fn footprint_run_guarded_json(
  source : String,
) -> String raise @types.GroundError {
  footprint_run_guarded_batch(source, false)
}

///|
/// Discover all candidate identities, including recovery after health blocking.
/// This returns no shape decisions, durable checkpoint or commit reservation.
pub fn footprint_run_guarded_preview_json(
  source : String,
) -> String raise @types.GroundError {
  footprint_run_guarded_batch(source, true)
}
