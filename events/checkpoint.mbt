///|
fn copy_track(track : GateTrackCheckpoint) -> GateTrackCheckpoint {
  { ..track, anchors: track.anchors.copy(), }
}

///|
pub fn GateCounter::checkpoint(self : GateCounter) -> GateCheckpoint {
  let tracks = self.tracks.values().map(copy_track).collect()
  tracks.sort_by((a, b) => a.track_id.compare(b.track_id))
  {
    version: 1,
    session_id: self.session_id,
    gates: self.gates.copy(),
    config: self.config,
    last_timestamp_us: self.last_timestamp,
    counts: self.counts.copy(),
    tracks,
  }
}

///|
/// Validate all restored state and detach every mutable array before returning.
pub fn GateCounter::from_checkpoint(
  checkpoint : GateCheckpoint,
) -> GateCounter raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput("unsupported gate checkpoint version")
  }
  let restored = GateCounter::new(
    checkpoint.session_id,
    checkpoint.gates,
    checkpoint.config,
  )
  if checkpoint.counts.length() != restored.gates.length() ||
    checkpoint.tracks.length() > restored.config.max_tracks {
    raise @types.InvalidInput("gate checkpoint count or track capacity differs")
  }
  for index, count in checkpoint.counts {
    if count.gate_id != restored.gates[index].gate_id ||
      count.negative_to_positive < 0L ||
      count.positive_to_negative < 0L {
      raise @types.InvalidInput("invalid gate checkpoint totals or gate order")
    }
  }
  match checkpoint.last_timestamp_us {
    None =>
      if checkpoint.tracks.length() != 0 ||
        checkpoint.counts.any(count => {
          count.negative_to_positive != 0L || count.positive_to_negative != 0L
        }) {
        raise @types.InvalidInput("unstarted gate checkpoint must be empty")
      }
    Some(timestamp) => {
      if timestamp < 0L {
        raise @types.InvalidInput(
          "gate checkpoint timestamp must be nonnegative",
        )
      }
      let segments : Map[String, Bool] = Map([])
      for track in checkpoint.tracks {
        validate_segment(track.segment_id)
        if track.track_id <= 0 ||
          restored.tracks.contains(track.track_id) ||
          segments.contains(track.segment_id) {
          raise @types.InvalidInput(
            "gate checkpoint track and segment identities must be unique",
          )
        }
        segments[track.segment_id] = true
        if track.anchors.length() != restored.gates.length() {
          raise @types.InvalidInput("gate checkpoint anchor shape differs")
        }
        for index, anchor in track.anchors {
          if anchor is Some(anchor) {
            anchor.point_m.validate()
            if anchor.timestamp_us < 0L ||
              anchor.timestamp_us > timestamp ||
              timestamp - anchor.timestamp_us >= restored.config.max_gap_us ||
              restored.gates[index].side(anchor.point_m) == 0 {
              raise @types.InvalidInput(
                "invalid or expired gate checkpoint anchor",
              )
            }
          }
        }
        restored.tracks[track.track_id] = copy_track(track)
      }
    }
  }
  restored.counts = checkpoint.counts.copy()
  restored.last_timestamp = checkpoint.last_timestamp_us
  restored
}
