///|
/// Whether the current landmark report permits object measurements under this
/// explicit policy. Allowed does not certify unobserved parts of the ground ROI.
pub(all) enum GuardDecision {
  Allowed
  Blocked
} derive(Debug, Eq)

///|
pub extend GuardDecision with @debug.Debug::{to_repr}

///|
pub extend GuardDecision with Eq::{equal, not_equal}

///|
/// One committed common frame. A blocked analysis contains no object estimates;
/// its closed segments show which earlier paths were ended by the policy.
pub(all) struct GuardedFrame {
  decision : GuardDecision
  health : @health.HealthReport
  analysis : @analysis.AnalysisFrame
  suppressed_track_ids : Array[Int32]
} derive(Debug)

///|
pub extend GuardedFrame with @debug.Debug::{to_repr}

///|
/// Complete health evidence and analysis state at the same frame watermark.
pub(all) struct GuardedCheckpoint {
  version : Int32
  analysis : @analysis.AnalysisCheckpoint
  health : @health.HealthCheckpoint
} derive(Debug)

///|
pub extend GuardedCheckpoint with @debug.Debug::{to_repr}

///|
/// Pixel analysis enabled only by the current frame's confirmed landmark health.
/// Both engines are owned independently of their constructor inputs.
pub struct GuardedSession {
  priv analysis : @analysis.AnalysisSession
  priv mut health : @health.CalibrationMonitor
  priv max_tracks : Int32
}
