///|
/// One committed health decision, pixel motion, covariance evidence and
/// interval result. Blocked frames close active segments and cancel entries.
pub(all) struct EvidenceGuardedTransitFrame {
  decision : GuardDecision
  health : @health.HealthReport
  analysis : @analysis.EvidenceTransitSessionFrame
  suppressed_track_ids : Array[Int32]
} derive(Debug)

///|
pub extend EvidenceGuardedTransitFrame with @debug.Debug::{to_repr}

///|
/// Complete health and evidence-transit analysis at one committed watermark.
/// Saved evidence is checked for local consistency, not history authenticity.
pub(all) struct EvidenceGuardedTransitCheckpoint {
  version : Int32
  analysis : @analysis.EvidenceTransitSessionCheckpoint
  health : @health.HealthCheckpoint
} derive(Debug)

///|
pub extend EvidenceGuardedTransitCheckpoint with @debug.Debug::{to_repr}

///|
/// Owns one pixel measurement engine and one evidence transit counter through
/// its joint analysis. Fatal failures also preserve health confirmation state.
pub struct EvidenceGuardedTransitSession {
  priv mut analysis : @analysis.EvidenceTransitSession
  priv mut health : @health.CalibrationMonitor
  priv max_tracks : Int32
}
