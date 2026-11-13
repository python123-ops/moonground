///|
/// One owner of raw measurements, covariance-confirmed transits and exact
/// confirmation windows. Complete restoration binds their saved histories.
pub struct EvidenceTransitWindowAnalysisReplay {
  priv session : @analysis.EvidenceTransitWindowSession
  priv configuration : Json
  priv diagnostics : Bool
  priv max_tracks : Int32
  priv pixel : Bool
  priv sigma_multiplier : Double
}

///|
fn transit_window_analysis_replay(
  analysis : EvidenceTransitAnalysisReplay,
  session : @analysis.EvidenceTransitWindowSession,
) -> EvidenceTransitWindowAnalysisReplay {
  {
    session,
    configuration: analysis.configuration,
    diagnostics: analysis.diagnostics,
    max_tracks: analysis.max_tracks,
    pixel: analysis.pixel,
    sigma_multiplier: analysis.sigma_multiplier,
  }
}

///|
fn joined_evidence_transit_window_analysis(
  analysis : EvidenceTransitAnalysisReplay,
  windows : String,
) -> EvidenceTransitWindowAnalysisReplay raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(windows, max_units=8388619),
    "joint transit window configuration",
  )
  let session = if fields.contains("resume") {
    let windows = EvidenceTransitWindowReplay::open(windows)
    @analysis.EvidenceTransitWindowSession::from_checkpoint({
      version: 1,
      analysis: analysis.session.checkpoint(),
      windows: windows.counter.checkpoint(),
    })
  } else {
    if windows.length() > 1048576 {
      raise invalid(
        "joint transit window configuration exceeds 1048576 UTF-16 code units",
      )
    }
    allowed_fields(
      fields,
      ["window_us", "duration_limits_us", "origin_us"],
      "joint transit window configuration",
    )
    @analysis.EvidenceTransitWindowSession::new(
      analysis.session,
      window_us=timestamp(required(fields, "window_us"), "window_us"),
      duration_limits_us=window_limits(required(fields, "duration_limits_us")),
      origin_us=match fields.get("origin_us") {
        Some(value) => timestamp(value, "origin_us")
        None => 0L
      },
    )
  }
  transit_window_analysis_replay(analysis, session)
}

///|
fn restore_evidence_transit_window_analysis(
  value : Json,
) -> EvidenceTransitWindowAnalysisReplay raise @types.GroundError {
  let fields = object(value, "evidence transit window analysis checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "analysis", "windows"],
    "evidence transit window analysis checkpoint",
  )
  if text(required(fields, "format"), "format") !=
    "moonground.evidence-transit-window-analysis" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid(
      "unsupported evidence transit window analysis checkpoint format or version",
    )
  }
  let analysis = restore_evidence_transit_analysis(required(fields, "analysis"))
  let windows = window_restore_checkpoint(required(fields, "windows"))
  transit_window_analysis_replay(
    analysis,
    @analysis.EvidenceTransitWindowSession::from_checkpoint({
      version: 1,
      analysis: analysis.session.checkpoint(),
      windows: windows.checkpoint(),
    }),
  )
}

///|
/// Preserve both source documents as raw strings until their strict parsers run.
pub fn EvidenceTransitWindowAnalysisReplay::open(
  source : String,
) -> EvidenceTransitWindowAnalysisReplay raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=8388619),
    "evidence transit window analysis source",
  )
  if fields.get("resume") is Some(saved) {
    allowed_fields(
      fields,
      ["resume"],
      "evidence transit window analysis resume",
    )
    if saved.stringify().length() > 8388608 {
      raise invalid(
        "evidence transit window analysis checkpoint exceeds 8388608 UTF-16 code units",
      )
    }
    restore_evidence_transit_window_analysis(saved)
  } else {
    allowed_fields(
      fields,
      ["analysis", "windows"],
      "evidence transit window analysis source",
    )
    joined_evidence_transit_window_analysis(
      EvidenceTransitAnalysisReplay::open(
        text(required(fields, "analysis"), "analysis"),
      ),
      text(required(fields, "windows"), "windows"),
    )
  }
}

///|
fn evidence_transit_window_analysis_frame_json(
  frame : @analysis.EvidenceTransitWindowSessionFrame,
  diagnostics : Bool,
  sigma_multiplier : Double,
) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("evidence_transit_window_analysis_frame"),
    "analysis": evidence_transit_analysis_frame_json(
      frame.analysis,
      diagnostics,
      sigma_multiplier,
    ),
    "windows": window_frame_json(frame.windows),
  })
}

///|
fn EvidenceTransitWindowAnalysisReplay::evidence_transit_window_analysis_process_frame(
  self : EvidenceTransitWindowAnalysisReplay,
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
  evidence_transit_window_analysis_frame_json(
    result,
    self.diagnostics,
    self.sigma_multiplier,
  )
}

///|
/// Each successful raw frame advances measurement, transit and windows once.
pub fn EvidenceTransitWindowAnalysisReplay::process_line(
  self : EvidenceTransitWindowAnalysisReplay,
  source : String,
) -> String raise @types.GroundError {
  self.evidence_transit_window_analysis_process_frame(source).stringify()
}

///|
fn evidence_transit_window_analysis_checkpoint_value(
  saved : @analysis.EvidenceTransitWindowSessionCheckpoint,
  configuration : Json,
) -> Json raise @types.GroundError {
  Json::object({
    "format": Json("moonground.evidence-transit-window-analysis"),
    "checkpoint_version": Json("1"),
    "analysis": evidence_transit_analysis_checkpoint_value(
      saved.analysis,
      configuration,
    ),
    "windows": window_checkpoint_value(saved.windows),
  })
}

///|
pub fn EvidenceTransitWindowAnalysisReplay::checkpoint_json(
  self : EvidenceTransitWindowAnalysisReplay,
) -> String raise @types.GroundError {
  let result = evidence_transit_window_analysis_checkpoint_value(
    self.session.checkpoint(),
    self.configuration,
  ).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "evidence transit window analysis checkpoint exceeds 8388608 UTF-16 code units",
    )
  }
  result
}

///|
/// Pure bounded replay without persistent handles or failed-batch prefixes.
pub fn evidence_transit_window_analysis_json(
  source : String,
) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid(
      "evidence transit window analysis request exceeds 16777216 UTF-16 code units",
    )
  }
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "evidence transit window analysis request",
  )
  allowed_fields(
    fields,
    ["source", "observations"],
    "evidence transit window analysis request",
  )
  let replay = EvidenceTransitWindowAnalysisReplay::open(
    text(required(fields, "source"), "source"),
  )
  let observations = text(required(fields, "observations"), "observations")
  if observations.length() > 8388608 {
    raise invalid(
      "evidence transit window analysis observations exceed 8388608 UTF-16 code units",
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
    raise invalid("evidence transit window analysis batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut output_length = 0
  for line in lines {
    let frame = replay.evidence_transit_window_analysis_process_frame(
      line.to_owned(),
    )
    output_length += frame.stringify().length() + 1
    if output_length > 8388608 {
      raise invalid(
        "evidence transit window analysis output exceeds 8388608 UTF-16 code units",
      )
    }
    frames.push(frame)
  }
  let output = Json::object({
    "frames": Json(frames),
    "checkpoint": parse_checkpoint_document(replay.checkpoint_json()),
  }).stringify()
  if output.length() > 8388608 {
    raise invalid(
      "evidence transit window analysis output exceeds 8388608 UTF-16 code units",
    )
  }
  output
}
