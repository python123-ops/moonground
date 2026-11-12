///|
fn parse_reframe_document(source : String) -> Json raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid("reframing request exceeds 16777216 UTF-16 code units")
  }
  @json.parse(
    source,
    max_nesting_depth=32,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error => raise invalid("invalid reframing JSON: " + error.to_string())
  }
}

///|
fn pixel_transform(
  value : Json,
) -> @types.PixelTransform raise @types.GroundError {
  let fields = object(value, "pixel transform")
  allowed_fields(
    fields,
    ["scale_x", "scale_y", "offset_x", "offset_y"],
    "pixel transform",
  )
  @types.PixelTransform::new(
    scale_x=optional_number(fields, "scale_x", 1.0),
    scale_y=optional_number(fields, "scale_y", 1.0),
    offset_x=optional_number(fields, "offset_x", 0.0),
    offset_y=optional_number(fields, "offset_y", 0.0),
  )
}

///|
fn open_reframe_source(
  value : Json,
) -> (ReplaySession, Bool) raise @types.GroundError {
  let fields = object(value, "source session")
  if fields.get("resume") is Some(checkpoint) {
    allowed_fields(fields, ["resume"], "resume envelope")
    if checkpoint.stringify().length() > 8388608 {
      raise invalid("checkpoint exceeds 8388608 UTF-16 code units")
    }
    (restore_checkpoint(checkpoint), true)
  } else {
    if value.stringify().length() > 1048576 {
      raise invalid("configuration exceeds 1048576 UTF-16 code units")
    }
    (replay_configuration(value), false)
  }
}

///|
fn reframed_replay(
  source : ReplaySession,
  transform : @types.PixelTransform,
) -> ReplaySession raise @types.GroundError {
  guard source.pixel is Some(session) else {
    raise invalid("pixel reframing requires a pixel session")
  }
  let reframed = session.reframed(transform)
  let checkpoint = reframed.checkpoint()
  let fields = object(source.configuration, "configuration").copy()
  let old_calibration = object(required(fields, "calibration"), "calibration")
  let maximum = number(
      required(old_calibration, "max_meters_per_pixel"),
      "max_meters_per_pixel",
    ) /
    transform.scale_x.min(transform.scale_y)
  fields["calibration"] = Json::object({
    "matrix": Json(checkpoint.calibration.matrix()),
    "roi": Json(checkpoint.calibration.roi().map(point_json)),
    "max_meters_per_pixel": Json(maximum),
    // Preserve the effective standard deviation, rather than taking a square
    // root of the stored variance and changing its final rounding.
    "ground_noise_floor_m": required(old_calibration, "ground_noise_floor_m"),
  })
  if checkpoint.camera is Some(camera) {
    fields["camera"] = camera_json(camera)
  }
  {
    pixel: Some(reframed),
    ground: None,
    diagnostics: source.diagnostics,
    max_tracks: source.max_tracks,
    configuration: Json::object(fields),
  }
}

///|
/// Bounded-state NDJSON converter. The source session validates the original
/// lifecycle; conversion never changes ground state, identity or frame time.
pub struct ReplayReframer {
  priv source : ReplaySession
  priv transform : @types.PixelTransform
  priv header : String
}

///|
fn new_reframer(
  source_value : Json,
  transform : @types.PixelTransform,
) -> ReplayReframer raise @types.GroundError {
  let (source, resumed) = open_reframe_source(source_value)
  let target = reframed_replay(source, transform)
  let header = if resumed {
    "{\"resume\":" + target.checkpoint_json() + "}"
  } else {
    let header = target.configuration.stringify()
    if header.length() > 1048576 {
      raise invalid(
        "transformed configuration exceeds 1048576 UTF-16 code units",
      )
    }
    header
  }
  { source, transform, header, }
}

