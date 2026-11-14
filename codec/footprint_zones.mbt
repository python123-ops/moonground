///|
/// Pure convex-footprint interpretation of the original position configuration.
pub struct FootprintZoneEvidenceReplay {
  priv position : ZoneEvidenceReplay
  priv footprint : @zones.ConvexFootprint
}

///|
pub fn FootprintZoneEvidenceReplay::open(
  source : String,
) -> FootprintZoneEvidenceReplay raise @types.GroundError {
  let fields = object(
    parse_document(source),
    "footprint zone evidence configuration",
  )
  allowed_fields(
    fields,
    ["position", "footprint"],
    "footprint zone evidence configuration",
  )
  let position = ZoneEvidenceReplay::open(
    text(required(fields, "position"), "position"),
  )
  let options = object(
    parse_document(text(required(fields, "footprint"), "footprint")),
    "convex footprint",
  )
  allowed_fields(options, ["vertices_offset_m"], "convex footprint")
  {
    position,
    footprint: @zones.ConvexFootprint::new(
      array(required(options, "vertices_offset_m"), "vertices_offset_m", 32).map(value => {
          point(value, "footprint vertex offset")
        },
      ),
    ),
  }
}

///|
fn footprint_zone_row_fields(
  row : @zones.FootprintZoneEvidence,
) -> Map[String, Json] {
  let band = row.evidence
  {
    "track_id": Json(row.track_id),
    "segment_id": Json(row.segment_id),
    "zone_id": Json(band.zone_id),
    "vertices_offset_m": Json(
      band.vertices_offset_m.map(point => Json([Json(point.x), Json(point.y)])),
    ),
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
          "footprint_lower_m": Json(face.footprint_lower_m),
          "footprint_upper_m": Json(face.footprint_upper_m),
          "lower_m": Json(face.lower_m),
          "upper_m": Json(face.upper_m),
        })
      }),
    ),
  }
}

///|
fn footprint_zone_frame_json(frame : @zones.FootprintZoneEvidenceFrame) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("footprint_zone_evidence_frame"),
    "evidence_scope": Json(
      "model_position_halfplane_bands_plus_explicit_convex_footprint",
    ),
    "session_id": Json(frame.session_id),
    "timestamp_us": Json(frame.timestamp_us.to_string()),
    "evidence": Json(
      frame.evidence.map(row => Json::object(footprint_zone_row_fields(row))),
    ),
    "unavailable": Json(frame.unavailable.map(zone_unavailable_json)),
  })
}

///|
fn FootprintZoneEvidenceReplay::footprint_zone_process_frame(
  self : FootprintZoneEvidenceReplay,
  source : String,
) -> Json raise @types.GroundError {
  let max_tracks = self.position.max_tracks
  let frame = self.position.projector.evaluate_footprint(
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
  footprint_zone_frame_json(frame)
}

///|
pub fn FootprintZoneEvidenceReplay::process_line(
  self : FootprintZoneEvidenceReplay,
  source : String,
) -> String raise @types.GroundError {
  self.footprint_zone_process_frame(source).stringify()
}

///|
/// Bounded stateless batch; errors expose no partial result or checkpoint.
pub fn footprint_zone_evidence_json(
  source : String,
) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid(
      "footprint zone evidence request exceeds 16777216 UTF-16 code units",
    )
  }
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "footprint zone evidence request",
  )
  allowed_fields(
    fields,
    ["source", "measurements"],
    "footprint zone evidence request",
  )
  let replay = FootprintZoneEvidenceReplay::open(
    text(required(fields, "source"), "source"),
  )
  let measurements = text(required(fields, "measurements"), "measurements")
  if measurements.length() > 8388608 {
    raise invalid(
      "footprint zone evidence measurements exceed 8388608 UTF-16 code units",
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
    raise invalid("footprint zone evidence batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut length = 0
  for line in lines {
    let frame = replay.footprint_zone_process_frame(line.to_owned())
    length += frame.stringify().length() + 1
    if length > 8388608 {
      raise invalid(
        "footprint zone evidence output exceeds 8388608 UTF-16 code units",
      )
    }
    frames.push(frame)
  }
  let result = Json::object({ "frames": Json(frames) }).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "footprint zone evidence output exceeds 8388608 UTF-16 code units",
    )
  }
  result
}
