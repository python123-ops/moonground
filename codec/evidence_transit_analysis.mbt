///|
/// One transactional owner of raw observations and evidence-confirmed passages.
pub struct EvidenceTransitAnalysisReplay {
  priv session : @analysis.EvidenceTransitSession
  priv configuration : Json
  priv diagnostics : Bool
  priv max_tracks : Int32
  priv pixel : Bool
  priv sigma_multiplier : Double
}

///|
fn joined_evidence_transit_analysis(
  measurement : ReplaySession,
  transit : @transit.EvidenceTransitCounter,
) -> EvidenceTransitAnalysisReplay raise @types.GroundError {
  let (session, pixel) = match (measurement.pixel, measurement.ground) {
    (Some(pixel), None) =>
      (@analysis.EvidenceTransitSession::from_pixel(pixel, transit), true)
    (None, Some(ground)) =>
      (@analysis.EvidenceTransitSession::from_ground(ground, transit), false)
    _ => raise invalid("invalid evidence transit analysis measurement mode")
  }
  {
    session,
    configuration: measurement.configuration,
    diagnostics: measurement.diagnostics,
    max_tracks: measurement.max_tracks,
    pixel,
    sigma_multiplier: transit.checkpoint().counting.sigma_multiplier,
  }
}

///|
fn restore_evidence_transit_analysis(
  value : Json,
) -> EvidenceTransitAnalysisReplay raise @types.GroundError {
  let fields = object(value, "evidence transit analysis checkpoint")
  allowed_fields(
    fields,
    ["format", "checkpoint_version", "measurement", "transit"],
    "evidence transit analysis checkpoint",
  )
  if text(required(fields, "format"), "format") !=
    "moonground.evidence-transit-analysis" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid(
      "unsupported evidence transit analysis checkpoint format or version",
    )
  }
  joined_evidence_transit_analysis(
    restore_checkpoint(required(fields, "measurement")),
    restore_evidence_transit_checkpoint(required(fields, "transit")),
  )
}

///|
/// Raw inner strings preserve integer tokens, duplicate keys and exact times.
pub fn EvidenceTransitAnalysisReplay::open(
  source : String,
) -> EvidenceTransitAnalysisReplay raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=8388619),
    "evidence transit analysis source",
  )
  if fields.get("resume") is Some(saved) {
    allowed_fields(fields, ["resume"], "evidence transit analysis resume")
    if saved.stringify().length() > 8388608 {
      raise invalid(
        "evidence transit analysis checkpoint exceeds 8388608 UTF-16 code units",
      )
    }
    restore_evidence_transit_analysis(saved)
  } else {
    allowed_fields(
      fields,
      ["measurement", "transit"],
      "evidence transit analysis source",
    )
    joined_evidence_transit_analysis(
      ReplaySession::open(text(required(fields, "measurement"), "measurement")),
      EvidenceTransitReplay::open(text(required(fields, "transit"), "transit")).counter,
    )
  }
}

///|
fn EvidenceTransitAnalysisReplay::evidence_transit_analysis_process_frame(
  self : EvidenceTransitAnalysisReplay,
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
  evidence_transit_analysis_frame_json(
    result,
    self.diagnostics,
    self.sigma_multiplier,
  )
}

///|
fn evidence_transit_analysis_frame_json(
  result : @analysis.EvidenceTransitSessionFrame,
  diagnostics : Bool,
  sigma_multiplier : Double,
) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("evidence_transit_analysis_frame"),
    "measurement": measurement_json(
      result.measurement.motion,
      result.measurement.projection_failures,
      diagnostics,
    ),
    "transit": evidence_transit_frame_json(result.transit, sigma_multiplier),
  })
}

///|
/// A transit failure preserves motion, evidence, pending entries and segment allocation.
pub fn EvidenceTransitAnalysisReplay::process_line(
  self : EvidenceTransitAnalysisReplay,
  source : String,
) -> String raise @types.GroundError {
  self.evidence_transit_analysis_process_frame(source).stringify()
}

///|
pub fn EvidenceTransitAnalysisReplay::checkpoint_json(
  self : EvidenceTransitAnalysisReplay,
) -> String raise @types.GroundError {
  let result = evidence_transit_analysis_checkpoint_value(
    self.session.checkpoint(),
    self.configuration,
  ).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "evidence transit analysis checkpoint exceeds 8388608 UTF-16 code units",
    )
  }
  result
}

///|
fn evidence_transit_analysis_checkpoint_value(
  saved : @analysis.EvidenceTransitSessionCheckpoint,
  configuration : Json,
) -> Json raise @types.GroundError {
  Json::object({
    "format": Json("moonground.evidence-transit-analysis"),
    "checkpoint_version": Json("1"),
    "measurement": analysis_measurement_checkpoint_value(
      saved.measurement,
      configuration,
    ),
    "transit": evidence_transit_checkpoint_value(saved.transit),
  })
}

///|
/// Pure bounded replay of observations. Failed batches expose no partial state.
pub fn evidence_transit_analysis_json(
  source : String,
) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid(
      "evidence transit analysis request exceeds 16777216 UTF-16 code units",
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
        "invalid evidence transit analysis request JSON: " + error.to_string(),
      )
  }
  let fields = object(value, "evidence transit analysis request")
  allowed_fields(
    fields,
    ["source", "observations"],
    "evidence transit analysis request",
  )
  let replay = EvidenceTransitAnalysisReplay::open(
    text(required(fields, "source"), "source"),
  )
  let observations = text(required(fields, "observations"), "observations")
  if observations.length() > 8388608 {
    raise invalid(
      "evidence transit analysis observations exceed 8388608 UTF-16 code units",
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
    raise invalid("evidence transit analysis batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut output_length = 0
  for line in lines {
    let frame = replay.evidence_transit_analysis_process_frame(line.to_owned())
    output_length += frame.stringify().length() + 1
    if output_length > 8388608 {
      raise invalid(
        "evidence transit analysis output exceeds 8388608 UTF-16 code units",
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
      "evidence transit analysis output exceeds 8388608 UTF-16 code units",
    )
  }
  result
}
