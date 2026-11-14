///|
/// Owns the original visual run monitor and its current outcome bucket.
pub struct FootprintRunWindowReplay {
  priv monitor : @zones.FootprintRunWindowMonitor
  priv max_tracks : Int32
}

///|
fn footprint_run_end_reason_value(
  value : Json,
) -> @zones.FootprintRunEndReason raise @types.GroundError {
  match text(value, "footprint run ending reason") {
    "gap_exceeded" => @zones.GapExceeded
    "segment_closed" => @zones.SegmentClosed
    "segment_changed" => @zones.SegmentChanged
    "missing_target" => @zones.MissingTarget
    "unavailable_evidence" => @zones.UnavailableEvidence
    "shape_changed" => @zones.ShapeChanged
    "indeterminate_evidence" => @zones.IndeterminateEvidence
    "decision_changed" => @zones.DecisionChanged
    _ => raise invalid("unknown footprint run ending reason")
  }
}

///|
fn footprint_run_window_json(value : @zones.FootprintRunWindow) -> Json {
  Json::object({
    "start_us": Json(value.start_us.to_string()),
    "end_exclusive_us": window_optional_time(value.end_exclusive_us),
    "first_timestamp_us": Json(value.first_timestamp_us.to_string()),
    "last_timestamp_us": Json(value.last_timestamp_us.to_string()),
    "input_frames": Json(value.input_frames.to_string()),
    "zones": Json(
      value.zones.map(zone => {
        Json::object({
          "zone_id": Json(zone.zone_id),
          "opening_active": Json(zone.opening_active.to_string()),
          "opening_confirmed": Json(zone.opening_confirmed.to_string()),
          "started": Json(zone.started.to_string()),
          "confirmed_inside": Json(zone.confirmed_inside.to_string()),
          "confirmed_outside": Json(zone.confirmed_outside.to_string()),
          "endings": Json(
            zone.endings.map(row => {
              Json::object({
                "reason": Json(footprint_run_reason(row.reason)),
                "confirmed": Json(row.confirmed.to_string()),
                "unconfirmed": Json(row.unconfirmed.to_string()),
              })
            }),
          ),
        })
      }),
    ),
  })
}

///|
fn footprint_run_window_value(
  value : Json,
) -> @zones.FootprintRunWindow raise @types.GroundError {
  let fields = object(value, "footprint run window")
  allowed_fields(
    fields,
    [
      "start_us", "end_exclusive_us", "first_timestamp_us", "last_timestamp_us",
      "input_frames", "zones",
    ],
    "footprint run window",
  )
  {
    start_us: timestamp(required(fields, "start_us"), "start_us"),
    end_exclusive_us: window_time_option(
      required(fields, "end_exclusive_us"),
      "end_exclusive_us",
    ),
    first_timestamp_us: timestamp(
      required(fields, "first_timestamp_us"),
      "first_timestamp_us",
    ),
    last_timestamp_us: timestamp(
      required(fields, "last_timestamp_us"),
      "last_timestamp_us",
    ),
    input_frames: timestamp(required(fields, "input_frames"), "input_frames"),
    zones: array(required(fields, "zones"), "window zones", 16).map(value => {
      let fields = object(value, "window zone")
      allowed_fields(
        fields,
        [
          "zone_id", "opening_active", "opening_confirmed", "started", "confirmed_inside",
          "confirmed_outside", "endings",
        ],
        "window zone",
      )
      @zones.FootprintRunWindowZone::{
        zone_id: text(required(fields, "zone_id"), "zone_id"),
        opening_active: timestamp(
          required(fields, "opening_active"),
          "opening_active",
        ),
        opening_confirmed: timestamp(
          required(fields, "opening_confirmed"),
          "opening_confirmed",
        ),
        started: timestamp(required(fields, "started"), "started"),
        confirmed_inside: timestamp(
          required(fields, "confirmed_inside"),
          "confirmed_inside",
        ),
        confirmed_outside: timestamp(
          required(fields, "confirmed_outside"),
          "confirmed_outside",
        ),
        endings: array(required(fields, "endings"), "window endings", 8).map(value => {
          let fields = object(value, "window ending count")
          allowed_fields(
            fields,
            ["reason", "confirmed", "unconfirmed"],
            "window ending count",
          )
          @zones.FootprintRunWindowEndCount::{
            reason: footprint_run_end_reason_value(required(fields, "reason")),
            confirmed: timestamp(required(fields, "confirmed"), "confirmed"),
            unconfirmed: timestamp(
              required(fields, "unconfirmed"),
              "unconfirmed",
            ),
          }
        }),
      }
    }),
  }
}

///|
fn restore_footprint_run_windows(
  value : Json,
) -> FootprintRunWindowReplay raise @types.GroundError {
  let fields = object(value, "footprint run windows checkpoint")
  allowed_fields(
    fields,
    [
      "format", "checkpoint_version", "runs", "window_us", "origin_us", "baseline_timestamp_us",
      "current_window",
    ],
    "footprint run windows checkpoint",
  )
  if text(required(fields, "format"), "format") !=
    "moonground.footprint-run-windows" ||
    text(required(fields, "checkpoint_version"), "checkpoint_version") != "1" {
    raise invalid(
      "unsupported footprint run windows checkpoint format or version",
    )
  }
  let runs = footprint_run_checkpoint_value(required(fields, "runs"))
  let monitor = @zones.FootprintRunWindowMonitor::from_checkpoint({
    version: 1,
    runs,
    window_us: timestamp(required(fields, "window_us"), "window_us"),
    origin_us: timestamp(required(fields, "origin_us"), "origin_us"),
    baseline_timestamp_us: window_time_option(
      required(fields, "baseline_timestamp_us"),
      "baseline_timestamp_us",
    ),
    current_window: match required(fields, "current_window") {
      Null => None
      value => Some(footprint_run_window_value(value))
    },
  })
  { monitor, max_tracks: runs.max_tracks, }
}

