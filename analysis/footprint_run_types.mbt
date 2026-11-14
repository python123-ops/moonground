///|
/// Committed original measurement and exact-bound footprint evidence runs.
pub(all) struct FootprintRunSessionFrame {
  measurement : @moonground.MeasurementFrame
  runs : @zones.FootprintRunFrame
} derive(Debug)

///|
pub extend FootprintRunSessionFrame with @debug.Debug::{to_repr}

///|
/// Complete committed state. Prepared candidates are never checkpoints.
pub(all) struct FootprintRunSessionCheckpoint {
  version : Int32
  measurement : AnalysisMeasurement
  runs : @zones.FootprintRunCheckpoint
}

///|
pub struct FootprintRunSession {
  priv mut measurement : MeasurementEngine
  priv runs : @zones.FootprintRunMonitor
  priv mut last_timestamp : Int64?
}

///|
/// One uncommitted measurement bound to the original owner and its watermark.
/// The candidate exposes no mutable engine or serializable provisional state.
pub struct FootprintRunPreparation {
  priv owner : FootprintRunSession
  priv baseline : Int64?
  priv candidate : MeasurementEngine
  priv frame : @moonground.MeasurementFrame
  priv mut used : Bool
}
