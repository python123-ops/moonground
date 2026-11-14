///|
/// One transactional owner of raw motion, exact-bound sample runs and windows.
pub struct FootprintRunWindowAnalysisReplay {
  priv session : @analysis.FootprintRunWindowSession
  priv configuration : Json
  priv diagnostics : Bool
  priv max_tracks : Int32
  priv run_capacity : Int32
  priv pixel : Bool
}

///|
fn footprint_run_window_analysis_replay(
  original : FootprintRunAnalysisReplay,
  session : @analysis.FootprintRunWindowSession,
) -> FootprintRunWindowAnalysisReplay {
  {
    session,
    pixel: original.pixel,
    configuration: original.configuration,
    diagnostics: original.diagnostics,
    max_tracks: original.max_tracks,
    run_capacity: original.run_capacity,
  }
}

///|
fn restore_footprint_run_window_analysis(
  value : Json,
) -> FootprintRunWindowAnalysisReplay raise @types.GroundError {
  let fields = object(value, "footprint run window analysis checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "measurement", "windows"],
    "footprint run window analysis checkpoint",
  )
  if text(required(fields, "format"), "format") !=
    "moonground.footprint-run-window-analysis" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid(
      "unsupported footprint run window analysis checkpoint format or version",
    )
  }
  let measurement = restore_checkpoint(required(fields, "measurement"))
  let windows = restore_footprint_run_windows(required(fields, "windows")).monitor.checkpoint()
  let (saved, pixel) = match (measurement.pixel, measurement.ground) {
    (Some(session), None) => (@analysis.Pixel(session.checkpoint()), true)
    (None, Some(estimator)) => (@analysis.Ground(estimator.checkpoint()), false)
    _ => raise invalid("invalid footprint run window measurement mode")
  }
  {
    session: @analysis.FootprintRunWindowSession::from_checkpoint({
      version: 1,
      measurement: saved,
      windows,
    }),
    pixel,
    configuration: measurement.configuration,
    diagnostics: measurement.diagnostics,
    max_tracks: measurement.max_tracks,
    run_capacity: windows.runs.max_tracks,
  }
}

///|
pub fn FootprintRunWindowAnalysisReplay::open(
  source : String,
) -> FootprintRunWindowAnalysisReplay raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=8388619),
    "footprint run window analysis source",
  )
  if fields.get("resume") is Some(saved) {
    allowed_fields(fields, ["resume"], "footprint run window analysis resume")
    if saved.stringify().length() > 8388608 {
      raise invalid(
        "footprint run window analysis checkpoint exceeds 8388608 UTF-16 code units",
      )
    }
    restore_footprint_run_window_analysis(saved)
  } else {
    allowed_fields(
      fields,
      ["analysis", "window"],
      "footprint run window analysis source",
    )
    let original = FootprintRunAnalysisReplay::open(
      text(required(fields, "analysis"), "analysis"),
    )
    let options = object(
      parse_document(text(required(fields, "window"), "window")),
      "footprint run window options",
    )
    allowed_fields(
      options,
      ["window_us", "origin_us"],
      "footprint run window options",
    )
    footprint_run_window_analysis_replay(
      original,
      @analysis.FootprintRunWindowSession::new(
        original.session,
        window_us=timestamp(required(options, "window_us"), "window_us"),
        origin_us=match options.get("origin_us") {
          Some(value) => timestamp(value, "origin_us")
          None => 0L
        },
      ),
    )
  }
}

