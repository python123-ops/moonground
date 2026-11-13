///|
/// Detach the existing analysis and begin statistics at its current baseline.
/// Earlier completed outcomes are not filled into a new statistics window.
pub fn EvidenceTransitWindowSession::new(
  analysis : EvidenceTransitSession,
  window_us~ : Int64,
  duration_limits_us~ : Array[Int64],
  origin_us~ : Int64 = 0L,
) -> EvidenceTransitWindowSession raise @types.GroundError {
  let saved = analysis.checkpoint()
  let analysis = EvidenceTransitSession::from_checkpoint(saved)
  let windows = @transit.EvidenceTransitWindowCounter::new(
    saved.transit,
    window_us~,
    duration_limits_us~,
    origin_us~,
  )
  { analysis, windows, }
}

///|
pub fn EvidenceTransitWindowSession::checkpoint(
  self : EvidenceTransitWindowSession,
) -> EvidenceTransitWindowSessionCheckpoint {
  {
    version: 1,
    analysis: self.analysis.checkpoint(),
    windows: self.windows.checkpoint(),
  }
}

///|
pub fn EvidenceTransitWindowSession::fork(
  self : EvidenceTransitWindowSession,
) -> EvidenceTransitWindowSession {
  { analysis: self.analysis.fork(), windows: self.windows.fork(), }
}

///|
/// Stage the upstream owner without exporting a checkpoint. The window update
/// is atomic; only its success commits the upstream candidate to this owner.
pub fn EvidenceTransitWindowSession::update_pixel(
  self : EvidenceTransitWindowSession,
  timestamp_us : Int64,
  observations : Array[@moonground.PixelObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> EvidenceTransitWindowSessionFrame raise @types.GroundError {
  let analysis = self.analysis.fork()
  let frame = analysis.update_pixel(timestamp_us, observations, lost~, removed~)
  let windows = self.windows.update(frame.transit)
  self.analysis = analysis
  { analysis: frame, windows, }
}

///|
pub fn EvidenceTransitWindowSession::update_ground(
  self : EvidenceTransitWindowSession,
  timestamp_us : Int64,
  observations : Array[@types.GroundObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> EvidenceTransitWindowSessionFrame raise @types.GroundError {
  let analysis = self.analysis.fork()
  let frame = analysis.update_ground(
    timestamp_us,
    observations,
    lost~,
    removed~,
  )
  let windows = self.windows.update(frame.transit)
  self.analysis = analysis
  { analysis: frame, windows, }
}

///|
/// Close every active segment, including hidden filters, and count that same
/// empty confirmation frame and its pending-entry cancellations exactly once.
pub fn EvidenceTransitWindowSession::interrupt(
  self : EvidenceTransitWindowSession,
  timestamp_us : Int64,
) -> EvidenceTransitWindowSessionFrame raise @types.GroundError {
  let analysis = self.analysis.fork()
  let frame = analysis.interrupt(timestamp_us)
  let windows = self.windows.update(frame.transit)
  self.analysis = analysis
  { analysis: frame, windows, }
}

///|
/// Re-express pixel input while preserving all metric and window state.
/// Ground analysis has no pixel coordinates and retains its original error.
pub fn EvidenceTransitWindowSession::reframed(
  self : EvidenceTransitWindowSession,
  transform : @types.PixelTransform,
) -> EvidenceTransitWindowSession raise @types.GroundError {
  { analysis: self.analysis.reframed(transform), windows: self.windows.fork(), }
}
