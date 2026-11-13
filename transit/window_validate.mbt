///|
fn window_segment(segment : String) -> Unit raise @types.GroundError {
  let value = @string.parse_int64(segment, base=10) catch {
    _ => raise @types.InvalidInput("invalid transit window source segment")
  }
  if value <= 0L || value.to_string() != segment {
    raise @types.InvalidInput(
      "transit window source segment must be canonical and positive",
    )
  }
}

///|
fn same_window_crossing(
  a : @events.GateCrossing,
  b : @events.GateCrossing,
) -> Bool {
  a.gate_id == b.gate_id &&
  a.track_id == b.track_id &&
  a.segment_id == b.segment_id &&
  a.direction == b.direction &&
  a.from_timestamp_us == b.from_timestamp_us &&
  a.to_timestamp_us == b.to_timestamp_us &&
  a.crossing_fraction == b.crossing_fraction &&
  a.from_position_m.x == b.from_position_m.x &&
  a.from_position_m.y == b.from_position_m.y &&
  a.to_position_m.x == b.to_position_m.x &&
  a.to_position_m.y == b.to_position_m.y &&
  a.position_m.x == b.position_m.x &&
  a.position_m.y == b.position_m.y
}

///|
fn window_section_index(
  sections : Array[Section],
  id : String,
) -> Int32 raise @types.GroundError {
  for index, section in sections {
    if section.section_id == id {
      return index
    }
  }
  raise @types.InvalidInput(
    "transit window outcome references an unknown section",
  )
}

///|
fn EvidenceTransitWindowCounter::validate_window_evidence(
  self : EvidenceTransitWindowCounter,
  frame : @events.EvidenceGateFrame,
) -> Map[Int32, Int32] raise @types.GroundError {
  let size = self.gates.length()
  if frame.evidence.length() > size * self.config.max_tracks ||
    frame.evidence.length() % size != 0 {
    raise @types.InvalidInput(
      "transit window evidence row capacity or shape differs",
    )
  }
  let groups : Map[Int32, Int32] = Map([])
  let segments : Map[String, Bool] = Map([])
  let mut previous_id = 0
  for index, row in frame.evidence {
    let gate = self.gates[index % size]
    if index % size == 0 {
      window_segment(row.segment_id)
      if row.track_id <= previous_id || segments.contains(row.segment_id) {
        raise @types.InvalidInput(
          "transit window evidence identities or order differ",
        )
      }
      previous_id = row.track_id
      segments[row.segment_id] = true
      groups[row.track_id] = index
    } else {
      let first = frame.evidence[index - index % size]
      if row.track_id != first.track_id || row.segment_id != first.segment_id {
        raise @types.InvalidInput(
          "transit window evidence target group differs",
        )
      }
    }
    if row.gate_id != gate.gate_id ||
      !@types.is_finite(row.distance_m) ||
      !@types.is_finite(row.normal_std_m) ||
      row.normal_std_m <= 0.0 ||
      !@types.is_finite(row.lower_m) ||
      !@types.is_finite(row.upper_m) {
      raise @types.InvalidInput(
        "invalid transit window source evidence diagnostics",
      )
    }
    let radius = self.sigma_multiplier * row.normal_std_m
    if !@types.is_finite(radius) ||
      (
        self.sigma_multiplier > 0.0 &&
        (
          radius <= 0.0 ||
          row.lower_m >= row.distance_m ||
          row.upper_m <= row.distance_m
        )
      ) ||
      row.lower_m != row.distance_m - radius ||
      row.upper_m != row.distance_m + radius {
      raise @types.InvalidInput(
        "transit window source evidence interval differs",
      )
    }
    let side = if row.lower_m > gate.deadband_m {
      1
    } else if row.upper_m < -gate.deadband_m {
      -1
    } else {
      0
    }
    if row.side != side {
      raise @types.InvalidInput("transit window source evidence side differs")
    }
  }
  groups
}

