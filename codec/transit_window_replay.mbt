///|
/// Standalone bounded statistics over original covariance-confirmed transit
/// results. Upstream state and external persistence remain caller-owned.
pub struct EvidenceTransitWindowReplay {
  priv counter : @transit.EvidenceTransitWindowCounter
  priv max_tracks : Int32
  priv sigma_multiplier : Double
}

///|
pub fn EvidenceTransitWindowReplay::open(
  source : String,
) -> EvidenceTransitWindowReplay raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=8388619),
    "transit windows source",
  )
  let counter = if fields.get("resume") is Some(value) {
    allowed_fields(fields, ["resume"], "transit windows resume")
    if value.stringify().length() > 8388608 {
      raise invalid(
        "transit windows checkpoint exceeds 8388608 UTF-16 code units",
      )
    }
    window_restore_checkpoint(value)
  } else {
    allowed_fields(
      fields,
      ["transit", "window_us", "origin_us", "duration_limits_us"],
      "transit windows source",
    )
    let upstream = EvidenceTransitReplay::open(
      text(required(fields, "transit"), "transit"),
    )
    @transit.EvidenceTransitWindowCounter::new(
      upstream.counter.checkpoint(),
      window_us=timestamp(required(fields, "window_us"), "window_us"),
      origin_us=match fields.get("origin_us") {
        Some(value) => timestamp(value, "origin_us")
        None => 0L
      },
      duration_limits_us=window_limits(required(fields, "duration_limits_us")),
    )
  }
  let saved = counter.checkpoint()
  {
    counter,
    max_tracks: saved.config.max_tracks,
    sigma_multiplier: saved.sigma_multiplier,
  }
}

///|
fn window_frame_json(frame : @transit.EvidenceTransitWindowFrame) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("evidence_transit_window_frame"),
    "classification_scope": Json("observed_chord_elapsed_bounds"),
    "session_id": Json(frame.session_id),
    "timestamp_us": Json(frame.timestamp_us.to_string()),
    "closed_window": match frame.closed_window {
      Some(window) => window_value(window)
      None => Json::null()
    },
    "current_window": window_value(frame.current_window),
    "unobserved_windows": Json(frame.unobserved_windows.to_string()),
  })
}

///|
fn EvidenceTransitWindowReplay::window_process_frame(
  self : EvidenceTransitWindowReplay,
  source : String,
) -> Json raise @types.GroundError {
  window_frame_json(
    self.counter.update(
      window_source_frame(source, self.max_tracks, self.sigma_multiplier),
    ),
  )
}

///|
/// Preserve all upstream empty and barrier frames. Source/result clocks are
/// exact decimal strings; this does not recompute historical covariance evidence.
pub fn EvidenceTransitWindowReplay::process_line(
  self : EvidenceTransitWindowReplay,
  source : String,
) -> String raise @types.GroundError {
  self.window_process_frame(source).stringify()
}

///|
pub fn EvidenceTransitWindowReplay::checkpoint_json(
  self : EvidenceTransitWindowReplay,
) -> String raise @types.GroundError {
  let output = window_checkpoint_value(self.counter.checkpoint()).stringify()
  if output.length() > 8388608 {
    raise invalid(
      "transit windows checkpoint exceeds 8388608 UTF-16 code units",
    )
  }
  output
}

///|
/// Pure bounded downstream replay. No session handles or partial batch output.
pub fn transit_windows_json(source : String) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid("transit windows request exceeds 16777216 UTF-16 code units")
  }
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "transit windows request",
  )
  allowed_fields(fields, ["source", "transits"], "transit windows request")
  let replay = EvidenceTransitWindowReplay::open(
    text(required(fields, "source"), "source"),
  )
  let transits = text(required(fields, "transits"), "transits")
  if transits.length() > 8388608 {
    raise invalid("transit windows input exceeds 8388608 UTF-16 code units")
  }
  let lines = if transits.length() == 0 {
    []
  } else {
    transits.split("\n").collect()
  }
  if transits.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5000 {
    raise invalid("transit windows batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut output_length = 0
  for line in lines {
    let frame = replay.window_process_frame(line.to_owned())
    output_length += frame.stringify().length() + 1
    if output_length > 8388608 {
      raise invalid("transit windows output exceeds 8388608 UTF-16 code units")
    }
    frames.push(frame)
  }
  let output = Json::object({
    "frames": Json(frames),
    "checkpoint": parse_checkpoint_document(replay.checkpoint_json()),
  }).stringify()
  if output.length() > 8388608 {
    raise invalid("transit windows output exceeds 8388608 UTF-16 code units")
  }
  output
}
