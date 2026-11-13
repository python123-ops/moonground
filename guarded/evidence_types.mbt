///|
/// One committed calibration-health decision and covariance-evidence analysis.
/// A blocked frame has no objects or current evidence and closes old segments.
pub(all) struct EvidenceGuardedFrame {
  decision : GuardDecision
  health : @health.HealthReport
  analysis : @analysis.EvidenceAnalysisFrame
  suppressed_track_ids : Array[Int32]
} derive(Debug)

///|
pub extend EvidenceGuardedFrame with @debug.Debug::{to_repr}

///|
/// Complete health, pixel motion and original covariance-evidence anchors at
/// one watermark. It is distinct from the legacy mean-counting checkpoint.
pub(all) struct EvidenceGuardedCheckpoint {
  version : Int32
  analysis : @analysis.EvidenceAnalysisCheckpoint
  health : @health.HealthCheckpoint
} derive(Debug)

///|
pub extend EvidenceGuardedCheckpoint with @debug.Debug::{to_repr}

///|
/// A peer of GuardedSession with explicit covariance-evidence counting. Its
/// analysis owns pixel motion and its evidence counter directly; fatal errors
/// preserve all three components, including landmark confirmation progress.
pub struct EvidenceGuardedSession {
  priv mut analysis : @analysis.EvidenceAnalysisSession
  priv mut health : @health.CalibrationMonitor
  priv max_tracks : Int32
}