///|
fn EvidenceTransitWindowCounter::validate_window_crossings(
  self : EvidenceTransitWindowCounter,
  frame : @events.EvidenceGateFrame,
  groups : Map[Int32, Int32],
) -> Map[Int32, Map[String, @events.GateCrossing]] raise @types.GroundError {
  let gates = frame.counting
  if gates.counts.length() != self.gates.length() ||
    gates.crossings.length() > self.gates.length() * self.config.max_tracks {
    raise @types.InvalidInput(
      "transit window source gate count or crossing capacity differs",
    )
  }
  for index, count in gates.counts {
    if count.gate_id != self.gates[index].gate_id ||
      count.negative_to_positive < 0L ||
      count.positive_to_negative < 0L {
      raise @types.InvalidInput(
        "invalid transit window source gate totals or order",
      )
    }
  }
  let current : Map[Int32, Map[String, @events.GateCrossing]] = Map([])
  let positive = Array::make(self.gates.length(), 0L)
  let negative = Array::make(self.gates.length(), 0L)
  let mut previous_id = 0
  let mut previous_gate = -1
  for event in gates.crossings {
    guard gate_index(self.gates, event.gate_id) is Some(index) else {
      raise @types.InvalidInput(
        "transit window crossing references an unknown gate",
      )
    }
    event.validate(self.gates[index])
    if event.to_timestamp_us != gates.timestamp_us ||
      event.to_timestamp_us - event.from_timestamp_us >= self.config.max_gap_us ||
      event.track_id < previous_id ||
      (event.track_id == previous_id && index <= previous_gate) {
      raise @types.InvalidInput(
        "invalid transit window source crossing time or order",
      )
    }
    previous_id = event.track_id
    previous_gate = index
    guard groups.get(event.track_id) is Some(group) else {
      raise @types.InvalidInput(
        "transit window crossing lacks current evidence",
      )
    }
    let row = frame.evidence[group + index]
    let side = if event.direction is @events.NegativeToPositive {
      1
    } else {
      -1
    }
    if row.segment_id != event.segment_id || row.side != side {
      raise @types.InvalidInput(
        "transit window crossing differs from its current evidence",
      )
    }
    match current.get(event.track_id) {
      None => current[event.track_id] = Map([(event.gate_id, event)])
      Some(events) => {
        for previous in events.values() {
          if previous.to_position_m.x != event.to_position_m.x ||
            previous.to_position_m.y != event.to_position_m.y {
            raise @types.InvalidInput(
              "transit window simultaneous crossings have different current points",
            )
          }
        }
        events[event.gate_id] = event
      }
    }
    match event.direction {
      @events.NegativeToPositive => positive[index] = positive[index] + 1L
      @events.PositiveToNegative => negative[index] = negative[index] + 1L
    }
  }
  for index, count in gates.counts {
    if positive[index] > count.negative_to_positive ||
      negative[index] > count.positive_to_negative {
      raise @types.InvalidInput(
        "transit window crossings exceed source gate totals",
      )
    }
  }
  current
}

///|
fn require_current_window_crossing(
  event : @events.GateCrossing,
  current : Map[Int32, Map[String, @events.GateCrossing]],
) -> Unit raise @types.GroundError {
  guard current.get(event.track_id) is Some(events) &&
    events.get(event.gate_id) is Some(actual) else {
    raise @types.InvalidInput(
      "transit window outcome lacks its current source crossing",
    )
  }
  if !same_window_crossing(actual, event) {
    raise @types.InvalidInput(
      "transit window outcome differs from its current source crossing",
    )
  }
}

