///|
fn copy_window(window : TransitWindow) -> TransitWindow {
  {
    ..window,
    sections: window.sections.map(section => {
      ..section,
      duration_limits: section.duration_limits.copy(),
      cancellations: section.cancellations.copy(),
    }),
  }
}

///|
fn window_bounds(
  timestamp : Int64,
  origin : Int64,
  width : Int64,
) -> (Int64, Int64?) {
  let start = timestamp - (timestamp - origin) % width
  let end = if width <= 9223372036854775807L - start {
    Some(start + width)
  } else {
    None
  }
  (start, end)
}

///|
fn cancellation_reasons() -> Array[CancellationReason] {
  [Discontinuity, Expired, Reentered, Reversed, AmbiguousOrder]
}

///|
fn empty_window(
  sections : Array[Section],
  limits : Array[Int64],
  timestamp : Int64,
  origin : Int64,
  width : Int64,
) -> TransitWindow {
  let (start, end) = window_bounds(timestamp, origin, width)
  {
    start_us: start,
    end_exclusive_us: end,
    first_timestamp_us: timestamp,
    last_timestamp_us: timestamp,
    input_frames: 0L,
    sections: sections.map(section => {
      section_id: section.section_id,
      completed: 0L,
      duration_limits: limits.map(limit => {
        limit_us: limit,
        within: 0L,
        exceeded: 0L,
        indeterminate: 0L,
      }),
      cancellations: cancellation_reasons().map(reason => { reason, count: 0L, }),
    }),
  }
}

///|
fn validate_window_configuration(
  session_id : String,
  gates : Array[@events.LineGate],
  sections : Array[Section],
  config : @events.GateConfig,
  multiplier : Double,
  width : Int64,
  origin : Int64,
  limits : Array[Int64],
) -> Unit raise @types.GroundError {
  // These checked constructors validate the original definitions and budgets,
  // but create no upstream history, observations or covariance witnesses.
  ignore(
    @events.EvidenceGateCounter::new(
      session_id,
      gates,
      config,
      sigma_multiplier=multiplier,
    ),
  )
  validate_sections(sections, gates, config.max_tracks, 1L)
  if width <= 0L || origin < 0L || limits.length() < 1 || limits.length() > 16 {
    raise @types.InvalidInput(
      "invalid transit window width origin or limit capacity",
    )
  }
  for index, limit in limits {
    if limit < 0L || (index > 0 && limit <= limits[index - 1]) {
      raise @types.InvalidInput(
        "transit duration limits must be nonnegative and strictly increasing",
      )
    }
  }
}

///|
/// Validate the original checkpoint once, then retain only immutable
/// definitions, the exact watermark and completed-count baseline.
pub fn EvidenceTransitWindowCounter::new(
  upstream : EvidenceTransitCheckpoint,
  window_us~ : Int64,
  duration_limits_us~ : Array[Int64],
  origin_us~ : Int64 = 0L,
) -> EvidenceTransitWindowCounter raise @types.GroundError {
  let source = EvidenceTransitCounter::from_checkpoint(upstream).checkpoint()
  validate_window_configuration(
    source.counting.session_id,
    source.counting.gates,
    source.sections,
    source.counting.config,
    source.counting.sigma_multiplier,
    window_us,
    origin_us,
    duration_limits_us,
  )
  if source.counting.last_timestamp_us is Some(timestamp) &&
    timestamp < origin_us {
    raise @types.InvalidInput("upstream checkpoint precedes the window origin")
  }
  {
    session_id: source.counting.session_id,
    gates: source.counting.gates.copy(),
    sections: source.sections.copy(),
    config: source.counting.config,
    sigma_multiplier: source.counting.sigma_multiplier,
    window_us,
    origin_us,
    duration_limits_us: duration_limits_us.copy(),
    baseline_timestamp_us: source.counting.last_timestamp_us,
    baseline_counts: source.counts.copy(),
    last_timestamp_us: source.counting.last_timestamp_us,
    counts: source.counts.copy(),
    current_window: None,
  }
}

///|
pub fn EvidenceTransitWindowCounter::checkpoint(
  self : EvidenceTransitWindowCounter,
) -> EvidenceTransitWindowCheckpoint {
  {
    version: 1,
    session_id: self.session_id,
    gates: self.gates.copy(),
    sections: self.sections.copy(),
    config: self.config,
    sigma_multiplier: self.sigma_multiplier,
    window_us: self.window_us,
    origin_us: self.origin_us,
    duration_limits_us: self.duration_limits_us.copy(),
    baseline_timestamp_us: self.baseline_timestamp_us,
    baseline_counts: self.baseline_counts.copy(),
    last_timestamp_us: self.last_timestamp_us,
    counts: self.counts.copy(),
    current_window: self.current_window.map(copy_window),
  }
}

///|
pub fn EvidenceTransitWindowCounter::fork(
  self : EvidenceTransitWindowCounter,
) -> EvidenceTransitWindowCounter {
  {
    session_id: self.session_id,
    gates: self.gates.copy(),
    sections: self.sections.copy(),
    config: self.config,
    sigma_multiplier: self.sigma_multiplier,
    window_us: self.window_us,
    origin_us: self.origin_us,
    duration_limits_us: self.duration_limits_us.copy(),
    baseline_timestamp_us: self.baseline_timestamp_us,
    baseline_counts: self.baseline_counts.copy(),
    last_timestamp_us: self.last_timestamp_us,
    counts: self.counts.copy(),
    current_window: self.current_window.map(copy_window),
  }
}
