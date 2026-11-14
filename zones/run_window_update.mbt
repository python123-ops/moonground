///|
/// Compute genuine run outcomes on a private branch, then install the monitor
/// and aggregate together. A late statistics failure also preserves run state.
pub fn FootprintRunWindowMonitor::update(
  self : FootprintRunWindowMonitor,
  frame : @motion.FrameResult,
  assignments : FootprintAssignments,
) -> FootprintRunWindowFrame raise @types.GroundError {
  let candidate = self.runs.fork()
  let runs = candidate.update(frame, assignments)
  let timestamp = frame.timestamp_us
  let (start, end) = run_window_bounds(
    timestamp,
    self.window_us,
    self.origin_us,
  )
  let (window, closed, unobserved) = match self.current_window {
    Some(previous) if previous.start_us == start =>
      (
        {
          ..copy_run_window(previous),
          last_timestamp_us: timestamp,
          input_frames: increment_run_window(previous.input_frames),
        },
        None,
        0L,
      )
    Some(previous) =>
      (
        new_run_window(self.runs, timestamp, start, end),
        Some(copy_run_window(previous)),
        (start - previous.start_us) / self.window_us - 1L,
      )
    None => (new_run_window(self.runs, timestamp, start, end), None, 0L)
  }
  let order : Map[String, Int32] = Map([])
  for index, row in window.zones {
    order[row.zone_id] = index
  }
  for run in runs.active {
    if run.first_timestamp_us == timestamp {
      let index = order[run.zone_id]
      let row = window.zones[index]
      window.zones[index] = {
        ..row,
        started: increment_run_window(row.started),
      }
    }
  }
  for run in runs.confirmed {
    let index = order[run.zone_id]
    let row = window.zones[index]
    window.zones[index] = match run.decision {
      Inside =>
        { ..row, confirmed_inside: increment_run_window(row.confirmed_inside), }
      Outside =>
        {
          ..row,
          confirmed_outside: increment_run_window(row.confirmed_outside),
        }
      Indeterminate =>
        raise @types.InvalidInput("indeterminate footprint run cannot confirm")
    }
  }
  for closed in runs.closed {
    let index = order[closed.run.zone_id]
    let reasons = window.zones[index].endings
    let reason_index = run_window_reason_index(closed.reason)
    let count = reasons[reason_index]
    reasons[reason_index] = if closed.run.confirmed {
      { ..count, confirmed: increment_run_window(count.confirmed), }
    } else {
      { ..count, unconfirmed: increment_run_window(count.unconfirmed), }
    }
  }
  self.runs = candidate
  self.current_window = Some(window)
  {
    runs,
    statistics: {
      session_id: frame.session_id,
      timestamp_us: timestamp,
      closed_window: closed,
      current_window: copy_run_window(window),
      unobserved_windows: unobserved,
    },
  }
}