///|
fn EvidenceTransitWindowCounter::validate_window_input(
  self : EvidenceTransitWindowCounter,
  frame : EvidenceTransitFrame,
) -> Unit raise @types.GroundError {
  let gates = frame.counting.counting
  let timestamp = gates.timestamp_us
  if gates.session_id != self.session_id ||
    timestamp < self.origin_us ||
    (self.last_timestamp_us is Some(previous) && timestamp <= previous) {
    raise @types.InvalidInput(
      "transit window source session or timestamp differs",
    )
  }
  let slots = self.sections.length() * self.config.max_tracks
  if frame.passages.length() > slots ||
    frame.cancellations.length() > 2 * slots ||
    frame.pending_count < 0 ||
    frame.pending_count > slots {
    raise @types.InvalidInput("transit window source outcome capacity exceeded")
  }
  validate_window_counts(frame.counts, self.sections)
  let groups = self.validate_window_evidence(frame.counting)
  let current = self.validate_window_crossings(frame.counting, groups)
  let completed = Array::make(self.sections.length(), 0L)
  let mut previous_section = -1
  let mut previous_track = 0
  for value in frame.passages {
    let index = window_section_index(self.sections, value.section_id)
    let section = self.sections[index]
    value.entry.validate(
      self.gates[gate_index(self.gates, section.entry_gate_id).unwrap()],
    )
    value.exit.validate(
      self.gates[gate_index(self.gates, section.exit_gate_id).unwrap()],
    )
    if index < previous_section ||
      (index == previous_section && value.track_id <= previous_track) ||
      value.track_id != value.entry.track_id ||
      value.track_id != value.exit.track_id ||
      value.segment_id != value.entry.segment_id ||
      value.segment_id != value.exit.segment_id ||
      value.entry.gate_id != section.entry_gate_id ||
      value.exit.gate_id != section.exit_gate_id ||
      value.entry.direction != section.entry_direction ||
      value.exit.direction != section.exit_direction ||
      value.exit.to_timestamp_us != timestamp ||
      value.entry.to_timestamp_us - value.entry.from_timestamp_us >=
      self.config.max_gap_us ||
      value.exit.to_timestamp_us - value.exit.from_timestamp_us >=
      self.config.max_gap_us {
      raise @types.InvalidInput(
        "invalid transit window passage identity order or bracket",
      )
    }
    previous_section = index
    previous_track = value.track_id
    guard passage(section, value.entry, value.exit) is Some(expected) else {
      raise @types.InvalidInput(
        "transit window passage lacks a proved positive duration",
      )
    }
    if value.elapsed_lower_us != expected.elapsed_lower_us ||
      value.elapsed_upper_us != expected.elapsed_upper_us ||
      value.estimated_elapsed_us != expected.estimated_elapsed_us {
      raise @types.InvalidInput(
        "transit window passage duration differs from its original brackets",
      )
    }
    require_current_window_crossing(value.exit, current)
    if value.entry.to_timestamp_us == timestamp {
      require_current_window_crossing(value.entry, current)
    }
    completed[index] = completed[index] + 1L
  }
  previous_section = -1
  previous_track = 0
  let cancelled = Array::make(self.sections.length(), 0)
  for value in frame.cancellations {
    let index = window_section_index(self.sections, value.section_id)
    let section = self.sections[index]
    cancelled[index] = cancelled[index] + 1
    if cancelled[index] > 2 * self.config.max_tracks {
      raise @types.InvalidInput(
        "transit window source section cancellation capacity exceeded",
      )
    }
    value.entry.validate(
      self.gates[gate_index(self.gates, section.entry_gate_id).unwrap()],
    )
    if index < previous_section ||
      (index == previous_section && value.track_id < previous_track) ||
      value.track_id != value.entry.track_id ||
      value.segment_id != value.entry.segment_id ||
      value.entry.gate_id != section.entry_gate_id ||
      value.entry.direction != section.entry_direction ||
      value.entry.to_timestamp_us > timestamp ||
      value.entry.to_timestamp_us - value.entry.from_timestamp_us >=
      self.config.max_gap_us ||
      (
        (
          value.reason is Discontinuity ||
          value.reason is Expired ||
          value.reason is Reentered
        ) &&
        value.entry.to_timestamp_us == timestamp
      ) {
      raise @types.InvalidInput(
        "invalid transit window cancellation identity order or time",
      )
    }
    previous_section = index
    previous_track = value.track_id
    if value.entry.to_timestamp_us == timestamp {
      require_current_window_crossing(value.entry, current)
    }
  }
  for index, count in frame.counts {
    let section = self.sections[index]
    let entry_index = gate_index(self.gates, section.entry_gate_id).unwrap()
    let exit_index = gate_index(self.gates, section.exit_gate_id).unwrap()
    if count.completed < self.counts[index].completed ||
      count.completed - self.counts[index].completed != completed[index] ||
      count.completed >
      directional_count(gates.counts[entry_index], section.entry_direction) ||
      count.completed >
      directional_count(gates.counts[exit_index], section.exit_direction) {
      raise @types.InvalidInput(
        "transit window completion delta differs from supplied outcomes",
      )
    }
  }
}
