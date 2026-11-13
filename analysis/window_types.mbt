///|
/// One original measurement/transit frame and its confirmation-window update.
pub(all) struct EvidenceTransitWindowSessionFrame {
  analysis : EvidenceTransitSessionFrame
  windows : @transit.EvidenceTransitWindowFrame
} derive(Debug)

///|
pub extend EvidenceTransitWindowSessionFrame with @debug.Debug::{to_repr}

///|
/// Complete upstream and statistics state at one committed watermark.
/// Restore checks necessary saved-state relationships, not historical origin.
pub(all) struct EvidenceTransitWindowSessionCheckpoint {
  version : Int32
  analysis : EvidenceTransitSessionCheckpoint
  windows : @transit.EvidenceTransitWindowCheckpoint
} derive(Debug)

///|
pub extend EvidenceTransitWindowSessionCheckpoint with @debug.Debug::{to_repr}

///|
/// Joint recovery and atomic updates for raw observations and fixed windows.
/// It retains one upstream measurement/transit owner, without another counter.
pub struct EvidenceTransitWindowSession {
  priv mut analysis : EvidenceTransitSession
  priv windows : @transit.EvidenceTransitWindowCounter
}
