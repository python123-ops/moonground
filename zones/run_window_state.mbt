///|
fn run_window_reasons() -> Array[FootprintRunEndReason] {
  [
    GapExceeded,
    SegmentClosed,
    SegmentChanged,
    MissingTarget,
    UnavailableEvidence,
    ShapeChanged,
    IndeterminateEvidence,
    DecisionChanged,
  ]
}

///|
fn run_window_reason_index(reason : FootprintRunEndReason) -> Int32 {
  match reason {
    GapExceeded => 0
    SegmentClosed => 1
    SegmentChanged => 2
    MissingTarget => 3
    UnavailableEvidence => 4
    ShapeChanged => 5
    IndeterminateEvidence => 6
    DecisionChanged => 7
  }
}

///|
fn copy_run_window(window : FootprintRunWindow) -> FootprintRunWindow {
  {
    ..window,
    zones: window.zones.map(zone => { ..zone, endings: zone.endings.copy(), }),
  }
}

///|
fn validate_run_window_options(
  width : Int64,
  origin : Int64,
) -> Unit raise @types.GroundError {
  if width <= 0L || origin < 0L {
    raise @types.InvalidInput("footprint run window width or origin is invalid")
  }
}

///|
fn run_window_bounds(
  timestamp : Int64,
  width : Int64,
  origin : Int64,
) -> (Int64, Int64?) raise @types.GroundError {
  if timestamp < origin {
    raise @types.InvalidInput("footprint run window input precedes its origin")
  }
  let start = timestamp - (timestamp - origin) % width
  let end = if width <= 9223372036854775807L - start {
    Some(start + width)
  } else {
    None
  }
  (start, end)
}

///|
fn increment_run_window(value : Int64) -> Int64 raise @types.GroundError {
  if value == 9223372036854775807L {
    raise @types.InvalidInput("footprint run window count overflows Int64")
  }
  value + 1L
}

///|
pub fn FootprintRunWindowMonitor::new(
  monitor : FootprintRunMonitor,
  window_us~ : Int64,
  origin_us~ : Int64 = 0L,
) -> FootprintRunWindowMonitor raise @types.GroundError {
  validate_run_window_options(window_us, origin_us)
  let runs = FootprintRunMonitor::from_checkpoint(monitor.checkpoint())
  if runs.last_timestamp is Some(time) && time < origin_us {
    raise @types.InvalidInput(
      "footprint run window baseline precedes its origin",
    )
  }
  {
    runs,
    window_us,
    origin_us,
    baseline_timestamp_us: runs.last_timestamp,
    current_window: None,
  }
}

///|
pub fn FootprintRunWindowMonitor::checkpoint(
  self : FootprintRunWindowMonitor,
) -> FootprintRunWindowCheckpoint {
  {
    version: 1,
    runs: self.runs.checkpoint(),
    window_us: self.window_us,
    origin_us: self.origin_us,
    baseline_timestamp_us: self.baseline_timestamp_us,
    current_window: self.current_window.map(copy_run_window),
  }
}

///|
pub fn FootprintRunWindowMonitor::fork(
  self : FootprintRunWindowMonitor,
) -> FootprintRunWindowMonitor {
  {
    runs: self.runs.fork(),
    window_us: self.window_us,
    origin_us: self.origin_us,
    baseline_timestamp_us: self.baseline_timestamp_us,
    current_window: self.current_window.map(copy_run_window),
  }
}

///|
fn new_run_window(
  monitor : FootprintRunMonitor,
  timestamp : Int64,
  start : Int64,
  end : Int64?,
) -> FootprintRunWindow {
  let order : Map[String, Int32] = Map([])
  let zones : Array[FootprintRunWindowZone] = Array::makei(
    monitor.projector.zones.length(),
    index => {
      let zone = monitor.projector.zones[index]
      order[zone.zone_id] = index
      {
        zone_id: zone.zone_id,
        opening_active: 0L,
        opening_confirmed: 0L,
        started: 0L,
        confirmed_inside: 0L,
        confirmed_outside: 0L,
        endings: run_window_reasons().map(reason => {
          reason,
          confirmed: 0L,
          unconfirmed: 0L,
        }),
      }
    },
  )
  for state in monitor.states {
    let index = order[state.run.zone_id]
    let row = zones[index]
    zones[index] = {
      ..row,
      opening_active: row.opening_active + 1L,
      opening_confirmed: row.opening_confirmed +
      (if state.run.confirmed { 1L } else { 0L }),
    }
  }
  {
    start_us: start,
    end_exclusive_us: end,
    first_timestamp_us: timestamp,
    last_timestamp_us: timestamp,
    input_frames: 1L,
    zones,
  }
}
