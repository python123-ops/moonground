///|
fn evidence_pending(
  section : Section,
  entry : @events.GateCrossing,
  original : @events.EvidenceGateCounter,
  observations : Map[Int32, @motion.TrackEstimate],
) -> EvidenceTransitPending raise @types.GroundError {
  // original is still the pre-frame counter: updating its independent fork
  // does not overwrite the original anchor or its source covariance.
  guard original.anchor(entry.track_id, entry.segment_id, entry.gate_id)
    is Some(anchor) else {
    raise @types.InvalidInput(
      "entry crossing lacks its original evidence anchor",
    )
  }
  guard observations.get(entry.track_id) is Some(track) else {
    raise @types.InvalidInput("entry crossing lacks its accepted source target")
  }
  guard track.position_covariance is Some(covariance) else {
    raise @types.InvalidInput(
      "entry crossing lacks its source position covariance",
    )
  }
  if anchor.timestamp_us != entry.from_timestamp_us ||
    anchor.point_m.x != entry.from_position_m.x ||
    anchor.point_m.y != entry.from_position_m.y ||
    track.segment_id != entry.segment_id ||
    track.last_accepted_timestamp_us != entry.to_timestamp_us ||
    track.position is None {
    raise @types.InvalidInput("entry crossing source endpoints differ")
  }
  let point = track.position.unwrap()
  if point.x != entry.to_position_m.x || point.y != entry.to_position_m.y {
    raise @types.InvalidInput("entry crossing current position differs")
  }
  {
    section_id: section.section_id,
    entry,
    from_covariance: anchor.covariance,
    to_covariance: covariance,
  }
}

///|
/// Commit covariance-evidence gates and interval pairing together. This does
/// not roll back the upstream estimator or health owner which supplied frame.
pub fn EvidenceTransitCounter::update(
  self : EvidenceTransitCounter,
  frame : @motion.FrameResult,
) -> EvidenceTransitFrame raise @types.GroundError {
  let original = self.counting
  let counting = original.fork()
  let evidence_frame = counting.update(frame)
  let gate_frame = evidence_frame.counting
  let continuous = match self.last_timestamp_us {
    Some(previous) => frame.timestamp_us - previous < self.max_gap_us
    None => false
  }
  let by_track : Map[Int32, Array[@events.GateCrossing]] = Map([])
  for event in gate_frame.crossings {
    match by_track.get(event.track_id) {
      Some(events) => events.push(event)
      None => by_track[event.track_id] = [event]
    }
  }
  let observations : Map[Int32, @motion.TrackEstimate] = Map([])
  for track in frame.tracks {
    observations[track.track_id] = track
  }
  let staged : Array[Map[Int32, EvidenceTransitPending]] = []
  let counts = self.counts.copy()
  let passages : Array[TransitPassage] = []
  let cancellations : Array[TransitCancellation] = []
  let mut pending_count = 0
  for index, section in self.sections {
    let next : Map[Int32, EvidenceTransitPending] = Map([])
    let identities : Map[Int32, Bool] = Map([])
    for id in self.pending[index].keys() {
      identities[id] = true
    }
    for id in by_track.keys() {
      identities[id] = true
    }
    let ids = identities.keys().collect()
    ids.sort()
    for id in ids {
      let mut pending = self.pending[index].get(id)
      if pending is Some(saved) {
        let entry = saved.entry
        if !continuous || !counting.has_current_track(id, entry.segment_id) {
          cancellations.push(cancellation(section, entry, Discontinuity))
          pending = None
        } else if frame.timestamp_us - entry.to_timestamp_us >=
          self.max_duration_us {
          cancellations.push(cancellation(section, entry, Expired))
          pending = None
        }
      }
      let current : Array[@events.GateCrossing] = []
      if by_track.get(id) is Some(events) {
        for event in events {
          if event.gate_id == section.entry_gate_id ||
            event.gate_id == section.exit_gate_id {
            current.push(event)
          }
        }
      }
      if current.length() == 2 {
        let order = crossing_order(current[0], current[1])
        if order == 0 {
          match pending {
            Some(saved) =>
              cancellations.push(
                cancellation(section, saved.entry, AmbiguousOrder),
              )
            None =>
              for event in current {
                if event.gate_id == section.entry_gate_id &&
                  event.direction == section.entry_direction {
                  cancellations.push(
                    cancellation(section, event, AmbiguousOrder),
                  )
                }
              }
          }
          continue
        }
        if order == 1 {
          let first = current[0]
          current[0] = current[1]
          current[1] = first
        }
      }
      for event in current {
        let is_entry = event.gate_id == section.entry_gate_id
        let desired = if is_entry {
          section.entry_direction
        } else {
          section.exit_direction
        }
        if event.direction != desired {
          if pending is Some(saved) {
            cancellations.push(cancellation(section, saved.entry, Reversed))
            pending = None
          }
        } else if is_entry {
          if pending is Some(saved) {
            cancellations.push(cancellation(section, saved.entry, Reentered))
          }
          pending = Some(
            evidence_pending(section, event, original, observations),
          )
        } else if pending is Some(saved) {
          match passage(section, saved.entry, event) {
            Some(completed) => {
              if counts[index].completed == 9223372036854775807L {
                raise @types.InvalidInput(
                  "transit completion counter exhausted",
                )
              }
              counts[index] = {
                ..counts[index],
                completed: counts[index].completed + 1L,
              }
              passages.push(completed)
            }
            None =>
              cancellations.push(
                cancellation(section, saved.entry, AmbiguousOrder),
              )
          }
          pending = None
        }
      }
      if pending is Some(saved) {
        next[id] = saved
        pending_count = pending_count + 1
      }
    }
    staged.push(next)
  }
  self.counting = counting
  self.pending = staged
  self.counts = counts
  self.last_timestamp_us = Some(frame.timestamp_us)
  {
    counting: evidence_frame,
    passages,
    cancellations,
    counts: counts.copy(),
    pending_count,
  }
}