///|
pub fn FootprintRunWindowReplay::open(
  source : String,
) -> FootprintRunWindowReplay raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=8388619),
    "footprint run windows source",
  )
  if fields.get("resume") is Some(saved) {
    allowed_fields(fields, ["resume"], "footprint run windows resume")
    if saved.stringify().length() > 8388608 {
      raise invalid(
        "footprint run windows checkpoint exceeds 8388608 UTF-16 code units",
      )
    }
    restore_footprint_run_windows(saved)
  } else {
    allowed_fields(fields, ["runs", "window"], "footprint run windows source")
    let runs = FootprintRunReplay::open(text(required(fields, "runs"), "runs"))
    let window = object(
      parse_document(text(required(fields, "window"), "window")),
      "footprint run window options",
    )
    allowed_fields(
      window,
      ["window_us", "origin_us"],
      "footprint run window options",
    )
    {
      monitor: @zones.FootprintRunWindowMonitor::new(
        runs.monitor,
        window_us=timestamp(required(window, "window_us"), "window_us"),
        origin_us=match window.get("origin_us") {
          Some(value) => timestamp(value, "origin_us")
          None => 0L
        },
      ),
      max_tracks: runs.max_tracks,
    }
  }
}

///|
fn FootprintRunWindowReplay::process_frame(
  self : FootprintRunWindowReplay,
  source : String,
) -> Json raise @types.GroundError {
  let fields = object(parse_document(source), "footprint run windows frame")
  allowed_fields(
    fields,
    ["measurement", "assignments"],
    "footprint run windows frame",
  )
  let raw = text(required(fields, "measurement"), "measurement")
  let measurement = gate_measurement(raw, self.max_tracks)
  let assignments = assigned_footprints(
    text(required(fields, "assignments"), "assignments"),
    self.max_tracks,
  )
  // Validate original projection-failure rows before the owner can commit.
  let unavailable = footprint_run_projection_rows(raw, self.max_tracks)
  let result = self.monitor.update(measurement, assignments)
  for row in unavailable {
    result.runs.evidence.unavailable.push(row)
  }
  result.runs.evidence.unavailable.sort_by((a, b) => {
    a.track_id.compare(b.track_id)
  })
  let stats = result.statistics
  Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("footprint_run_window_frame"),
    "runs": footprint_run_frame_json(result.runs),
    "statistics": Json::object({
      "session_id": Json(stats.session_id),
      "timestamp_us": Json(stats.timestamp_us.to_string()),
      "closed_window": match stats.closed_window {
        Some(value) => footprint_run_window_json(value)
        None => Json::null()
      },
      "current_window": footprint_run_window_json(stats.current_window),
      "unobserved_windows": Json(stats.unobserved_windows.to_string()),
    }),
  })
}

///|
pub fn FootprintRunWindowReplay::process_line(
  self : FootprintRunWindowReplay,
  source : String,
) -> String raise @types.GroundError {
  self.process_frame(source).stringify()
}

///|
pub fn FootprintRunWindowReplay::checkpoint_json(
  self : FootprintRunWindowReplay,
) -> String raise @types.GroundError {
  let saved = self.monitor.checkpoint()
  let output = Json::object({
    "format": Json("moonground.footprint-run-windows"),
    "checkpoint_version": Json("1"),
    "runs": footprint_run_checkpoint_json(saved.runs),
    "window_us": Json(saved.window_us.to_string()),
    "origin_us": Json(saved.origin_us.to_string()),
    "baseline_timestamp_us": window_optional_time(saved.baseline_timestamp_us),
    "current_window": match saved.current_window {
      Some(value) => footprint_run_window_json(value)
      None => Json::null()
    },
  }).stringify()
  if output.length() > 8388608 {
    raise invalid(
      "footprint run windows checkpoint exceeds 8388608 UTF-16 code units",
    )
  }
  output
}

///|
/// Pure bounded visual outcome replay with its complete original monitor state.
pub fn footprint_run_windows_json(
  source : String,
) -> String raise @types.GroundError {
  let fields = object(
    parse_checkpoint_document(source, max_units=16777216),
    "footprint run windows request",
  )
  allowed_fields(fields, ["source", "frames"], "footprint run windows request")
  let replay = FootprintRunWindowReplay::open(
    text(required(fields, "source"), "source"),
  )
  let input = text(required(fields, "frames"), "frames")
  if input.length() > 8388608 {
    raise invalid(
      "footprint run windows frames exceed 8388608 UTF-16 code units",
    )
  }
  let lines = if input.length() == 0 { [] } else { input.split("\n").collect() }
  if input.has_suffix("\n") {
    ignore(lines.pop())
  }
  if lines.length() > 5000 {
    raise invalid("footprint run windows batch exceeds 5000 frames")
  }
  let frames : Array[Json] = []
  let mut units = 0
  for line in lines {
    let frame = replay.process_frame(line.to_owned())
    units += frame.stringify().length() + 1
    if units > 8388608 {
      raise invalid(
        "footprint run windows output exceeds 8388608 UTF-16 code units",
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
      "footprint run windows output exceeds 8388608 UTF-16 code units",
    )
  }
  output
}
