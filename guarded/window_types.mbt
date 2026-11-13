///|
/// One original guarded decision and its confirmation-window update.
pub(all) struct EvidenceGuardedTransitWindowFrame {
  guarded : EvidenceGuardedTransitFrame
  windows : @transit.EvidenceTransitWindowFrame
} derive(Debug)

///|
pub extend EvidenceGuardedTransitWindowFrame with @debug.Debug::{to_repr}

///|
/// Complete guarded transit and statistics state at one committed watermark.
/// Necessary saved-state checks do not authenticate the observation history.
pub(all) struct EvidenceGuardedTransitWindowCheckpoint {
  version : Int32
  guarded : EvidenceGuardedTransitCheckpoint
  windows : @transit.EvidenceTransitWindowCheckpoint
} derive(Debug)

///|
pub extend EvidenceGuardedTransitWindowCheckpoint with @debug.Debug::{to_repr}

///|
/// Current health controls one joint measurement, transit and window owner.
pub struct EvidenceGuardedTransitWindowSession {
  priv mut analysis : @analysis.EvidenceTransitWindowSession
  priv mut health : @health.CalibrationMonitor
  priv max_tracks : Int32
}