///|
/// Parse {"source": configuration_or_resume, "transform": {...}}. Ground-mode
/// sessions are rejected because their observations already use metres.
pub fn ReplayReframer::new(
  source : String,
) -> ReplayReframer raise @types.GroundError {
  let fields = object(parse_reframe_document(source), "reframing header")
  allowed_fields(fields, ["source", "transform"], "reframing header")
  new_reframer(
    required(fields, "source"),
    pixel_transform(required(fields, "transform")),
  )
}

///|
/// Destination configuration or resume envelope, ready for --stream input.
pub fn ReplayReframer::header_line(self : ReplayReframer) -> String {
  self.header
}

///|
/// Convert one original frame. An error leaves the source frame time reusable.
/// Missing pixel covariance becomes an explicit transformed 2-pixel prior.
pub fn ReplayReframer::process_line(
  self : ReplayReframer,
  source : String,
) -> String raise @types.GroundError {
  let fields = object(parse_document(source), "frame")
  allowed_fields(
    fields,
    ["timestamp_us", "observations", "lost", "removed"],
    "frame",
  )
  let time = timestamp(required(fields, "timestamp_us"), "timestamp_us")
  let observations = array(
    required(fields, "observations"),
    "observations",
    self.source.max_tracks,
  )
  let converted : Array[Json] = []
  for value in observations {
    let fields = object(value, "observation")
    allowed_fields(fields, ["track_id", "point", "covariance"], "observation")
    let identity = positive_int(required(fields, "track_id"), "track_id")
    let position = self.transform.point(
      point(required(fields, "point"), "point"),
    )
    let original = match fields.get("covariance") {
      Some(value) => covariance(value)
      None => @types.Covariance2::isotropic(2.0)
    }
    let covariance = self.transform.covariance(original)
    converted.push(
      Json::object({
        "track_id": Json(identity),
        "point": point_json(position),
        "covariance": covariance_json(covariance),
      }),
    )
  }
  let output = Json::object({
    "timestamp_us": Json(time.to_string()),
    "observations": Json(converted),
    "lost": Json(ids(fields, "lost", self.source.max_tracks)),
    "removed": Json(ids(fields, "removed", self.source.max_tracks)),
  }).stringify()
  if output.length() > 1048576 {
    raise invalid("transformed frame exceeds 1048576 UTF-16 code units")
  }
  // Validate and commit only after every transformed point, covariance and the
  // complete output line have succeeded. Discard measurement output here.
  ignore(self.source.process_line(source))
  output
}

///|
/// Convert a bounded raw NDJSON string atomically, without browser handles.
/// Native callers can use ReplayReframer directly for arbitrarily long streams.
pub fn reframe_json(source : String) -> String raise @types.GroundError {
  let fields = object(parse_reframe_document(source), "reframing request")
  allowed_fields(fields, ["ndjson", "transform"], "reframing request")
  let ndjson = text(required(fields, "ndjson"), "ndjson")
  if ndjson.length() == 0 || ndjson.length() > 8388608 {
    raise invalid(
      "NDJSON input must contain a header and fit 8388608 UTF-16 code units",
    )
  }
  let lines = ndjson.split("\n").collect()
  if ndjson.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5001 {
    raise invalid("browser reframing exceeds 5000 frames")
  }
  let first = parse_checkpoint_document(lines[0].to_owned(), max_units=8388619)
  let converter = new_reframer(
    first,
    pixel_transform(required(fields, "transform")),
  )
  let converted = [converter.header_line()]
  let mut length = converted[0].length() + 1
  if length > 8388608 {
    raise invalid("transformed NDJSON exceeds 8388608 UTF-16 code units")
  }
  for i in 1..<lines.length() {
    let line = converter.process_line(lines[i].to_owned())
    length += line.length() + 1
    if length > 8388608 {
      raise invalid("transformed NDJSON exceeds 8388608 UTF-16 code units")
    }
    converted.push(line)
  }
  Json::object({
    "ndjson": Json(converted.join("\n") + "\n"),
    "frame_count": Json(lines.length() - 1),
  }).stringify()
}
