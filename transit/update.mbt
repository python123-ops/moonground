///|
fn cancellation(
  section : Section,
  entry : @events.GateCrossing,
  reason : CancellationReason,
) -> TransitCancellation {
  {
    section_id: section.section_id,
    track_id: entry.track_id,
    segment_id: entry.segment_id,
    reason,
    entry,
  }
}

///|
/// Gate geometry, counts and transit pairing commit together. Missing, rejected,
/// quality-skipped and changed segments cancel pending entries immediately.
/// This downstream transaction does not roll back an upstream motion estimator.
pub fn TransitCounter::update(
  self : TransitCounter,
  frame : @motion.FrameResult,
) -> TransitFrame raise @types.GroundError {
  let counting = self.counting.fork()
  let gate_frame = counting.update(frame)
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
  let staged : Array[Map[Int32, @events.GateCrossing]] = []
  let counts = self.counts.copy()
  let passages : Array[TransitPassage] = []
  let cancellations : Array[TransitCancellation] = []
  let mut pending_count = 0
  for index, section in self.sections {
    let next : Map[Int32, @events.GateCrossing] = Map([])
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
      if pending is Some(entry) {
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
            Some(entry) =>
              cancellations.push(cancellation(section, entry, AmbiguousOrder))
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
          if pending is Some(entry) {
            cancellations.push(cancellation(section, entry, Reversed))
            pending = None
          }
        } else if is_entry {
          if pending is Some(entry) {
            cancellations.push(cancellation(section, entry, Reentered))
          }
          pending = Some(event)
        } else if pending is Some(entry) {
          match passage(section, entry, event) {
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
              cancellations.push(cancellation(section, entry, AmbiguousOrder))
          }
          pending = None
        }
      }
      if pending is Some(entry) {
        next[id] = entry
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
    counting: gate_frame,
    passages,
    cancellations,
    counts: counts.copy(),
    pending_count,
  }
}
