///|
/// A bounded metric event consumer. It does not mutate or predict motion state.
pub struct GateCounter {
  priv session_id : String
  priv gates : Array[LineGate]
  priv config : GateConfig
  priv mut last_timestamp : Int64?
  priv mut counts : Array[GateCount]
  priv mut tracks : Map[Int32, GateTrackCheckpoint]
}

///|
pub fn GateCounter::new(
  session_id : String,
  gates : Array[LineGate],
  config : GateConfig,
) -> GateCounter raise @types.GroundError {
  if session_id.length() == 0 {
    raise @types.InvalidInput("gate session_id must not be empty")
  }
  if gates.length() < 1 ||
    gates.length() > 16 ||
    gates.length() * config.max_tracks > 65536 {
    raise @types.InvalidInput("gate count or anchor capacity exceeded")
  }
  let seen : Map[String, Bool] = Map([])
  for gate in gates {
    if seen.contains(gate.gate_id) {
      raise @types.InvalidInput("gate identities must be unique")
    }
    seen[gate.gate_id] = true
  }
  {
    session_id,
    gates: gates.copy(),
    config,
    last_timestamp: None,
    counts: gates.map(gate => GateCount::{
      gate_id: gate.gate_id,
      negative_to_positive: 0L,
      positive_to_negative: 0L,
    }),
    tracks: Map([]),
  }
}

///|
fn validate_segment(segment_id : String) -> Unit raise @types.GroundError {
  let value = @string.parse_int64(segment_id, base=10) catch {
    _ =>
      raise @types.InvalidInput(
        "gate segment_id must be a positive Int64 decimal string",
      )
  }
  if value <= 0L || value.to_string() != segment_id {
    raise @types.InvalidInput(
      "gate segment_id must be a canonical positive Int64 decimal string",
    )
  }
}

///|
fn accepted(status : @motion.MotionStatus) -> Bool {
  status is @motion.Initializing ||
  status is @motion.Ready ||
  status is @motion.Uncertain
}

///|
fn increment(
  count : GateCount,
  direction : CrossingDirection,
) -> GateCount raise @types.GroundError {
  match direction {
    NegativeToPositive => {
      if count.negative_to_positive == 9223372036854775807L {
        raise @types.InvalidInput("gate crossing counter exhausted")
      }
      { ..count, negative_to_positive: count.negative_to_positive + 1L, }
    }
    PositiveToNegative => {
      if count.positive_to_negative == 9223372036854775807L {
        raise @types.InvalidInput("gate crossing counter exhausted")
      }
      { ..count, positive_to_negative: count.positive_to_negative + 1L, }
    }
  }
}

///|
fn validate_gate_frame(
  session_id : String,
  config : GateConfig,
  last_timestamp : Int64?,
  frame : @motion.FrameResult,
) -> Unit raise @types.GroundError {
  if frame.session_id != session_id || frame.timestamp_us < 0L {
    raise @types.InvalidInput("gate frame session or timestamp differs")
  }
  if last_timestamp is Some(previous) && frame.timestamp_us <= previous {
    raise @types.InvalidInput("gate frame timestamps must strictly increase")
  }
  if frame.tracks.length() > config.max_tracks ||
    frame.closed_segment_ids.length() > config.max_tracks {
    raise @types.InvalidInput("gate frame exceeds track capacity")
  }
  let track_ids : Map[Int32, Bool] = Map([])
  let segment_ids : Map[String, Bool] = Map([])
  for track in frame.tracks {
    validate_segment(track.segment_id)
    if track.track_id <= 0 ||
      track_ids.contains(track.track_id) ||
      segment_ids.contains(track.segment_id) {
      raise @types.InvalidInput(
        "gate frame track and segment identities must be positive and unique",
      )
    }
    track_ids[track.track_id] = true
    segment_ids[track.segment_id] = true
    if track.last_accepted_timestamp_us < 0L ||
      track.last_accepted_timestamp_us > frame.timestamp_us {
      raise @types.InvalidInput("invalid gate accepted timestamp")
    }
    if track.position is Some(point) {
      point.validate()
    }
    if track.position_std_m is Some(deviation) &&
      (!@types.is_finite(deviation) || deviation <= 0.0) {
      raise @types.InvalidInput(
        "gate position deviation must be finite and positive",
      )
    }
    if accepted(track.status) &&
      (
        track.position is None ||
        track.last_accepted_timestamp_us != frame.timestamp_us
      ) {
      raise @types.InvalidInput(
        "accepted gate positions must belong to the current frame",
      )
    }
  }
  let closed : Map[String, Bool] = Map([])
  for segment_id in frame.closed_segment_ids {
    validate_segment(segment_id)
    if closed.contains(segment_id) || segment_ids.contains(segment_id) {
      raise @types.InvalidInput(
        "closed gate segments must be unique and disjoint from current segments",
      )
    }
    closed[segment_id] = true
  }
}

///|
/// Commit one frame atomically. Missing, rejected and quality-skipped tracks
/// lose every anchor immediately. Accepted positions do not require ready speed.
/// A same-side stable point refreshes its anchor; deadband points do not.
pub fn GateCounter::update(
  self : GateCounter,
  frame : @motion.FrameResult,
) -> GateFrame raise @types.GroundError {
  validate_gate_frame(self.session_id, self.config, self.last_timestamp, frame)
  let continuous = match self.last_timestamp {
    Some(previous) => frame.timestamp_us - previous < self.config.max_gap_us
    None => false
  }
  let staged : Map[Int32, GateTrackCheckpoint] = Map([])
  let counts = self.counts.copy()
  let crossings : Array[GateCrossing] = []
  let ordered = frame.tracks.copy()
  ordered.sort_by((a, b) => a.track_id.compare(b.track_id))
  for track in ordered {
    if !accepted(track.status) {
      continue
    }
    if self.config.max_position_std_m is Some(limit) {
      match track.position_std_m {
        Some(deviation) if deviation <= limit => ()
        _ => continue
      }
    }
    let point = match track.position {
      Some(point) => point
      None => raise @types.InvalidInput("accepted gate position is missing")
    }
    let previous = match self.tracks.get(track.track_id) {
      Some(previous) if continuous && previous.segment_id == track.segment_id =>
        Some(previous)
      _ => None
    }
    let anchors : Array[GateAnchor?] = []
    let current : GateAnchor = {
      timestamp_us: frame.timestamp_us,
      point_m: point,
    }
    for index, gate in self.gates {
      let side = gate.side(point)
      let previous_anchor = match previous {
        Some(previous) =>
          match previous.anchors[index] {
            Some(anchor) if frame.timestamp_us - anchor.timestamp_us <
              self.config.max_gap_us => Some(anchor)
            _ => None
          }
        None => None
      }
      if side == 0 {
        anchors.push(previous_anchor)
        continue
      }
      if previous_anchor is Some(anchor) && gate.side(anchor.point_m) != side {
        if gate.crossing(anchor, current, track.track_id, track.segment_id)
          is Some(event) {
          counts[index] = increment(counts[index], event.direction)
          crossings.push(event)
        }
      }
      // A crossing of the infinite extension still changes the stable side.
      anchors.push(Some(current))
    }
    staged[track.track_id] = {
      track_id: track.track_id,
      segment_id: track.segment_id,
      anchors,
    }
  }
  self.tracks = staged
  self.counts = counts
  self.last_timestamp = Some(frame.timestamp_us)
  {
    session_id: self.session_id,
    timestamp_us: frame.timestamp_us,
    crossings,
    counts: counts.copy(),
  }
}
