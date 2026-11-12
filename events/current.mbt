///|
/// Whether the latest committed frame accepted this exact segment under this
/// counter's status and position-quality rules. Missing tracks return false.
pub fn GateCounter::has_current_track(
  self : GateCounter,
  track_id : Int32,
  segment_id : String,
) -> Bool {
  match self.tracks.get(track_id) {
    Some(track) => track.segment_id == segment_id
    None => false
  }
}

///|
/// Check a saved crossing against its directed finite gate and original chord.
/// This verifies geometry and exact stored fields, not historical authenticity.
pub fn GateCrossing::validate(
  self : GateCrossing,
  gate : LineGate,
) -> Unit raise @types.GroundError {
  validate_segment(self.segment_id)
  if self.gate_id != gate.gate_id ||
    self.track_id <= 0 ||
    self.from_timestamp_us < 0L ||
    self.to_timestamp_us <= self.from_timestamp_us ||
    !@types.is_finite(self.crossing_fraction) ||
    self.crossing_fraction <= 0.0 ||
    self.crossing_fraction >= 1.0 {
    raise @types.InvalidInput("invalid saved crossing identity or bracket")
  }
  self.from_position_m.validate()
  self.to_position_m.validate()
  self.position_m.validate()
  let from_side = gate.side(self.from_position_m)
  let to_side = gate.side(self.to_position_m)
  if from_side == 0 || to_side == 0 || from_side == to_side {
    raise @types.InvalidInput("saved crossing lacks opposite stable sides")
  }
  let expected = gate.crossing(
    { timestamp_us: self.from_timestamp_us, point_m: self.from_position_m, },
    { timestamp_us: self.to_timestamp_us, point_m: self.to_position_m, },
    self.track_id,
    self.segment_id,
  )
  guard expected is Some(expected) else {
    raise @types.InvalidInput("saved crossing misses the finite gate")
  }
  if self.direction != expected.direction ||
    self.crossing_fraction != expected.crossing_fraction ||
    self.position_m.x != expected.position_m.x ||
    self.position_m.y != expected.position_m.y {
    raise @types.InvalidInput("saved crossing differs from its chord geometry")
  }
}
