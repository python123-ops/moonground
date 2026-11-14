///|
// Each sum has at most nineteen nonnegative Int64 terms. Base 10^6 keeps the
// quotient sum representable even when the mathematical total exceeds Int64.
fn run_window_sum(values : Array[Int64]) -> (Int64, Int64) {
  let mut quotient = 0L
  let mut remainder = 0L
  for value in values {
    quotient += value / 1000000L
    remainder += value % 1000000L
    quotient += remainder / 1000000L
    remainder %= 1000000L
  }
  (quotient, remainder)
}

///|
fn validate_run_window_capacity(
  counts : Array[Int64],
  frames : Int64,
  tracks : Int32,
) -> Unit raise @types.GroundError {
  let (quotient, remainder) = run_window_sum(counts)
  let capacity = tracks.to_int64()
  let small = frames % 1000000L * capacity
  let limit_quotient = frames / 1000000L * capacity + small / 1000000L
  let limit_remainder = small % 1000000L
  if quotient > limit_quotient ||
    (quotient == limit_quotient && remainder > limit_remainder) {
    raise @types.InvalidInput(
      "footprint run window outcomes exceed the supplied frame capacity",
    )
  }
}

///|
fn run_window_anchor(
  anchors : Map[Int64, Int64],
  timestamp : Int64,
  suffix_count : Int64,
) -> Unit raise @types.GroundError {
  match anchors.get(timestamp) {
    Some(previous) if previous != suffix_count =>
      raise @types.InvalidInput(
        "footprint run window has inconsistent sample suffix anchors",
      )
    _ => anchors[timestamp] = suffix_count
  }
}

///|
fn validate_run_window_samples(
  saved : FootprintRunWindowCheckpoint,
  window : FootprintRunWindow,
) -> Unit raise @types.GroundError {
  let anchors : Map[Int64, Int64] = Map([])
  run_window_anchor(anchors, window.first_timestamp_us, window.input_frames)
  run_window_anchor(anchors, window.last_timestamp_us, 1L)
  let mut earliest : Int64? = None
  for state in saved.runs.states {
    let run = state.run
    if saved.baseline_timestamp_us is None &&
      run.first_timestamp_us < saved.origin_us {
      raise @types.InvalidInput(
        "fresh footprint run predates the statistics origin",
      )
    }
    earliest = match earliest {
      None => Some(run.first_timestamp_us)
      Some(previous) => Some(previous.min(run.first_timestamp_us))
    }
    let observed = match saved.baseline_timestamp_us {
      None => true
      Some(baseline) => run.first_timestamp_us > baseline
    }
    if observed &&
      run.first_timestamp_us >= window.start_us &&
      run.first_timestamp_us < window.first_timestamp_us {
      raise @types.InvalidInput(
        "footprint run witness precedes the first window input",
      )
    }
    if run.first_timestamp_us < window.first_timestamp_us {
      if run.sample_count <= window.input_frames {
        raise @types.InvalidInput(
          "old footprint run omits current window inputs",
        )
      }
    } else {
      run_window_anchor(anchors, run.first_timestamp_us, run.sample_count)
    }
  }
  let times = anchors.keys().collect()
  times.sort()
  if times.length().to_int64() > window.input_frames {
    raise @types.InvalidInput(
      "footprint run witnesses exceed observed window inputs",
    )
  }
  for index, timestamp in times {
    let count = anchors[timestamp]
    if count > window.input_frames - index.to_int64() ||
      window.input_frames - count > timestamp - window.first_timestamp_us {
      raise @types.InvalidInput(
        "footprint run sample suffix cannot fit the window inputs",
      )
    }
    if index > 0 {
      let previous = times[index - 1]
      let previous_count = anchors[previous]
      if previous_count <= count ||
        previous_count - count > timestamp - previous {
        raise @types.InvalidInput(
          "footprint run sample suffix order contradicts exact timestamps",
        )
      }
      if earliest is Some(first) && first <= previous {
        let intervals = previous_count - count
        let span = timestamp - previous
        let gap = saved.runs.config.max_gap_us - 1L
        if gap == 0L ||
          span / intervals > gap ||
          (span / intervals == gap && span % intervals != 0L) {
          raise @types.InvalidInput(
            "footprint run sample anchors cannot satisfy its maximum gap",
          )
        }
      }
    }
  }
}

