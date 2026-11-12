///|
/// Create an independent branch at the same event watermark and totals.
/// Anchor arrays are immutable inside the counter and replaced on every update.
pub fn GateCounter::fork(self : GateCounter) -> GateCounter {
  {
    session_id: self.session_id,
    gates: self.gates.copy(),
    config: self.config,
    last_timestamp: self.last_timestamp,
    counts: self.counts.copy(),
    tracks: self.tracks.copy(),
  }
}
