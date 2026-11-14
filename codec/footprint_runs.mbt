///|
/// Stateful confirmation of same-shape, current-frame evidence samples.
/// The monitor does not own or restore upstream motion estimation.
pub struct FootprintRunReplay {
  priv monitor : @zones.FootprintRunMonitor
  priv max_tracks : Int32
}

///|
fn footprint_run_config(
  value : Json,
) -> @zones.FootprintRunConfig raise @types.GroundError {
  let fields = object(value, "footprint run options")
  allowed_fields(
    fields,
    ["max_gap_us", "confirmation_us", "min_samples"],
    "footprint run options",
  )
  @zones.FootprintRunConfig::new(
    max_gap_us=match fields.get("max_gap_us") {
      Some(value) => timestamp(value, "max_gap_us")
      None => 500000L
    },
    confirmation_us=match fields.get("confirmation_us") {
      Some(value) => timestamp(value, "confirmation_us")
      None => 1000000L
    },
    min_samples=match fields.get("min_samples") {
      Some(value) => timestamp(value, "min_samples")
      None => 2L
    },
  )
}

///|
fn footprint_run_config_json(config : @zones.FootprintRunConfig) -> Json {
  Json::object({
    "max_gap_us": Json(config.max_gap_us.to_string()),
    "confirmation_us": Json(config.confirmation_us.to_string()),
    "min_samples": Json(config.min_samples.to_string()),
  })
}

///|
fn footprint_run_shape_json(shape : @zones.FootprintShape) -> Json {
  match shape {
    @zones.Disk(disk) =>
      Json::object({ "kind": Json("disk"), "radius_m": Json(disk.radius_m) })
    @zones.Convex(body) =>
      Json::object({
        "kind": Json("convex"),
        "vertices_offset_m": Json(body.vertices_offset_m().map(point_json)),
      })
  }
}

///|
fn footprint_run_json(run : @zones.FootprintRun) -> Json {
  Json::object({
    "zone_id": Json(run.zone_id),
    "track_id": Json(run.track_id),
    "segment_id": Json(run.segment_id),
    "decision": Json(
      match run.decision {
        @zones.Inside => "inside"
        @zones.Outside => "outside"
        @zones.Indeterminate => "indeterminate"
      },
    ),
    "first_timestamp_us": Json(run.first_timestamp_us.to_string()),
    "last_timestamp_us": Json(run.last_timestamp_us.to_string()),
    "sample_count": Json(run.sample_count.to_string()),
    "sample_span_us": Json(run.sample_span_us.to_string()),
    "confirmed": Json(run.confirmed),
  })
}

///|
fn footprint_run_value(
  value : Json,
) -> @zones.FootprintRun raise @types.GroundError {
  let fields = object(value, "footprint run")
  allowed_fields(
    fields,
    [
      "zone_id", "track_id", "segment_id", "decision", "first_timestamp_us", "last_timestamp_us",
      "sample_count", "sample_span_us", "confirmed",
    ],
    "footprint run",
  )
  let confirmed = match required(fields, "confirmed") {
    True => true
    False => false
    _ => raise invalid("run confirmed must be a boolean")
  }
  {
    zone_id: text(required(fields, "zone_id"), "zone_id"),
    track_id: positive_int(required(fields, "track_id"), "track_id"),
    segment_id: text(required(fields, "segment_id"), "segment_id"),
    decision: match text(required(fields, "decision"), "run decision") {
      "inside" => @zones.Inside
      "outside" => @zones.Outside
      _ => raise invalid("run decision must be inside or outside")
    },
    first_timestamp_us: timestamp(
      required(fields, "first_timestamp_us"),
      "first_timestamp_us",
    ),
    last_timestamp_us: timestamp(
      required(fields, "last_timestamp_us"),
      "last_timestamp_us",
    ),
    sample_count: timestamp(required(fields, "sample_count"), "sample_count"),
    sample_span_us: timestamp(
      required(fields, "sample_span_us"),
      "sample_span_us",
    ),
    confirmed,
  }
}