///|
fn validate_saved_run_window(
  saved : FootprintRunWindowCheckpoint,
  timestamp : Int64,
  window : FootprintRunWindow,
) -> Unit raise @types.GroundError {
  let (start, end) = run_window_bounds(
    timestamp,
    saved.window_us,
    saved.origin_us,
  )
  if window.start_us != start ||
    window.end_exclusive_us != end ||
    window.first_timestamp_us < start ||
    window.first_timestamp_us > timestamp ||
    window.last_timestamp_us != timestamp ||
    window.input_frames < 1L ||
    window.input_frames - 1L > timestamp - window.first_timestamp_us ||
    window.zones.length() != saved.runs.zones.length() ||
    (
      saved.baseline_timestamp_us is Some(baseline) &&
      window.first_timestamp_us <= baseline
    ) {
    raise @types.InvalidInput(
      "footprint run window bounds chronology or zone shape is invalid",
    )
  }
  let order : Map[String, Int32] = Map([])
  let active : Array[Int64] = Array::make(window.zones.length(), 0L)
  let confirmed : Array[Int64] = Array::make(window.zones.length(), 0L)
  let minimum_inside : Array[Int64] = Array::make(window.zones.length(), 0L)
  let minimum_outside : Array[Int64] = Array::make(window.zones.length(), 0L)
  for index, zone in saved.runs.zones {
    order[zone.zone_id] = index
  }
  for state in saved.runs.states {
    let run = state.run
    let index = order[run.zone_id]
    active[index] += 1L
    if run.confirmed {
      confirmed[index] += 1L
      // Qualification guarantees this addition is <= the current timestamp.
      let required_span = saved.runs.config.confirmation_us.max(
        saved.runs.config.min_samples - 1L,
      )
      let earliest = run.first_timestamp_us + required_span
      let after_baseline = match saved.baseline_timestamp_us {
        None => true
        Some(baseline) => earliest > baseline
      }
      if (earliest >= start && after_baseline) ||
        run.sample_count == saved.runs.config.min_samples ||
        run.sample_span_us == saved.runs.config.confirmation_us {
        match run.decision {
          Inside => minimum_inside[index] += 1L
          Outside => minimum_outside[index] += 1L
          Indeterminate => ()
        }
      }
    }
  }
  let reasons = run_window_reasons()
  for index, row in window.zones {
    if row.zone_id != saved.runs.zones[index].zone_id ||
      row.opening_active < 0L ||
      row.opening_active > saved.runs.max_tracks.to_int64() ||
      row.opening_confirmed < 0L ||
      row.opening_confirmed > row.opening_active ||
      row.started < 0L ||
      row.confirmed_inside < minimum_inside[index] ||
      row.confirmed_outside < minimum_outside[index] ||
      row.endings.length() != reasons.length() ||
      (
        saved.baseline_timestamp_us is None &&
        start == saved.origin_us &&
        row.opening_active != 0L
      ) {
      raise @types.InvalidInput(
        "footprint run window zone pools counts or order are invalid",
      )
    }
    let closed : Array[Int64] = []
    let closed_confirmed : Array[Int64] = []
    for reason_index, ending in row.endings {
      if ending.reason != reasons[reason_index] ||
        ending.confirmed < 0L ||
        ending.unconfirmed < 0L ||
        (
          saved.runs.config.min_samples == 1L &&
          saved.runs.config.confirmation_us == 0L &&
          ending.unconfirmed != 0L
        ) {
        raise @types.InvalidInput(
          "footprint run window ending counts or reason order are invalid",
        )
      }
      closed.push(ending.confirmed)
      closed.push(ending.unconfirmed)
      closed_confirmed.push(ending.confirmed)
    }
    validate_run_window_capacity(
      [row.started],
      window.input_frames,
      saved.runs.max_tracks,
    )
    validate_run_window_capacity(
      [row.confirmed_inside, row.confirmed_outside],
      window.input_frames,
      saved.runs.max_tracks,
    )
    validate_run_window_capacity(
      closed,
      window.input_frames,
      saved.runs.max_tracks,
    )
    let all_closed = closed.copy()
    all_closed.push(active[index])
    closed_confirmed.push(confirmed[index])
    if run_window_sum([row.opening_active, row.started]) !=
      run_window_sum(all_closed) ||
      run_window_sum([
        row.opening_confirmed,
        row.confirmed_inside,
        row.confirmed_outside,
      ]) !=
      run_window_sum(closed_confirmed) {
      raise @types.InvalidInput(
        "footprint run window flow does not match its retained active state",
      )
    }
  }
  validate_run_window_samples(saved, window)
}

///|
pub fn FootprintRunWindowMonitor::from_checkpoint(
  saved : FootprintRunWindowCheckpoint,
) -> FootprintRunWindowMonitor raise @types.GroundError {
  if saved.version != 1 {
    raise @types.InvalidInput(
      "unsupported footprint run window checkpoint version",
    )
  }
  let runs = FootprintRunMonitor::from_checkpoint(saved.runs)
  validate_run_window_options(saved.window_us, saved.origin_us)
  if saved.baseline_timestamp_us is Some(baseline) && baseline < saved.origin_us {
    raise @types.InvalidInput(
      "footprint run window baseline precedes its origin",
    )
  }
  match saved.current_window {
    None =>
      if saved.runs.last_timestamp_us != saved.baseline_timestamp_us {
        raise @types.InvalidInput(
          "unobserved footprint run statistics differ from their baseline",
        )
      }
    Some(window) => {
      guard saved.runs.last_timestamp_us is Some(timestamp) else {
        raise @types.InvalidInput(
          "footprint run window lacks a monitor watermark",
        )
      }
      validate_saved_run_window(saved, timestamp, window)
    }
  }
  {
    runs,
    window_us: saved.window_us,
    origin_us: saved.origin_us,
    baseline_timestamp_us: saved.baseline_timestamp_us,
    current_window: saved.current_window.map(copy_run_window),
  }
}
