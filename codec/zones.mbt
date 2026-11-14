///|
/// Independent current-position covariance evidence, without a clock owner.
pub struct ZoneEvidenceReplay {
  priv projector : @zones.ZoneProjector
  priv max_tracks : Int32
}

///|
pub fn ZoneEvidenceReplay::open(
  source : String,
) -> ZoneEvidenceReplay raise @types.GroundError {
  let fields = object(parse_document(source), "zone evidence configuration")
  allowed_fields(
    fields,
    ["session_id", "zones", "max_tracks"],
    "zone evidence configuration",
  )
  let zones = array(required(fields, "zones"), "zones", 16).map(value => {
    let fields = object(value, "convex zone")
    allowed_fields(
      fields,
      ["zone_id", "vertices_m", "sigma_multiplier"],
      "convex zone",
    )
    @zones.ConvexZone::new(
      text(required(fields, "zone_id"), "zone_id"),
      array(required(fields, "vertices_m"), "vertices_m", 32).map(value => {
        point(value, "zone vertex")
      }),
      sigma_multiplier=match fields.get("sigma_multiplier") {
        Some(value) => number(value, "sigma_multiplier")
        None => 2.0
      },
    )
  })
  let max_tracks = match fields.get("max_tracks") {
    Some(value) => positive_int(value, "max_tracks")
    None => 1000
  }
  {
    projector: @zones.ZoneProjector::new(
      text(required(fields, "session_id"), "session_id"),
      zones,
      max_tracks~,
    ),
    max_tracks,
  }
}

///|
fn zone_unavailable_json(row : @zones.ZoneUnavailable) -> Json {
  Json::object({
    "track_id": Json(row.track_id),
    "segment_id": match row.segment_id {
      Some(value) => Json(value)
      None => Json::null()
    },
    "reason": Json(
      match row.reason {
        @zones.Initializing => "initializing"
        @zones.Uncertain => "uncertain"
        @zones.RejectedInnovation => "rejected_innovation"
        @zones.NumericalFailure => "numerical_failure"
        @zones.RejectedProjection => "rejected_projection"
      },
    ),
  })
}

///|
fn zone_frame_json(frame : @zones.ZoneEvidenceFrame) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("zone_evidence_frame"),
    "evidence_scope": Json("model_position_halfplane_bands"),
    "session_id": Json(frame.session_id),
    "timestamp_us": Json(frame.timestamp_us.to_string()),
    "evidence": Json(
      frame.evidence.map(row => {
        let band = row.evidence
        Json::object({
          "track_id": Json(row.track_id),
          "segment_id": Json(row.segment_id),
          "zone_id": Json(band.zone_id),
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
                "lower_m": Json(face.lower_m),
                "upper_m": Json(face.upper_m),
              })
            }),
          ),
        })
      }),
    ),
    "unavailable": Json(frame.unavailable.map(zone_unavailable_json)),
  })
}

///|
fn ZoneEvidenceReplay::zone_process_frame(
  self : ZoneEvidenceReplay,
  source : String,
) -> Json raise @types.GroundError {
  // Validate the original payload, including unavailable projection failures.
  let frame = self.projector.evaluate(gate_measurement(source, self.max_tracks))
  let fields = object(parse_document(source), "measurement frame")
  for
    value in array(
      required(fields, "tracks"),
      "measurement tracks",
      self.max_tracks,
    ) {
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
  zone_frame_json(frame)
}

///|
/// Repetition and inter-frame reordering are independent evaluations.
pub fn ZoneEvidenceReplay::process_line(
  self : ZoneEvidenceReplay,
  source : String,
) -> String raise @types.GroundError {
  self.zone_process_frame(source).stringify()
}

///|
/// Bounded pure batch; errors return no partial result and allocate no handle.
pub fn zone_evidence_json(source : String) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid("zone evidence request exceeds 16777216 UTF-16 code units")
  }
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "zone evidence request",
  )
  allowed_fields(fields, ["source", "measurements"], "zone evidence request")
  let replay = ZoneEvidenceReplay::open(
    text(required(fields, "source"), "source"),
  )
  let measurements = text(required(fields, "measurements"), "measurements")
  if measurements.length() > 8388608 {
    raise invalid("zone evidence measurements exceed 8388608 UTF-16 code units")
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
    raise invalid("zone evidence batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut length = 0
  for line in lines {
    let frame = replay.zone_process_frame(line.to_owned())
    length += frame.stringify().length() + 1
    if length > 8388608 {
      raise invalid("zone evidence output exceeds 8388608 UTF-16 code units")
    }
    frames.push(frame)
  }
  let result = Json::object({ "frames": Json(frames) }).stringify()
  if result.length() > 8388608 {
    raise invalid("zone evidence output exceeds 8388608 UTF-16 code units")
  }
  result
}