///|
fn footprint_run_checkpoint_value(
  value : Json,
) -> @zones.FootprintRunCheckpoint raise @types.GroundError {
  let fields = object(value, "footprint run checkpoint")
  allowed_fields(
    fields,
    [
      "schema_version", "kind", "version", "session_id", "zones", "max_tracks", "config",
      "last_timestamp_us", "states",
    ],
    "footprint run checkpoint",
  )
  if text(required(fields, "schema_version"), "schema_version") != "0.1.0" ||
    text(required(fields, "kind"), "kind") != "footprint_run_checkpoint" ||
    positive_int(required(fields, "version"), "version") != 1 {
    raise invalid("unsupported footprint run checkpoint version")
  }
  let zones = array(required(fields, "zones"), "zones", 16).map(value => {
    let fields = object(value, "checkpoint zone")
    allowed_fields(
      fields,
      ["zone_id", "vertices_m", "sigma_multiplier"],
      "checkpoint zone",
    )
    @zones.ConvexZone::new(
      text(required(fields, "zone_id"), "zone_id"),
      array(required(fields, "vertices_m"), "vertices_m", 32).map(value => {
        point(value, "zone vertex")
      }),
      sigma_multiplier=number(
        required(fields, "sigma_multiplier"),
        "sigma_multiplier",
      ),
    )
  })
  let max_tracks = positive_int(required(fields, "max_tracks"), "max_tracks")
  // Bound multiplication before allocating or reconstructing all saved states.
  if max_tracks > 10000 {
    raise invalid("checkpoint track capacity exceeds 10000")
  }
  let config_fields = object(
    required(fields, "config"),
    "checkpoint run config",
  )
  for name in ["max_gap_us", "confirmation_us", "min_samples"] {
    ignore(required(config_fields, name))
  }
  let states : Array[@zones.FootprintRunState] = array(
    required(fields, "states"),
    "footprint run states",
    max_tracks * zones.length(),
  ).map(value => {
    let fields = object(value, "footprint run state")
    allowed_fields(
      fields,
      ["run", "shape", "last_position_m", "last_position_covariance"],
      "footprint run state",
    )
    {
      run: footprint_run_value(required(fields, "run")),
      shape: assigned_shape(required(fields, "shape")),
      last_position_m: point(
        required(fields, "last_position_m"),
        "last_position_m",
      ),
      last_position_covariance: covariance(
        required(fields, "last_position_covariance"),
      ),
    }
  })
  {
    version: 1,
    session_id: text(required(fields, "session_id"), "session_id"),
    zones,
    max_tracks,
    config: footprint_run_config(Json::object(config_fields)),
    last_timestamp_us: match required(fields, "last_timestamp_us") {
      Null => None
      value => Some(timestamp(value, "last_timestamp_us"))
    },
    states,
  }
}

///|
fn footprint_run_checkpoint_json(
  checkpoint : @zones.FootprintRunCheckpoint,
) -> Json {
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("footprint_run_checkpoint"),
    "version": Json(1),
    "session_id": Json(checkpoint.session_id),
    "zones": Json(
      checkpoint.zones.map(zone => {
        Json::object({
          "zone_id": Json(zone.zone_id),
          "vertices_m": Json(zone.vertices_m().map(point_json)),
          "sigma_multiplier": Json(zone.sigma_multiplier),
        })
      }),
    ),
    "max_tracks": Json(checkpoint.max_tracks),
    "config": footprint_run_config_json(checkpoint.config),
    "last_timestamp_us": match checkpoint.last_timestamp_us {
      Some(time) => Json(time.to_string())
      None => Json::null()
    },
    "states": Json(
      checkpoint.states.map(state => {
        Json::object({
          "run": footprint_run_json(state.run),
          "shape": footprint_run_shape_json(state.shape),
          "last_position_m": point_json(state.last_position_m),
          "last_position_covariance": covariance_json(
            state.last_position_covariance,
          ),
        })
      }),
    ),
  })
}

///|
pub fn FootprintRunReplay::open(
  source : String,
) -> FootprintRunReplay raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=8388619),
    "footprint run source",
  )
  if fields.contains("resume") {
    allowed_fields(fields, ["resume"], "footprint run source")
    let checkpoint = required(fields, "resume")
    if checkpoint.stringify().length() > 8388608 {
      raise invalid(
        "footprint run checkpoint exceeds 8388608 UTF-16 code units",
      )
    }
    let checkpoint = footprint_run_checkpoint_value(checkpoint)
    {
      monitor: @zones.FootprintRunMonitor::from_checkpoint(checkpoint),
      max_tracks: checkpoint.max_tracks,
    }
  } else {
    // Configs have the original 1Mi limit, independently of resume capacity.
    ignore(parse_document(source))
    allowed_fields(fields, ["position", "options"], "footprint run source")
    let (session_id, zones, max_tracks) = zone_configuration_parts(
      text(required(fields, "position"), "position"),
    )
    let config = footprint_run_config(
      parse_document(text(required(fields, "options"), "options")),
    )
    {
      monitor: @zones.FootprintRunMonitor::new(
        session_id,
        zones,
        config,
        max_tracks~,
      ),
      max_tracks,
    }
  }
}

