///|
/// End every active segment at this new frame time, clearing gate anchors
/// while retaining totals and the next segment identity. The frame is atomic
/// under the same capacity and timestamp rules as an ordinary update.
pub fn AnalysisSession::interrupt(
  self : AnalysisSession,
  timestamp_us : Int64,
) -> AnalysisFrame raise @types.GroundError {
  match self.measurement {
    Pixel(session) => {
      let removed = session.estimator.tracks.keys().collect()
      removed.sort()
      self.update_pixel(timestamp_us, [], removed~)
    }
    Ground(estimator) => {
      let removed = estimator.tracks.keys().collect()
      removed.sort()
      self.update_ground(timestamp_us, [], removed~)
    }
  }
}
