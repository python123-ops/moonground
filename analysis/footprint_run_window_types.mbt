///|
/// Original measurement and its atomically committed visual run windows.
pub(all) struct FootprintRunWindowSessionFrame {
  measurement : @moonground.MeasurementFrame
  windows : @zones.FootprintRunWindowFrame
} derive(Debug)

///|
pub extend FootprintRunWindowSessionFrame with @debug.Debug::{to_repr}

///|
/// Committed measurement and a single complete run/window state.
pub(all) struct FootprintRunWindowSessionCheckpoint {
  version : Int32
  measurement : AnalysisMeasurement
  windows : @zones.FootprintRunWindowCheckpoint
}

///|
pub struct FootprintRunWindowSession {
  priv mut measurement : MeasurementEngine
  priv windows : @zones.FootprintRunWindowMonitor
  priv mut last_timestamp : Int64?
}

///|
/// A candidate bound to one owner and its unchanged committed watermark.
pub struct FootprintRunWindowPreparation {
  priv owner : FootprintRunWindowSession
  priv baseline : Int64?
  priv candidate : MeasurementEngine
  priv frame : @moonground.MeasurementFrame
  priv mut used : Bool
}