///|
fn footprint_run_reason(reason : @zones.FootprintRunEndReason) -> String {
  match reason {
    @zones.GapExceeded => "gap_exceeded"
    @zones.SegmentClosed => "segment_closed"
    @zones.SegmentChanged => "segment_changed"
    @zones.MissingTarget => "missing_target"
    @zones.UnavailableEvidence => "unavailable_evidence"
    @zones.ShapeChanged => "shape_changed"
    @zones.IndeterminateEvidence => "indeterminate_evidence"
    @zones.DecisionChanged => "decision_changed"
  }
}

///|
fn FootprintRunReplay::run_process_frame(
  self : FootprintRunReplay,
  source : String,
) -> Json raise @types.GroundError {
  let fields = object(parse_document(source), "footprint run frame")
  allowed_fields(fields, ["measurement", "assignments"], "footprint run frame")
  let measurement_source = text(required(fields, "measurement"), "measurement")
  let measurement = gate_measurement(measurement_source, self.max_tracks)
  let assignments = assigned_footprints(
    text(required(fields, "assignments"), "assignments"),
    self.max_tracks,
  )
  let result = self.monitor.update(measurement, assignments)
  let original = object(parse_document(measurement_source), "measurement frame")
  for
    value in array(
      required(original, "tracks"),
      "measurement tracks",
      self.max_tracks,
    ) {
    let track = object(value, "measurement track")
    if track.get("status") is Some(String("rejected_projection")) {
      result.evidence.unavailable.push({
        track_id: positive_int(required(track, "track_id"), "track_id"),
        segment_id: None,
        reason: @zones.Position(@zones.RejectedProjection),
      })
    }
  }
  result.evidence.unavailable.sort_by((a, b) => a.track_id.compare(b.track_id))
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("footprint_run_frame"),
    "evidence_scope": Json("current_target_footprint_confirmed_sample_runs"),
    "evidence": assigned_zone_frame_json(result.evidence),
    "active": Json(result.active.map(footprint_run_json)),
    "confirmed": Json(result.confirmed.map(footprint_run_json)),
    "closed": Json(
      result.closed.map(closed => {
        Json::object({
          "run": footprint_run_json(closed.run),
          "closed_at_timestamp_us": Json(
            closed.closed_at_timestamp_us.to_string(),
          ),
          "reason": Json(footprint_run_reason(closed.reason)),
        })
      }),
    ),
  })
}

///|
pub fn FootprintRunReplay::process_line(
  self : FootprintRunReplay,
  source : String,
) -> String raise @types.GroundError {
  self.run_process_frame(source).stringify()
}

///|
pub fn FootprintRunReplay::checkpoint_json(
  self : FootprintRunReplay,
) -> String raise @types.GroundError {
  let result = footprint_run_checkpoint_json(self.monitor.checkpoint()).stringify()
  if result.length() > 8388608 {
    raise invalid("footprint run checkpoint exceeds 8388608 UTF-16 code units")
  }
  result
}

///|
/// Bounded pure replay including the complete downstream checkpoint.
pub fn footprint_runs_json(source : String) -> String raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "footprint runs request",
  )
  allowed_fields(fields, ["source", "frames"], "footprint runs request")
  let replay = FootprintRunReplay::open(
    text(required(fields, "source"), "source"),
  )
  let input = text(required(fields, "frames"), "frames")
  if input.length() > 8388608 {
    raise invalid("footprint run frames exceed 8388608 UTF-16 code units")
  }
  let lines = if input.length() == 0 { [] } else { input.split("\n").collect() }
  if input.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5000 {
    raise invalid("footprint run batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut units = 0
  for line in lines {
    let frame = replay.run_process_frame(line.to_owned())
    units += frame.stringify().length() + 1
    if units > 8388608 {
      raise invalid("footprint run output exceeds 8388608 UTF-16 code units")
    }
    frames.push(frame)
  }
  let result = Json::object({
    "frames": Json(frames),
    "checkpoint": parse_checkpoint_document(replay.checkpoint_json()),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("footprint run output exceeds 8388608 UTF-16 code units")
  }
  result
}
