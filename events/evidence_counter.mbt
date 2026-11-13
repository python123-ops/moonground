///|
pub fn EvidenceGateCounter::new(
  session_id : String,
  gates : Array[LineGate],
  config : GateConfig,
  sigma_multiplier~ : Double = 2.0,
) -> EvidenceGateCounter raise @types.GroundError {
  let base = GateCounter::new(session_id, gates, config)
  if !@types.is_finite(sigma_multiplier) || sigma_multiplier < 0.0 {
    raise @types.InvalidInput(
      "evidence sigma multiplier must be finite and nonnegative",
    )
  }
  {
    session_id,
    gates: base.gates,
    config,
    sigma_multiplier,
    last_timestamp: None,
    counts: base.counts,
    tracks: Map([]),
  }
}

///|
/// Normal covariance evidence only establishes stable sides. Crossings still
/// use the finite mean-position chord between the two confirmed anchors.
pub fn EvidenceGateCounter::update(
  self : EvidenceGateCounter,
  frame : @motion.FrameResult,
) -> EvidenceGateFrame raise @types.GroundError {
  validate_gate_frame(self.session_id, self.config, self.last_timestamp, frame)
  // Covariance is structural input for this explicit policy, including k=0.
  // Validate before quality skips can hide malformed typed covariance values.
  for track in frame.tracks {
    match track.position_covariance {
      Some(covariance) => covariance.validate()
      None =>
        if accepted(track.status) {
          raise @types.InvalidInput(
            "evidence counting requires current accepted position covariance",
          )
        }
    }
  }
  let continuous = match self.last_timestamp {
    Some(previous) => frame.timestamp_us - previous < self.config.max_gap_us
    None => false
  }
  let staged : Map[Int32, EvidenceGateTrackCheckpoint] = Map([])
  let counts = self.counts.copy()
  let crossings : Array[GateCrossing] = []
  let evidence : Array[GateEvidence] = []
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
    let point = track.position.unwrap()
    let covariance = track.position_covariance.unwrap()
    let previous = match self.tracks.get(track.track_id) {
      Some(previous) if continuous && previous.segment_id == track.segment_id =>
        Some(previous)
      _ => None
    }
    let anchors : Array[EvidenceGateAnchor?] = []
    let current : EvidenceGateAnchor = {
      timestamp_us: frame.timestamp_us,
      point_m: point,
      covariance,
    }
    for index, gate in self.gates {
      let row = gate_evidence(
        gate,
        track.track_id,
        track.segment_id,
        point,
        covariance,
        self.sigma_multiplier,
      )
      evidence.push(row)
      let previous_anchor = match previous {
        Some(previous) =>
          match previous.anchors[index] {
            Some(anchor) if frame.timestamp_us - anchor.timestamp_us <
              self.config.max_gap_us => Some(anchor)
            _ => None
          }
        None => None
      }
      if row.side == 0 {
        anchors.push(previous_anchor)
        continue
      }
      if previous_anchor is Some(anchor) &&
        gate.side(anchor.point_m) != row.side {
        if gate.crossing(
            { timestamp_us: anchor.timestamp_us, point_m: anchor.point_m, },
            { timestamp_us: current.timestamp_us, point_m: current.point_m, },
            track.track_id,
            track.segment_id,
          )
          is Some(event) {
          counts[index] = increment(counts[index], event.direction)
          crossings.push(event)
        }
      }
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
    counting: {
      session_id: self.session_id,
      timestamp_us: frame.timestamp_us,
      crossings,
      counts: counts.copy(),
    },
    evidence,
  }
}
