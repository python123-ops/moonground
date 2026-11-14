///|
/// One transactional owner of raw motion and exact-bound footprint sample runs.
pub struct FootprintRunAnalysisReplay {
  priv session : @analysis.FootprintRunSession
  priv configuration : Json
  priv diagnostics : Bool
  priv max_tracks : Int32
  priv run_capacity : Int32
  priv pixel : Bool
}

///|
fn joined_footprint_run_analysis(
  measurement : ReplaySession,
  runs : @zones.FootprintRunMonitor,
) -> FootprintRunAnalysisReplay raise @types.GroundError {
  let (session, pixel) = match (measurement.pixel, measurement.ground) {
    (Some(engine), None) =>
      (@analysis.FootprintRunSession::from_pixel(engine, runs), true)
    (None, Some(engine)) =>
      (@analysis.FootprintRunSession::from_ground(engine, runs), false)
    _ => raise invalid("invalid footprint run measurement mode")
  }
  {
    session,
    pixel,
    configuration: measurement.configuration,
    diagnostics: measurement.diagnostics,
    max_tracks: measurement.max_tracks,
    run_capacity: runs.checkpoint().max_tracks,
  }
}

///|
fn restore_footprint_run_analysis(
  value : Json,
) -> FootprintRunAnalysisReplay raise @types.GroundError {
  let fields = object(value, "footprint run analysis checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "measurement", "runs"],
    "footprint run analysis checkpoint",
  )
  if text(required(fields, "format"), "format") !=
    "moonground.footprint-run-analysis" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid(
      "unsupported footprint run analysis checkpoint format or version",
    )
  }
  joined_footprint_run_analysis(
    restore_checkpoint(required(fields, "measurement")),
    @zones.FootprintRunMonitor::from_checkpoint(
      footprint_run_checkpoint_value(required(fields, "runs")),
    ),
  )
}

///|
pub fn FootprintRunAnalysisReplay::open(
  source : String,
) -> FootprintRunAnalysisReplay raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=8388619),
    "footprint run analysis source",
  )
  if fields.get("resume") is Some(saved) {
    allowed_fields(fields, ["resume"], "footprint run analysis resume")
    if saved.stringify().length() > 8388608 {
      raise invalid(
        "footprint run analysis checkpoint exceeds 8388608 UTF-16 code units",
      )
    }
    restore_footprint_run_analysis(saved)
  } else {
    allowed_fields(
      fields,
      ["measurement", "runs"],
      "footprint run analysis source",
    )
    joined_footprint_run_analysis(
      ReplaySession::open(text(required(fields, "measurement"), "measurement")),
      FootprintRunReplay::open(text(required(fields, "runs"), "runs")).monitor,
    )
  }
}

///|
fn FootprintRunAnalysisReplay::prepare_observation(
  self : FootprintRunAnalysisReplay,
  source : String,
) -> @analysis.FootprintRunPreparation raise @types.GroundError {
  let (time, observations, lost, removed) = observation_frame(
    source,
    self.max_tracks,
    self.pixel,
  )
  if self.pixel {
    self.session.prepare_pixel(
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
    self.session.prepare_ground(time, observations, lost~, removed~)
  }
}

///|
fn FootprintRunAnalysisReplay::footprint_run_analysis_process_frame(
  self : FootprintRunAnalysisReplay,
  source : String,
) -> Json raise @types.GroundError {
  let fields = object(parse_document(source), "footprint run analysis frame")
  allowed_fields(
    fields,
    ["measurement", "assignments"],
    "footprint run analysis frame",
  )
  let prepared = self.prepare_observation(
    text(required(fields, "measurement"), "measurement"),
  )
  let assignments = assigned_footprints(
    text(required(fields, "assignments"), "assignments"),
    self.run_capacity,
  )
  let result = prepared.commit(assignments)
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("footprint_run_analysis_frame"),
    "measurement": measurement_json(
      result.measurement.motion,
      result.measurement.projection_failures,
      self.diagnostics,
    ),
    "runs": footprint_run_frame_json(result.runs),
  })
}

///|
pub fn FootprintRunAnalysisReplay::process_line(
  self : FootprintRunAnalysisReplay,
  source : String,
) -> String raise @types.GroundError {
  self.footprint_run_analysis_process_frame(source).stringify()
}

///|
/// Repeated previews independently start at the same committed baseline.
/// The returned measurement is not a reservation or a transferable candidate.
pub fn FootprintRunAnalysisReplay::preview_line(
  self : FootprintRunAnalysisReplay,
  source : String,
) -> String raise @types.GroundError {
  let measurement = self.prepare_observation(source).measurement()
  let result = Json::object({
    "measurement": measurement_json(
      measurement.motion,
      measurement.projection_failures,
      self.diagnostics,
    ),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "footprint run preview output exceeds 8388608 UTF-16 code units",
    )
  }
  result
}

///|
fn footprint_run_analysis_checkpoint_value(
  saved : @analysis.FootprintRunSessionCheckpoint,
  configuration : Json,
) -> Json raise @types.GroundError {
  Json::object({
    "format": Json("moonground.footprint-run-analysis"),
    "checkpoint_version": Json("1"),
    "measurement": analysis_measurement_checkpoint_value(
      saved.measurement,
      configuration,
    ),
    "runs": footprint_run_checkpoint_json(saved.runs),
  })
}

///|
pub fn FootprintRunAnalysisReplay::checkpoint_json(
  self : FootprintRunAnalysisReplay,
) -> String raise @types.GroundError {
  let result = footprint_run_analysis_checkpoint_value(
    self.session.checkpoint(),
    self.configuration,
  ).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "footprint run analysis checkpoint exceeds 8388608 UTF-16 code units",
    )
  }
  result
}

///|
/// Bounded pure observation replay with complete committed motion and run state.
pub fn footprint_run_analysis_json(
  source : String,
) -> String raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "footprint run analysis request",
  )
  allowed_fields(fields, ["source", "frames"], "footprint run analysis request")
  let replay = FootprintRunAnalysisReplay::open(
    text(required(fields, "source"), "source"),
  )
  let input = text(required(fields, "frames"), "frames")
  if input.length() > 8388608 {
    raise invalid(
      "footprint run analysis frames exceed 8388608 UTF-16 code units",
    )
  }
  let lines = if input.length() == 0 { [] } else { input.split("\n").collect() }
  if input.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5000 {
    raise invalid("footprint run analysis batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut units = 0
  for line in lines {
    let frame = replay.footprint_run_analysis_process_frame(line.to_owned())
    units += frame.stringify().length() + 1
    if units > 8388608 {
      raise invalid(
        "footprint run analysis output exceeds 8388608 UTF-16 code units",
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
      "footprint run analysis output exceeds 8388608 UTF-16 code units",
    )
  }
  result
}

///|
/// A read-only candidate at the supplied complete source, without a handle.
pub fn footprint_run_preview_json(
  source : String,
) -> String raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "footprint run preview request",
  )
  allowed_fields(fields, ["source", "frame"], "footprint run preview request")
  let replay = FootprintRunAnalysisReplay::open(
    text(required(fields, "source"), "source"),
  )
  replay.preview_line(text(required(fields, "frame"), "frame"))
}
