///|
pub(all) struct FootprintRunWindowEndCount {
  reason : FootprintRunEndReason
  confirmed : Int64
  unconfirmed : Int64
} derive(Debug)

///|
pub extend FootprintRunWindowEndCount with @debug.Debug::{to_repr}

///|
pub(all) struct FootprintRunWindowZone {
  zone_id : String
  opening_active : Int64
  opening_confirmed : Int64
  started : Int64
  confirmed_inside : Int64
  confirmed_outside : Int64
  endings : Array[FootprintRunWindowEndCount]
} derive(Debug)

///|
pub extend FootprintRunWindowZone with @debug.Debug::{to_repr}

///|
/// Supplied outcome frames in one fixed time bucket, not continuous exposure.
pub(all) struct FootprintRunWindow {
  start_us : Int64
  end_exclusive_us : Int64?
  first_timestamp_us : Int64
  last_timestamp_us : Int64
  input_frames : Int64
  zones : Array[FootprintRunWindowZone]
} derive(Debug)

///|
pub extend FootprintRunWindow with @debug.Debug::{to_repr}

///|
pub(all) struct FootprintRunWindowStatistics {
  session_id : String
  timestamp_us : Int64
  closed_window : FootprintRunWindow?
  current_window : FootprintRunWindow
  unobserved_windows : Int64
} derive(Debug)

///|
pub extend FootprintRunWindowStatistics with @debug.Debug::{to_repr}

///|
pub(all) struct FootprintRunWindowFrame {
  runs : FootprintRunFrame
  statistics : FootprintRunWindowStatistics
} derive(Debug)

///|
pub extend FootprintRunWindowFrame with @debug.Debug::{to_repr}

///|
pub(all) struct FootprintRunWindowCheckpoint {
  version : Int32
  runs : FootprintRunCheckpoint
  window_us : Int64
  origin_us : Int64
  baseline_timestamp_us : Int64?
  current_window : FootprintRunWindow?
}

///|
/// Owns the original run monitor and one bounded outcome window. No completed
/// run history or upstream motion estimator is retained.
pub struct FootprintRunWindowMonitor {
  priv mut runs : FootprintRunMonitor
  priv window_us : Int64
  priv origin_us : Int64
  priv baseline_timestamp_us : Int64?
  priv mut current_window : FootprintRunWindow?
}
