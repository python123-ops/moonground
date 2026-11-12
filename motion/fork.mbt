///|
/// Create an independent branch at the same committed frame. Accepted track
/// buffers are shared internally until replacement; neither branch mutates them.
pub fn MotionEstimator::fork(self : MotionEstimator) -> MotionEstimator {
  {
    session_id: self.session_id,
    config: self.config,
    tracks: self.tracks.copy(),
    last_timestamp: self.last_timestamp,
    next_segment: self.next_segment,
  }
}
