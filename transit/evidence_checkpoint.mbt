///|
/// Start from a detached evidence counter. Earlier gate totals remain, but no
/// prior entry is reconstructed and interval completions begin at zero.
pub fn EvidenceTransitCounter::new(
  counting : @events.EvidenceGateCounter,
  sections : Array[Section],
  max_duration_us~ : Int64 = 300000000L,
) -> EvidenceTransitCounter raise @types.GroundError {
  let source = counting.checkpoint()
  let counting = @events.EvidenceGateCounter::from_checkpoint(source)
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
pub fn EvidenceTransitCounter::checkpoint(
  self : EvidenceTransitCounter,
) -> EvidenceTransitCheckpoint {
  let pending : Array[EvidenceTransitPending] = []
  for index, _ in self.sections {
    let ids = self.pending[index].keys().collect()
    ids.sort()
    for id in ids {
      pending.push(self.pending[index][id])
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
/// Validate geometry and actual saved endpoint evidence, not an invented
/// covariance for an old mean-only crossing. This is local state consistency,
/// not proof of the historical source observations or a physical path.
pub fn EvidenceTransitCounter::from_checkpoint(
  checkpoint : EvidenceTransitCheckpoint,
) -> EvidenceTransitCounter raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput("unsupported evidence transit checkpoint version")
  }
  let counting = @events.EvidenceGateCounter::from_checkpoint(
    checkpoint.counting,
  )
  let restored = EvidenceTransitCounter::new(
    counting,
    checkpoint.sections,
    max_duration_us=checkpoint.max_duration_us,
  )
  if checkpoint.counts.length() != restored.sections.length() ||
    checkpoint.pending.length() >
    restored.sections.length() * restored.max_tracks {
    raise @types.InvalidInput(
      "evidence transit checkpoint count or pending shape differs",
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
        "evidence transit completed totals are inconsistent",
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
      raise @types.InvalidInput(
        "pending evidence transit references an unknown section",
      )
    }
    let section = restored.sections[section_index]
    let entry = pending.entry
    let gate = restored.gates[gate_index(restored.gates, section.entry_gate_id).unwrap()]
    entry.validate(gate)
    let from_side = gate.evidence_side(
      entry.from_position_m,
      pending.from_covariance,
      sigma_multiplier=checkpoint.counting.sigma_multiplier,
    )
    let to_side = gate.evidence_side(
      entry.to_position_m,
      pending.to_covariance,
      sigma_multiplier=checkpoint.counting.sigma_multiplier,
    )
    if from_side == 0 || to_side == 0 || from_side == to_side {
      raise @types.InvalidInput(
        "pending entry endpoints lack opposite confirmed evidence",
      )
    }
    guard checkpoint.counting.last_timestamp_us is Some(timestamp) else {
      raise @types.InvalidInput(
        "unstarted evidence transit has a pending entry",
      )
    }
    if entry.direction != section.entry_direction ||
      entry.to_timestamp_us > timestamp ||
      timestamp - entry.to_timestamp_us >= restored.max_duration_us ||
      entry.to_timestamp_us - entry.from_timestamp_us >= restored.max_gap_us ||
      !restored.counting.has_current_track(entry.track_id, entry.segment_id) ||
      restored.pending[section_index].contains(entry.track_id) ||
      restored.pending[section_index].length() >= restored.max_tracks {
      raise @types.InvalidInput(
        "invalid expired or duplicate pending evidence transit",
      )
    }
    let anchor = restored.counting.anchor(
      entry.track_id,
      entry.segment_id,
      entry.gate_id,
    )
    if anchor is Some(anchor) && anchor.timestamp_us < entry.to_timestamp_us {
      raise @types.InvalidInput(
        "pending entry anchor predates its confirmation",
      )
    }
    if anchor is None && timestamp - entry.to_timestamp_us < restored.max_gap_us {
      raise @types.InvalidInput(
        "pending entry confirmation anchor disappeared before expiry",
      )
    }
    if timestamp == entry.to_timestamp_us &&
      (anchor is None || anchor.unwrap().timestamp_us != entry.to_timestamp_us) {
      raise @types.InvalidInput(
        "current pending entry lacks its confirmation anchor",
      )
    }
    // A still-retained anchor at exactly the entry confirmation time is that
    // same observation, even if later unconfirmed frames advanced the clock.
    // A subsequently refreshed anchor has its own later point/covariance.
    if anchor is Some(anchor) &&
      anchor.timestamp_us == entry.to_timestamp_us &&
      (
        anchor.point_m.x != entry.to_position_m.x ||
        anchor.point_m.y != entry.to_position_m.y ||
        anchor.covariance.xx != pending.to_covariance.xx ||
        anchor.covariance.xy != pending.to_covariance.xy ||
        anchor.covariance.yy != pending.to_covariance.yy
      ) {
      raise @types.InvalidInput(
        "pending entry differs from its retained confirmation anchor",
      )
    }
    restored.pending[section_index][entry.track_id] = { ..pending, }
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
        "pending evidence transits exceed recorded entry crossings",
      )
    }
  }
  restored.counts = checkpoint.counts.copy()
  restored
}

///|
pub fn EvidenceTransitCounter::fork(
  self : EvidenceTransitCounter,
) -> EvidenceTransitCounter {
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
