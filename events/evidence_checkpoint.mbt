///|
fn copy_evidence_track(
  track : EvidenceGateTrackCheckpoint,
) -> EvidenceGateTrackCheckpoint {
  { ..track, anchors: track.anchors.copy(), }
}

///|
pub fn EvidenceGateCounter::checkpoint(
  self : EvidenceGateCounter,
) -> EvidenceGateCheckpoint {
  let tracks = self.tracks.values().map(copy_evidence_track).collect()
  tracks.sort_by((a, b) => a.track_id.compare(b.track_id))
  {
    version: 1,
    session_id: self.session_id,
    gates: self.gates.copy(),
    config: self.config,
    sigma_multiplier: self.sigma_multiplier,
    last_timestamp_us: self.last_timestamp,
    counts: self.counts.copy(),
    tracks,
  }
}

///|
/// Recheck the original covariance, side proof and anchor age under the saved
/// policy. Legacy checkpoint validation additionally checks identities, shape,
/// mean-side geometry and exact counters. No historical samples are invented.
pub fn EvidenceGateCounter::from_checkpoint(
  checkpoint : EvidenceGateCheckpoint,
) -> EvidenceGateCounter raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput("unsupported evidence gate checkpoint version")
  }
  let restored = EvidenceGateCounter::new(
    checkpoint.session_id,
    checkpoint.gates,
    checkpoint.config,
    sigma_multiplier=checkpoint.sigma_multiplier,
  )
  if checkpoint.tracks.length() > restored.config.max_tracks ||
    checkpoint.counts.length() != restored.gates.length() {
    raise @types.InvalidInput(
      "evidence checkpoint count or track capacity differs",
    )
  }
  for track in checkpoint.tracks {
    if track.anchors.length() != restored.gates.length() {
      raise @types.InvalidInput("evidence checkpoint anchor shape differs")
    }
  }
  let legacy : GateCheckpoint = {
    version: 1,
    session_id: checkpoint.session_id,
    gates: checkpoint.gates,
    config: checkpoint.config,
    last_timestamp_us: checkpoint.last_timestamp_us,
    counts: checkpoint.counts,
    tracks: checkpoint.tracks.map(track => GateTrackCheckpoint::{
      track_id: track.track_id,
      segment_id: track.segment_id,
      anchors: track.anchors.map(anchor => {
        anchor.map(anchor => GateAnchor::{
          timestamp_us: anchor.timestamp_us,
          point_m: anchor.point_m,
        })
      }),
    }),
  }
  ignore(GateCounter::from_checkpoint(legacy))
  for track in checkpoint.tracks {
    for index, anchor in track.anchors {
      if anchor is Some(anchor) {
        anchor.covariance.validate()
        let row = gate_evidence(
          restored.gates[index],
          track.track_id,
          track.segment_id,
          anchor.point_m,
          anchor.covariance,
          restored.sigma_multiplier,
        )
        if row.side == 0 {
          raise @types.InvalidInput(
            "saved evidence anchor does not establish a stable side",
          )
        }
      }
    }
    restored.tracks[track.track_id] = copy_evidence_track(track)
  }
  restored.counts = checkpoint.counts.copy()
  restored.last_timestamp = checkpoint.last_timestamp_us
  restored
}

///|
pub fn EvidenceGateCounter::fork(
  self : EvidenceGateCounter,
) -> EvidenceGateCounter {
  {
    session_id: self.session_id,
    gates: self.gates.copy(),
    config: self.config,
    sigma_multiplier: self.sigma_multiplier,
    last_timestamp: self.last_timestamp,
    counts: self.counts.copy(),
    tracks: self.tracks.copy(),
  }
}
