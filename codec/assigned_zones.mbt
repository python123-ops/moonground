///|
/// Independent frame-bound explicit shapes; no assignment map is retained.
pub struct AssignedZoneEvidenceReplay {
  priv position : ZoneEvidenceReplay
}

///|
pub fn AssignedZoneEvidenceReplay::open(
  source : String,
) -> AssignedZoneEvidenceReplay raise @types.GroundError {
  { position: ZoneEvidenceReplay::open(source), }
}

///|
fn assigned_shape(
  value : Json,
) -> @zones.FootprintShape raise @types.GroundError {
  let fields = object(value, "assigned footprint shape")
  match text(required(fields, "kind"), "shape kind") {
    "disk" => {
      allowed_fields(fields, ["kind", "radius_m"], "assigned disk shape")
      @zones.Disk(
        @zones.DiskFootprint::new(
          number(required(fields, "radius_m"), "radius_m"),
        ),
      )
    }
    "convex" => {
      allowed_fields(
        fields,
        ["kind", "vertices_offset_m"],
        "assigned convex shape",
      )
      @zones.Convex(
        @zones.ConvexFootprint::new(
          array(required(fields, "vertices_offset_m"), "vertices_offset_m", 32).map(value => {
              point(value, "assigned footprint vertex offset")
            },
          ),
        ),
      )
    }
    _ => raise invalid("assigned footprint kind must be disk or convex")
  }
}

///|
fn assigned_footprints(
  source : String,
  max_tracks : Int32,
) -> @zones.FootprintAssignments raise @types.GroundError {
  let fields = object(parse_document(source), "footprint assignments")
  allowed_fields(
    fields,
    ["timestamp_us", "footprints"],
    "footprint assignments",
  )
  @zones.FootprintAssignments::new(
    timestamp(required(fields, "timestamp_us"), "assignment timestamp_us"),
    array(required(fields, "footprints"), "footprint assignments", max_tracks).map(value => {
        let fields = object(value, "target footprint assignment")
        allowed_fields(
          fields,
          ["track_id", "segment_id", "shape"],
          "target footprint assignment",
        )
        @zones.FootprintAssignment::new(
          positive_int(required(fields, "track_id"), "track_id"),
          text(required(fields, "segment_id"), "segment_id"),
          assigned_shape(required(fields, "shape")),
        )
      },
    ),
  )
}

///|
fn assigned_disk_face_json(
  face : @zones.DiskZoneFaceBand,
  radius : Double,
) -> Json {
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
    "footprint_lower_m": Json(-radius),
    "footprint_upper_m": Json(radius),
    "lower_m": Json(face.lower_m),
    "upper_m": Json(face.upper_m),
  })
}

///|
fn assigned_zone_row_json(row : @zones.AssignedFootprintEvidence) -> Json {
  let fields = match row.evidence {
    @zones.Disk(band) => {
      let fields = disk_zone_row_fields({
        track_id: row.track_id,
        segment_id: row.segment_id,
        evidence: band,
      })
      fields["shape_kind"] = Json("disk")
      fields["faces"] = Json(
        band.faces.map(face => assigned_disk_face_json(face, band.radius_m)),
      )
      fields
    }
    @zones.Convex(band) => {
      let fields = footprint_zone_row_fields({
        track_id: row.track_id,
        segment_id: row.segment_id,
        evidence: band,
      })
      fields["shape_kind"] = Json("convex")
      fields
    }
  }
  Json::object(fields)
}

///|
fn assigned_unavailable_json(row : @zones.AssignedFootprintUnavailable) -> Json {
  match row.reason {
    @zones.Position(reason) =>
      zone_unavailable_json({
        track_id: row.track_id,
        segment_id: row.segment_id,
        reason,
      })
    @zones.MissingFootprint =>
      Json::object({
        "track_id": Json(row.track_id),
        "segment_id": match row.segment_id {
          Some(value) => Json(value)
          None => Json::null()
        },
        "reason": Json("missing_footprint"),
      })
  }
}

///|
fn AssignedZoneEvidenceReplay::assigned_process_frame(
  self : AssignedZoneEvidenceReplay,
  source : String,
) -> Json raise @types.GroundError {
  let fields = object(parse_document(source), "assigned zone frame")
  allowed_fields(fields, ["measurement", "assignments"], "assigned zone frame")
  let measurement_source = text(required(fields, "measurement"), "measurement")
  let max_tracks = self.position.max_tracks
  // Original parser validates the entire measurement, including projection rows.
  let measurement = gate_measurement(measurement_source, max_tracks)
  let assignments = assigned_footprints(
    text(required(fields, "assignments"), "assignments"),
    max_tracks,
  )
  let frame = self.position.projector.evaluate_assigned(
    measurement, assignments,
  )
  let fields = object(parse_document(measurement_source), "measurement frame")
  for
    value in array(required(fields, "tracks"), "measurement tracks", max_tracks) {
    let fields = object(value, "measurement track")
    if fields.get("status") is Some(String("rejected_projection")) {
      frame.unavailable.push({
        track_id: positive_int(required(fields, "track_id"), "track_id"),
        segment_id: None,
        reason: @zones.Position(@zones.RejectedProjection),
      })
    }
  }
  frame.unavailable.sort_by((a, b) => a.track_id.compare(b.track_id))
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("assigned_zone_evidence_frame"),
    "evidence_scope": Json(
      "model_position_halfplane_bands_plus_current_target_footprints",
    ),
    "session_id": Json(frame.session_id),
    "timestamp_us": Json(frame.timestamp_us.to_string()),
    "evidence": Json(frame.evidence.map(assigned_zone_row_json)),
    "unavailable": Json(frame.unavailable.map(assigned_unavailable_json)),
  })
}

///|
pub fn AssignedZoneEvidenceReplay::process_line(
  self : AssignedZoneEvidenceReplay,
  source : String,
) -> String raise @types.GroundError {
  self.assigned_process_frame(source).stringify()
}

///|
/// Whole-batch errors return no partial result, clock or shape history.
pub fn assigned_zone_evidence_json(
  source : String,
) -> String raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "assigned zone request",
  )
  allowed_fields(fields, ["source", "frames"], "assigned zone request")
  let replay = AssignedZoneEvidenceReplay::open(
    text(required(fields, "source"), "source"),
  )
  let frames_source = text(required(fields, "frames"), "frames")
  if frames_source.length() > 8388608 {
    raise invalid("assigned zone frames exceed 8388608 UTF-16 code units")
  }
  let lines = if frames_source.length() == 0 {
    []
  } else {
    frames_source.split("\n").collect()
  }
  if frames_source.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5000 {
    raise invalid("assigned zone batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut length = 0
  for line in lines {
    let frame = replay.assigned_process_frame(line.to_owned())
    length += frame.stringify().length() + 1
    if length > 8388608 {
      raise invalid("assigned zone output exceeds 8388608 UTF-16 code units")
    }
    frames.push(frame)
  }
  let result = Json::object({ "frames": Json(frames) }).stringify()
  if result.length() > 8388608 {
    raise invalid("assigned zone output exceeds 8388608 UTF-16 code units")
  }
  result
}