///|
fn FootprintRunWindowAnalysisReplay::prepare_observation(
  self : FootprintRunWindowAnalysisReplay,
  source : String,
) -> @analysis.FootprintRunWindowPreparation raise @types.GroundError {
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
fn FootprintRunWindowAnalysisReplay::footprint_run_window_analysis_process_frame(
  self : FootprintRunWindowAnalysisReplay,
  source : String,
) -> Json raise @types.GroundError {
  let fields = object(
    parse_document(source),
    "footprint run window analysis frame",
  )
  allowed_fields(
    fields,
    ["measurement", "assignments"],
    "footprint run window analysis frame",
  )
  let prepared = self.prepare_observation(
    text(required(fields, "measurement"), "measurement"),
  )
  let assignments = assigned_footprints(
    text(required(fields, "assignments"), "assignments"),
    self.run_capacity,
  )
  let result = prepared.commit(assignments)
  footprint_run_window_analysis_frame_json(result, self.diagnostics)
}

///|
fn footprint_run_window_analysis_frame_json(
  result : @analysis.FootprintRunWindowSessionFrame,
  diagnostics : Bool,
) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("footprint_run_window_analysis_frame"),
    "measurement": measurement_json(
      result.measurement.motion,
      result.measurement.projection_failures,
      diagnostics,
    ),
    "windows": footprint_run_window_frame_json(result.windows),
  })
}

///|
pub fn FootprintRunWindowAnalysisReplay::process_line(
  self : FootprintRunWindowAnalysisReplay,
  source : String,
) -> String raise @types.GroundError {
  self.footprint_run_window_analysis_process_frame(source).stringify()
}

///|
/// Repeated previews independently start at the same committed baseline.
/// The returned measurement is not a reservation or a transferable candidate.
pub fn FootprintRunWindowAnalysisReplay::preview_line(
  self : FootprintRunWindowAnalysisReplay,
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
      "footprint run window preview output exceeds 8388608 UTF-16 code units",
    )
  }
  result
}

///|
fn footprint_run_window_analysis_checkpoint_value(
  saved : @analysis.FootprintRunWindowSessionCheckpoint,
  configuration : Json,
) -> Json raise @types.GroundError {
  Json::object({
    "format": Json("moonground.footprint-run-window-analysis"),
    "checkpoint_version": Json("1"),
    "measurement": analysis_measurement_checkpoint_value(
      saved.measurement,
      configuration,
    ),
    "windows": footprint_run_windows_checkpoint_value(saved.windows),
  })
}

///|
pub fn FootprintRunWindowAnalysisReplay::checkpoint_json(
  self : FootprintRunWindowAnalysisReplay,
) -> String raise @types.GroundError {
  let result = footprint_run_window_analysis_checkpoint_value(
    self.session.checkpoint(),
    self.configuration,
  ).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "footprint run window analysis checkpoint exceeds 8388608 UTF-16 code units",
    )
  }
  result
}

///|
/// Bounded pure raw observation replay with complete motion, run and window state.
pub fn footprint_run_window_analysis_json(
  source : String,
) -> String raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "footprint run window analysis request",
  )
  allowed_fields(
    fields,
    ["source", "frames"],
    "footprint run window analysis request",
  )
  let replay = FootprintRunWindowAnalysisReplay::open(
    text(required(fields, "source"), "source"),
  )
  let input = text(required(fields, "frames"), "frames")
  if input.length() > 8388608 {
    raise invalid(
      "footprint run window analysis frames exceed 8388608 UTF-16 code units",
    )
  }
  let lines = if input.length() == 0 { [] } else { input.split("\n").collect() }
  if input.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5000 {
    raise invalid("footprint run window analysis batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut units = 0
  for line in lines {
    let frame = replay.footprint_run_window_analysis_process_frame(
      line.to_owned(),
    )
    units += frame.stringify().length() + 1
    if units > 8388608 {
      raise invalid(
        "footprint run window analysis output exceeds 8388608 UTF-16 code units",
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
      "footprint run window analysis output exceeds 8388608 UTF-16 code units",
    )
  }
  result
}

///|
/// A read-only candidate at the supplied complete source, without a handle.
pub fn footprint_run_window_preview_json(
  source : String,
) -> String raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "footprint run window preview request",
  )
  allowed_fields(
    fields,
    ["source", "frame"],
    "footprint run window preview request",
  )
  let replay = FootprintRunWindowAnalysisReplay::open(
    text(required(fields, "source"), "source"),
  )
  replay.preview_line(text(required(fields, "frame"), "frame"))
}
