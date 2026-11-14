///|
/// One committed health decision and its exact-bound footprint run result.
pub(all) struct FootprintRunGuardedFrame {
  decision : GuardDecision
  health : @health.HealthReport
  analysis : @analysis.FootprintRunSessionFrame
  suppressed_track_ids : Array[Int32]
} derive(Debug)

///|
pub extend FootprintRunGuardedFrame with @debug.Debug::{to_repr}

///|
/// Actual candidate identities; a Blocked candidate contains no object rows.
pub(all) struct FootprintRunGuardedPreview {
  decision : GuardDecision
  health : @health.HealthReport
  measurement : @moonground.MeasurementFrame
  suppressed_track_ids : Array[Int32]
} derive(Debug)

///|
pub extend FootprintRunGuardedPreview with @debug.Debug::{to_repr}

///|
pub(all) struct FootprintRunGuardedCheckpoint {
  version : Int32
  analysis : @analysis.FootprintRunSessionCheckpoint
  health : @health.HealthCheckpoint
}

///|
pub struct FootprintRunGuardedSession {
  priv mut analysis : @analysis.FootprintRunSession
  priv mut health : @health.CalibrationMonitor
  priv max_tracks : Int32
  priv mut last_timestamp : Int64?
}

///|
priv enum FootprintRunGuardedCandidate {
  Allowed(@analysis.FootprintRunPreparation)
  Blocked(@analysis.FootprintRunSessionFrame)
}

///|
/// Captures its original owner. Failed assignment commits remain retryable;
/// any successful update or replacement makes competing preparations stale.
pub struct FootprintRunGuardedPreparation {
  priv owner : FootprintRunGuardedSession
  priv baseline : Int64?
  priv analysis : @analysis.FootprintRunSession
  priv health : @health.CalibrationMonitor
  priv report : @health.HealthReport
  priv candidate : FootprintRunGuardedCandidate
  priv suppressed : Array[Int32]
  priv mut used : Bool
}
