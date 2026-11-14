///|
/// Bounded current-position ellipse intersection, without a clock owner.
pub struct ZoneIntersectionReplay {
  priv projector : @zones.ZoneProjector
  priv max_tracks : Int32
}

///|
pub fn ZoneIntersectionReplay::open(
  source : String,
) -> ZoneIntersectionReplay raise @types.GroundError {
  let (session_id, zones, max_tracks) = zone_configuration_parts(source)
  {
    projector: @zones.ZoneProjector::new(session_id, zones, max_tracks~),
    max_tracks,
  }
}

///|
fn zone_intersection_frame_json(
  frame : @zones.PositionZoneIntersectionFrame,
) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("position_zone_intersection_frame"),
    "evidence_scope": Json("model_position_ellipse_convex_zone_intersection"),
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
          "minimum_quadratic_lower": Json(band.minimum_quadratic_lower),
          "minimum_quadratic_upper": Json(band.minimum_quadratic_upper),
          "witness_edge_index": match band.witness_edge_index {
            Some(value) => Json(value)
            None => Json::null()
          },
          "witness_fraction": match band.witness_fraction {
            Some(value) => Json(value)
            None => Json::null()
          },
          "witness_position_m": Json([
            Json(band.witness_position_m.x),
            Json(band.witness_position_m.y),
          ]),
          "decision": Json(
            match band.decision {
              @zones.Disjoint => "disjoint"
              @zones.Intersects => "intersects"
              @zones.Unresolved => "indeterminate"
            },
          ),
        })
      }),
    ),
    "unavailable": Json(frame.unavailable.map(zone_unavailable_json)),
  })
}

///|
fn ZoneIntersectionReplay::intersection_process_frame(
  self : ZoneIntersectionReplay,
  source : String,
) -> Json raise @types.GroundError {
  // Validate the original payload, including unavailable projection failures.
  let frame = self.projector.intersect_position(
    gate_measurement(source, self.max_tracks),
  )
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
  zone_intersection_frame_json(frame)
}

///|
/// Repetition and inter-frame reordering are independent evaluations.
pub fn ZoneIntersectionReplay::process_line(
  self : ZoneIntersectionReplay,
  source : String,
) -> String raise @types.GroundError {
  self.intersection_process_frame(source).stringify()
}

///|
/// Bounded pure batch; errors return no partial result and allocate no handle.
pub fn zone_intersection_json(
  source : String,
) -> String raise @types.GroundError {
  if source.length() > 16777216 {
    raise invalid(
      "zone intersection request exceeds 16777216 UTF-16 code units",
    )
  }
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "zone intersection request",
  )
  allowed_fields(
    fields,
    ["source", "measurements"],
    "zone intersection request",
  )
  let replay = ZoneIntersectionReplay::open(
    text(required(fields, "source"), "source"),
  )
  let measurements = text(required(fields, "measurements"), "measurements")
  if measurements.length() > 8388608 {
    raise invalid(
      "zone intersection measurements exceed 8388608 UTF-16 code units",
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
    raise invalid("zone intersection batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut length = 0
  for line in lines {
    let frame = replay.intersection_process_frame(line.to_owned())
    length += frame.stringify().length() + 1
    if length > 8388608 {
      raise invalid(
        "zone intersection output exceeds 8388608 UTF-16 code units",
      )
    }
    frames.push(frame)
  }
  let result = Json::object({ "frames": Json(frames) }).stringify()
  if result.length() > 8388608 {
    raise invalid("zone intersection output exceeds 8388608 UTF-16 code units")
  }
  result
}
