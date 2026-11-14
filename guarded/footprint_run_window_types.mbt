///|
/// Current health and one atomic raw measurement, footprint run and window.
pub(all) struct FootprintRunWindowGuardedFrame {
  decision : GuardDecision
  health : @health.HealthReport
  analysis : @analysis.FootprintRunWindowSessionFrame
  suppressed_track_ids : Array[Int32]
} derive(Debug)

///|
pub extend FootprintRunWindowGuardedFrame with @debug.Debug::{to_repr}

///|
pub(all) struct FootprintRunWindowGuardedCheckpoint {
  version : Int32
  analysis : @analysis.FootprintRunWindowSessionCheckpoint
  health : @health.HealthCheckpoint
}

///|
pub struct FootprintRunWindowGuardedSession {
  priv mut analysis : @analysis.FootprintRunWindowSession
  priv mut health : @health.CalibrationMonitor
  priv max_tracks : Int32
  priv mut last_timestamp : Int64?
}

///|
priv enum FootprintRunWindowGuardedCandidate {
  Allowed(@analysis.FootprintRunWindowPreparation)
  Blocked(@analysis.FootprintRunWindowSessionFrame)
}

///|
/// Health and object candidates belong to their original unchanged owner.
pub struct FootprintRunWindowGuardedPreparation {
  priv owner : FootprintRunWindowGuardedSession
  priv baseline : Int64?
  priv analysis : @analysis.FootprintRunWindowSession
  priv health : @health.CalibrationMonitor
  priv report : @health.HealthReport
  priv candidate : FootprintRunWindowGuardedCandidate
  priv suppressed : Array[Int32]
  priv mut used : Bool
}
