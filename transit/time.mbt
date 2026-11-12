///|
fn same_chord(a : @events.GateCrossing, b : @events.GateCrossing) -> Bool {
  a.from_timestamp_us == b.from_timestamp_us &&
  a.to_timestamp_us == b.to_timestamp_us &&
  a.from_position_m.x == b.from_position_m.x &&
  a.from_position_m.y == b.from_position_m.y &&
  a.to_position_m.x == b.to_position_m.x &&
  a.to_position_m.y == b.to_position_m.y
}

///|
// -1 proves a precedes b, 1 proves b precedes a, 0 is deliberately unresolved.
// Configuration order and fractions on different chords cannot prove ordering.
fn crossing_order(a : @events.GateCrossing, b : @events.GateCrossing) -> Int32 {
  if a.to_timestamp_us <= b.from_timestamp_us {
    -1
  } else if b.to_timestamp_us <= a.from_timestamp_us {
    1
  } else if same_chord(a, b) {
    a.crossing_fraction.compare(b.crossing_fraction)
  } else {
    0
  }
}

///|
fn passage(
  section : Section,
  entry : @events.GateCrossing,
  exit : @events.GateCrossing,
) -> TransitPassage? {
  if crossing_order(entry, exit) != -1 {
    return None
  }
  let lower = if exit.from_timestamp_us >= entry.to_timestamp_us {
    exit.from_timestamp_us - entry.to_timestamp_us
  } else {
    0L
  }
  let upper = exit.to_timestamp_us - entry.from_timestamp_us
  // Never convert an absolute clock to Double or subtract large interpolated
  // clocks. The disjoint-bracket expression adds three nonnegative durations.
  let estimate = if same_chord(entry, exit) {
    (exit.crossing_fraction - entry.crossing_fraction) *
    (entry.to_timestamp_us - entry.from_timestamp_us).to_double()
  } else {
    lower.to_double() +
    (1.0 - entry.crossing_fraction) *
    (entry.to_timestamp_us - entry.from_timestamp_us).to_double() +
    exit.crossing_fraction *
    (exit.to_timestamp_us - exit.from_timestamp_us).to_double()
  }
  if !@types.is_finite(estimate) || estimate <= 0.0 {
    return None
  }
  Some({
    section_id: section.section_id,
    track_id: entry.track_id,
    segment_id: entry.segment_id,
    entry,
    exit,
    elapsed_lower_us: lower,
    elapsed_upper_us: upper,
    estimated_elapsed_us: estimate,
  })
}
