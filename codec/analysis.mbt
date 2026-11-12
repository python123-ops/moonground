///|
/// A single transactional owner of measured motion and directional gate state.
/// Existing measurement and event JSON remain nested, with their own versions.
pub struct AnalysisReplay {
  priv session : @analysis.AnalysisSession
  priv configuration : Json
  priv diagnostics : Bool
  priv max_tracks : Int32
  priv pixel : Bool
}

///|
fn joined_analysis(
  measurement : ReplaySession,
  counting : GateReplay,
) -> AnalysisReplay raise @types.GroundError {
  let (session, pixel) = match (measurement.pixel, measurement.ground) {
    (Some(pixel), None) =>
      (@analysis.AnalysisSession::from_pixel(pixel, counting.counter), true)
    (None, Some(ground)) =>
      (@analysis.AnalysisSession::from_ground(ground, counting.counter), false)
    _ => raise invalid("invalid analysis measurement mode")
  }
  {
    session,
    configuration: measurement.configuration,
    diagnostics: measurement.diagnostics,
    max_tracks: measurement.max_tracks,
    pixel,
  }
}

///|
fn restore_analysis(value : Json) -> AnalysisReplay raise @types.GroundError {
  let fields = object(value, "analysis checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "measurement", "counting"],
    "analysis checkpoint",
  )
  if text(required(fields, "format"), "format") != "moonground.analysis" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid("unsupported analysis checkpoint format or version")
  }
  joined_analysis(
    restore_checkpoint(required(fields, "measurement")),
    new_gate_replay(restore_gate_checkpoint(required(fields, "counting"))),
  )
}

///|
/// Open raw {measurement: "configuration_or_resume", counting: "gate_source"}
/// or one {resume: analysis_checkpoint}. Inner strings retain exact JSON tokens.
pub fn AnalysisReplay::open(
  source : String,
) -> AnalysisReplay raise @types.GroundError {
  let value = parse_checkpoint_document(source, max_units=8388619)
  let fields = object(value, "analysis source")
  if fields.get("resume") is Some(saved) {
    allowed_fields(fields, ["resume"], "analysis resume envelope")
    if saved.stringify().length() > 8388608 {
      raise invalid("analysis checkpoint exceeds 8388608 UTF-16 code units")
    }
    restore_analysis(saved)
  } else {
    allowed_fields(fields, ["measurement", "counting"], "analysis source")
    joined_analysis(
      ReplaySession::open(text(required(fields, "measurement"), "measurement")),
      GateReplay::open(text(required(fields, "counting"), "counting")),
    )
  }
}

///|
fn AnalysisReplay::analysis_process_frame(
  self : AnalysisReplay,
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
  analysis_frame_json(result, self.diagnostics)
}

///|
fn analysis_frame_json(
  result : @analysis.AnalysisFrame,
  diagnostics : Bool,
) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("analysis_frame"),
    "measurement": measurement_json(
      result.measurement.motion,
      result.measurement.projection_failures,
      diagnostics,
    ),
    "counting": gate_frame_json(result.counting),
  })
}

///|
/// A gate failure also leaves measurement time, state and segment IDs reusable.
pub fn AnalysisReplay::process_line(
  self : AnalysisReplay,
  source : String,
) -> String raise @types.GroundError {
  self.analysis_process_frame(source).stringify()
}

///|
/// Export both validated states at the same processed frame watermark.
fn analysis_checkpoint_value(
  saved : @analysis.AnalysisCheckpoint,
  configuration : Json,
) -> Json raise @types.GroundError {
  let motion = match saved.measurement {
    @analysis.Pixel(pixel) => pixel.motion
    @analysis.Ground(ground) => ground
  }
  if motion.tracks.length() > 10000 {
    raise invalid("measurement checkpoint exceeds 10000 active tracks")
  }
  Json::object({
    "format": Json("moonground.analysis"),
    "checkpoint_version": Json("1"),
    "measurement": Json::object({
      "format": Json("moonground.session"),
      "checkpoint_version": Json("1"),
      "configuration": configuration,
      "motion": motion_checkpoint_json(motion),
    }),
    "counting": gate_checkpoint_value(saved.counting),
  })
}

///|
/// Export both validated states at the same processed frame watermark.
pub fn AnalysisReplay::checkpoint_json(
  self : AnalysisReplay,
) -> String raise @types.GroundError {
  let result = analysis_checkpoint_value(
    self.session.checkpoint(),
    self.configuration,
  ).stringify()
  if result.length() > 8388608 {
    raise invalid("analysis checkpoint exceeds 8388608 UTF-16 code units")
  }
  result
}

///|
/// Pure bounded analysis of raw observation text. No persistent handle is used;
/// a failed batch returns no frames or checkpoint.
pub fn analysis_json(source : String) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid("analysis request exceeds 16777216 UTF-16 code units")
  }
  let value = @json.parse(
    source,
    max_nesting_depth=32,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error =>
      raise invalid("invalid analysis request JSON: " + error.to_string())
  }
  let fields = object(value, "analysis request")
  allowed_fields(fields, ["source", "observations"], "analysis request")
  let replay = AnalysisReplay::open(text(required(fields, "source"), "source"))
  let observations = text(required(fields, "observations"), "observations")
  if observations.length() > 8388608 {
    raise invalid("analysis observations exceed 8388608 UTF-16 code units")
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
    raise invalid("analysis batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut output_length = 0
  for line in lines {
    let frame = replay.analysis_process_frame(line.to_owned())
    output_length += frame.stringify().length() + 1
    if output_length > 8388608 {
      raise invalid("analysis output exceeds 8388608 UTF-16 code units")
    }
    frames.push(frame)
  }
  let result = Json::object({
    "frames": Json(frames),
    "checkpoint": parse_checkpoint_document(replay.checkpoint_json()),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("analysis output exceeds 8388608 UTF-16 code units")
  }
  result
}
