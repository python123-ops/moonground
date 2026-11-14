///|
/// Pure disk-footprint interpretation of the original position configuration.
pub struct DiskZoneEvidenceReplay {
  priv position : ZoneEvidenceReplay
  priv footprint : @zones.DiskFootprint
}

///|
pub fn DiskZoneEvidenceReplay::open(
  source : String,
) -> DiskZoneEvidenceReplay raise @types.GroundError {
  let fields = object(
    parse_document(source),
    "disk zone evidence configuration",
  )
  allowed_fields(
    fields,
    ["position", "disk"],
    "disk zone evidence configuration",
  )
  let position = ZoneEvidenceReplay::open(
    text(required(fields, "position"), "position"),
  )
  let options = object(
    parse_document(text(required(fields, "disk"), "disk")),
    "disk footprint",
  )
  allowed_fields(options, ["radius_m"], "disk footprint")
  {
    position,
    footprint: @zones.DiskFootprint::new(
      number(required(options, "radius_m"), "radius_m"),
    ),
  }
}

///|
fn disk_zone_row_fields(row : @zones.DiskZoneEvidence) -> Map[String, Json] {
  let band = row.evidence
  {
    "track_id": Json(row.track_id),
    "segment_id": Json(row.segment_id),
    "zone_id": Json(band.zone_id),
    "radius_m": Json(band.radius_m),
    "sigma_multiplier": Json(band.sigma_multiplier),
    "decision": Json(
      match band.decision {
        @zones.Inside => "inside"
        @zones.Outside => "outside"
        @zones.Indeterminate => "indeterminate"
      },
    ),
    "separating_edge_index": match band.separating_edge_index {
      Some(value) => Json(value)
      None => Json::null()
    },
    "faces": Json(
      band.faces.map(face => {
        Json::object({
          "edge_index": Json(face.edge_index),
          "outward_normal": Json([
            Json(face.outward_normal.x),
            Json(face.outward_normal.y),
          ]),
          "distance_m": Json(face.distance_m),
          "normal_std_m": Json(face.normal_std_m),
          "position_lower_m": Json(face.position_lower_m),
          "position_upper_m": Json(face.position_upper_m),
          "lower_m": Json(face.lower_m),
          "upper_m": Json(face.upper_m),
        })
      }),
    ),
  }
}

///|
fn disk_zone_frame_json(frame : @zones.DiskZoneEvidenceFrame) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("disk_zone_evidence_frame"),
    "evidence_scope": Json("model_position_halfplane_bands_plus_explicit_disk"),
    "session_id": Json(frame.session_id),
    "timestamp_us": Json(frame.timestamp_us.to_string()),
    "evidence": Json(
      frame.evidence.map(row => Json::object(disk_zone_row_fields(row))),
    ),
    "unavailable": Json(frame.unavailable.map(zone_unavailable_json)),
  })
}

///|
fn DiskZoneEvidenceReplay::disk_zone_process_frame(
  self : DiskZoneEvidenceReplay,
  source : String,
) -> Json raise @types.GroundError {
  let max_tracks = self.position.max_tracks
  let frame = self.position.projector.evaluate_disk(
    gate_measurement(source, max_tracks),
    self.footprint,
  )
  // The original measurement parser validates every rejected projection first.
  let fields = object(parse_document(source), "measurement frame")
  for
    value in array(required(fields, "tracks"), "measurement tracks", max_tracks) {
    let fields = object(value, "measurement track")
    if fields.get("status") is Some(String("rejected_projection")) {
      frame.unavailable.push({
        track_id: positive_int(required(fields, "track_id"), "track_id"),
        segment_id: None,
        reason: @zones.RejectedProjection,
      })
    }
  }
  frame.unavailable.sort_by((a, b) => a.track_id.compare(b.track_id))
  disk_zone_frame_json(frame)
}

///|
pub fn DiskZoneEvidenceReplay::process_line(
  self : DiskZoneEvidenceReplay,
  source : String,
) -> String raise @types.GroundError {
  self.disk_zone_process_frame(source).stringify()
}

///|
/// Bounded stateless batch; errors expose no partial result or checkpoint.
pub fn disk_zone_evidence_json(
  source : String,
) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid(
      "disk zone evidence request exceeds 16777216 UTF-16 code units",
    )
  }
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "disk zone evidence request",
  )
  allowed_fields(
    fields,
    ["source", "measurements"],
    "disk zone evidence request",
  )
  let replay = DiskZoneEvidenceReplay::open(
    text(required(fields, "source"), "source"),
  )
  let measurements = text(required(fields, "measurements"), "measurements")
  if measurements.length() > 8388608 {
    raise invalid(
      "disk zone evidence measurements exceed 8388608 UTF-16 code units",
    )
  }
  let lines = if measurements.length() == 0 {
    []
  } else {
    measurements.split("\n").collect()
  }
  if measurements.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5000 {
    raise invalid("disk zone evidence batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut length = 0
  for line in lines {
    let frame = replay.disk_zone_process_frame(line.to_owned())
    length += frame.stringify().length() + 1
    if length > 8388608 {
      raise invalid(
        "disk zone evidence output exceeds 8388608 UTF-16 code units",
      )
    }
    frames.push(frame)
  }
  let result = Json::object({ "frames": Json(frames) }).stringify()
  if result.length() > 8388608 {
    raise invalid("disk zone evidence output exceeds 8388608 UTF-16 code units")
  }
  result
}
