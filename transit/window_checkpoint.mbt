///|
fn validate_window_counts(
  counts : Array[TransitCount],
  sections : Array[Section],
) -> Unit raise @types.GroundError {
  if counts.length() != sections.length() {
    raise @types.InvalidInput("transit window completed count shape differs")
  }
  for index, count in counts {
    if count.section_id != sections[index].section_id || count.completed < 0L {
      raise @types.InvalidInput(
        "invalid transit window completed count or order",
      )
    }
  }
}

///|
fn validate_window_frame_capacity(
  count : Int64,
  frames : Int64,
  per_frame : Int32,
) -> Unit raise @types.GroundError {
  let capacity = Int64::from_int(per_frame)
  let quotient = count / capacity
  if quotient > frames || (quotient == frames && count % capacity != 0L) {
    raise @types.InvalidInput(
      "transit window count exceeds its observed frame capacity",
    )
  }
}

///|
fn validate_saved_window(
  window : TransitWindow,
  saved : EvidenceTransitWindowCheckpoint,
  timestamp : Int64,
) -> Unit raise @types.GroundError {
  let (start, end) = window_bounds(timestamp, saved.origin_us, saved.window_us)
  if window.start_us != start ||
    window.end_exclusive_us != end ||
    window.last_timestamp_us != timestamp ||
    window.first_timestamp_us < start ||
    window.first_timestamp_us > timestamp ||
    window.input_frames < 1L ||
    window.input_frames - 1L > timestamp - window.first_timestamp_us ||
    window.sections.length() != saved.sections.length() {
    raise @types.InvalidInput(
      "invalid transit window bounds chronology or shape",
    )
  }
  if saved.baseline_timestamp_us is Some(baseline) &&
    (
      window.first_timestamp_us <= baseline ||
      window.input_frames > timestamp - baseline
    ) {
    raise @types.InvalidInput(
      "transit window samples do not follow their baseline",
    )
  }
  let reasons = cancellation_reasons()
  for index, section in window.sections {
    if section.section_id != saved.sections[index].section_id ||
      section.completed < 0L ||
      section.completed >
      saved.counts[index].completed - saved.baseline_counts[index].completed ||
      section.duration_limits.length() != saved.duration_limits_us.length() ||
      section.cancellations.length() != reasons.length() {
      raise @types.InvalidInput(
        "invalid transit window section totals or shape",
      )
    }
    validate_window_frame_capacity(
      section.completed,
      window.input_frames,
      saved.config.max_tracks,
    )
    for limit_index, row in section.duration_limits {
      if row.limit_us != saved.duration_limits_us[limit_index] ||
        row.within < 0L ||
        row.exceeded < 0L ||
        row.indeterminate < 0L ||
        row.within > section.completed ||
        row.exceeded > section.completed - row.within ||
        row.indeterminate != section.completed - row.within - row.exceeded ||
        (
          limit_index > 0 &&
          (
            row.within < section.duration_limits[limit_index - 1].within ||
            row.exceeded > section.duration_limits[limit_index - 1].exceeded
          )
        ) ||
        (row.limit_us == 0L && row.within != 0L) ||
        (
          row.limit_us == 9223372036854775807L &&
          row.within != section.completed
        ) {
        raise @types.InvalidInput(
          "invalid transit duration classification partition",
        )
      }
    }
    for reason_index, row in section.cancellations {
      if row.reason != reasons[reason_index] || row.count < 0L {
        raise @types.InvalidInput(
          "invalid transit window cancellation count or order",
        )
      }
      validate_window_frame_capacity(
        row.count,
        window.input_frames,
        2 * saved.config.max_tracks,
      )
    }
  }
}

///|
/// Restore bounded aggregate state without reconstructing unobserved passage
/// histories. Counts and all exposed arrays are detached from the checkpoint.
pub fn EvidenceTransitWindowCounter::from_checkpoint(
  saved : EvidenceTransitWindowCheckpoint,
) -> EvidenceTransitWindowCounter raise @types.GroundError {
  if saved.version != 1 {
    raise @types.InvalidInput(
      "unsupported evidence transit window checkpoint version",
    )
  }
  validate_window_configuration(
    saved.session_id,
    saved.gates,
    saved.sections,
    saved.config,
    saved.sigma_multiplier,
    saved.window_us,
    saved.origin_us,
    saved.duration_limits_us,
  )
  validate_window_counts(saved.baseline_counts, saved.sections)
  validate_window_counts(saved.counts, saved.sections)
  for index, count in saved.counts {
    if count.completed < saved.baseline_counts[index].completed {
      raise @types.InvalidInput(
        "transit window lifetime count predates its baseline",
      )
    }
  }
  match saved.baseline_timestamp_us {
    None =>
      if saved.baseline_counts.any(count => count.completed != 0L) {
        raise @types.InvalidInput(
          "unstarted transit window baseline has completed outcomes",
        )
      }
    Some(baseline) =>
      if baseline < saved.origin_us {
        raise @types.InvalidInput("transit window baseline precedes its origin")
      }
  }
  match saved.last_timestamp_us {
    None =>
      if saved.baseline_timestamp_us is Some(_) ||
        saved.current_window is Some(_) ||
        saved.counts.any(count => count.completed != 0L) {
        raise @types.InvalidInput("unstarted transit window must be empty")
      }
    Some(timestamp) => {
      if timestamp < saved.origin_us ||
        (saved.baseline_timestamp_us is Some(baseline) && timestamp < baseline) {
        raise @types.InvalidInput("invalid transit window watermark")
      }
      match saved.current_window {
        None => {
          if saved.last_timestamp_us != saved.baseline_timestamp_us {
            raise @types.InvalidInput(
              "observed transit window lacks its aggregate",
            )
          }
          for index, count in saved.counts {
            if count.completed != saved.baseline_counts[index].completed {
              raise @types.InvalidInput(
                "unobserved transit window changed lifetime counts",
              )
            }
          }
        }
        Some(window) => validate_saved_window(window, saved, timestamp)
      }
    }
  }
  {
    session_id: saved.session_id,
    gates: saved.gates.copy(),
    sections: saved.sections.copy(),
    config: saved.config,
    sigma_multiplier: saved.sigma_multiplier,
    window_us: saved.window_us,
    origin_us: saved.origin_us,
    duration_limits_us: saved.duration_limits_us.copy(),
    baseline_timestamp_us: saved.baseline_timestamp_us,
    baseline_counts: saved.baseline_counts.copy(),
    last_timestamp_us: saved.last_timestamp_us,
    counts: saved.counts.copy(),
    current_window: saved.current_window.map(copy_window),
  }
}
