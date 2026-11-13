///|
fn gate_index(gates : Array[@events.LineGate], id : String) -> Int32? {
  for index, gate in gates {
    if gate.gate_id == id {
      return Some(index)
    }
  }
  None
}

///|
fn directional_count(
  count : @events.GateCount,
  direction : @events.CrossingDirection,
) -> Int64 {
  match direction {
    NegativeToPositive => count.negative_to_positive
    PositiveToNegative => count.positive_to_negative
  }
}

///|
fn validate_sections(
  sections : Array[Section],
  gates : Array[@events.LineGate],
  max_tracks : Int32,
  max_duration_us : Int64,
) -> Unit raise @types.GroundError {
  if sections.length() < 1 ||
    sections.length() > 16 ||
    sections.length() * max_tracks > 65536 ||
    max_duration_us <= 0L {
    raise @types.InvalidInput("invalid transit section capacity or duration")
  }
  let seen : Map[String, Bool] = Map([])
  for section in sections {
    ignore(
      Section::new(
        section.section_id,
        section.entry_gate_id,
        section.entry_direction,
        section.exit_gate_id,
        section.exit_direction,
      ),
    )
    if seen.contains(section.section_id) ||
      gate_index(gates, section.entry_gate_id) is None ||
      gate_index(gates, section.exit_gate_id) is None {
      raise @types.InvalidInput(
        "transit sections must be unique and reference configured gates",
      )
    }
    seen[section.section_id] = true
  }
}

///|
/// Start a detached downstream counter at the gate counter's current frame.
/// Existing gate totals remain; completed transits start at zero and no earlier
/// entry is reconstructed. max_duration_us bounds waiting since entry confirmation.
pub fn TransitCounter::new(
  counting : @events.GateCounter,
  sections : Array[Section],
  max_duration_us~ : Int64 = 300000000L,
) -> TransitCounter raise @types.GroundError {
  let source = counting.checkpoint()
  let counting = @events.GateCounter::from_checkpoint(source)
  validate_sections(
    sections,
    source.gates,
    source.config.max_tracks,
    max_duration_us,
  )
  {
    counting,
    sections: sections.copy(),
    gates: source.gates.copy(),
    max_duration_us,
    max_gap_us: source.config.max_gap_us,
    max_tracks: source.config.max_tracks,
    last_timestamp_us: source.last_timestamp_us,
    counts: sections.map(section => {
      section_id: section.section_id,
      completed: 0L,
    }),
    pending: sections.map(_ => Map([])),
  }
}

///|
pub fn TransitCounter::checkpoint(self : TransitCounter) -> TransitCheckpoint {
  let pending : Array[TransitPending] = []
  for index, section in self.sections {
    let ids = self.pending[index].keys().collect()
    ids.sort()
    for id in ids {
      pending.push({
        section_id: section.section_id,
        entry: self.pending[index][id],
      })
    }
  }
  {
    version: 1,
    counting: self.counting.checkpoint(),
    sections: self.sections.copy(),
    max_duration_us: self.max_duration_us,
    counts: self.counts.copy(),
    pending,
  }
}

///|
pub fn TransitCounter::from_checkpoint(
  checkpoint : TransitCheckpoint,
) -> TransitCounter raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput("unsupported transit checkpoint version")
  }
  let gate_counter = @events.GateCounter::from_checkpoint(checkpoint.counting)
  let restored = TransitCounter::new(
    gate_counter,
    checkpoint.sections,
    max_duration_us=checkpoint.max_duration_us,
  )
  if checkpoint.counts.length() != restored.sections.length() ||
    checkpoint.pending.length() >
    restored.sections.length() * restored.max_tracks {
    raise @types.InvalidInput(
      "transit checkpoint count or pending shape differs",
    )
  }
  for index, section in restored.sections {
    let count = checkpoint.counts[index]
    let entry_index = gate_index(restored.gates, section.entry_gate_id).unwrap()
    let exit_index = gate_index(restored.gates, section.exit_gate_id).unwrap()
    if count.section_id != section.section_id ||
      count.completed < 0L ||
      count.completed >
      directional_count(
        checkpoint.counting.counts[entry_index],
        section.entry_direction,
      ) ||
      count.completed >
      directional_count(
        checkpoint.counting.counts[exit_index],
        section.exit_direction,
      ) {
      raise @types.InvalidInput(
        "transit checkpoint completed totals are inconsistent",
      )
    }
  }
  for pending in checkpoint.pending {
    let mut section_index = -1
    for index, section in restored.sections {
      if section.section_id == pending.section_id {
        section_index = index
        break
      }
    }
    if section_index < 0 {
      raise @types.InvalidInput("pending transit references an unknown section")
    }
    let section = restored.sections[section_index]
    let entry = pending.entry
    let gate = restored.gates[gate_index(restored.gates, section.entry_gate_id).unwrap()]
    entry.validate(gate)
    guard checkpoint.counting.last_timestamp_us is Some(timestamp) else {
      raise @types.InvalidInput(
        "unstarted transit checkpoint has a pending entry",
      )
    }
    if entry.direction != section.entry_direction ||
      entry.to_timestamp_us > timestamp ||
      timestamp - entry.to_timestamp_us >= restored.max_duration_us ||
      entry.to_timestamp_us - entry.from_timestamp_us >= restored.max_gap_us ||
      !restored.counting.has_current_track(entry.track_id, entry.segment_id) ||
      restored.pending[section_index].contains(entry.track_id) ||
      restored.pending[section_index].length() >= restored.max_tracks {
      raise @types.InvalidInput("invalid, expired or duplicate pending transit")
    }
    restored.pending[section_index][entry.track_id] = entry
  }
  for index, section in restored.sections {
    let entry_index = gate_index(restored.gates, section.entry_gate_id).unwrap()
    let entries = directional_count(
      checkpoint.counting.counts[entry_index],
      section.entry_direction,
    )
    if entries - checkpoint.counts[index].completed <
      Int64::from_int(restored.pending[index].length()) {
      raise @types.InvalidInput(
        "pending transits exceed recorded entry crossings",
      )
    }
  }
  restored.counts = checkpoint.counts.copy()
  restored
}

///|
pub fn TransitCounter::fork(self : TransitCounter) -> TransitCounter {
  {
    counting: self.counting.fork(),
    sections: self.sections.copy(),
    gates: self.gates.copy(),
    max_duration_us: self.max_duration_us,
    max_gap_us: self.max_gap_us,
    max_tracks: self.max_tracks,
    last_timestamp_us: self.last_timestamp_us,
    counts: self.counts.copy(),
    pending: self.pending.map(tracks => tracks.copy()),
  }
}
