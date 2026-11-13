///|
fn window_increment(value : Int64) -> Int64 raise @types.GroundError {
  if value == 9223372036854775807L {
    raise @types.InvalidInput("transit window counter exhausted")
  }
  value + 1L
}

///|
fn window_reason_index(reason : CancellationReason) -> Int32 {
  match reason {
    Discontinuity => 0
    Expired => 1
    Reentered => 2
    Reversed => 3
    AmbiguousOrder => 4
  }
}

///|
/// Reduce all supplied outcomes into one confirmation-time bucket atomically.
/// Rollover emits only the previous observed bucket; skipped buckets are
/// unobserved, never synthesized as zero traffic or healthy exposure.
pub fn EvidenceTransitWindowCounter::update(
  self : EvidenceTransitWindowCounter,
  frame : EvidenceTransitFrame,
) -> EvidenceTransitWindowFrame raise @types.GroundError {
  self.validate_window_input(frame)
  let timestamp = frame.counting.counting.timestamp_us
  let (start, _) = window_bounds(timestamp, self.origin_us, self.window_us)
  let (candidate, closed, skipped) = match self.current_window {
    Some(previous) if previous.start_us == start =>
      (copy_window(previous), None, 0L)
    Some(previous) =>
      (
        empty_window(
          self.sections,
          self.duration_limits_us,
          timestamp,
          self.origin_us,
          self.window_us,
        ),
        Some(copy_window(previous)),
        (start - previous.start_us) / self.window_us - 1L,
      )
    None =>
      (
        empty_window(
          self.sections,
          self.duration_limits_us,
          timestamp,
          self.origin_us,
          self.window_us,
        ),
        None,
        0L,
      )
  }
  for value in frame.passages {
    let index = window_section_index(self.sections, value.section_id)
    let section = candidate.sections[index]
    let completed = window_increment(section.completed)
    for limit_index, row in section.duration_limits {
      section.duration_limits[limit_index] = if value.elapsed_upper_us <=
        row.limit_us {
        { ..row, within: window_increment(row.within), }
      } else if value.elapsed_lower_us > row.limit_us {
        { ..row, exceeded: window_increment(row.exceeded), }
      } else {
        { ..row, indeterminate: window_increment(row.indeterminate), }
      }
    }
    candidate.sections[index] = { ..section, completed, }
  }
  for value in frame.cancellations {
    let index = window_section_index(self.sections, value.section_id)
    let reason = window_reason_index(value.reason)
    let row = candidate.sections[index].cancellations[reason]
    candidate.sections[index].cancellations[reason] = {
      ..row,
      count: window_increment(row.count),
    }
  }
  let current = {
    ..candidate,
    input_frames: window_increment(candidate.input_frames),
    last_timestamp_us: timestamp,
  }
  self.last_timestamp_us = Some(timestamp)
  self.counts = frame.counts.copy()
  self.current_window = Some(current)
  {
    session_id: self.session_id,
    timestamp_us: timestamp,
    closed_window: closed,
    current_window: copy_window(current),
    unobserved_windows: skipped,
  }
}
