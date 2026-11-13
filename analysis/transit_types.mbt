///|
/// Complete measurement, covariance evidence and interval pairing at one
/// committed watermark. Historical evidence remains locally checkable state,
/// not an authenticated observation history.
pub(all) struct EvidenceTransitSessionCheckpoint {
  version : Int32
  measurement : AnalysisMeasurement
  transit : @transit.EvidenceTransitCheckpoint
} derive(Debug)

///|
pub extend EvidenceTransitSessionCheckpoint with @debug.Debug::{to_repr}

///|
/// One atomic measurement frame and its downstream evidence interval result.
pub(all) struct EvidenceTransitSessionFrame {
  measurement : @moonground.MeasurementFrame
  transit : @transit.EvidenceTransitFrame
} derive(Debug)

///|
pub extend EvidenceTransitSessionFrame with @debug.Debug::{to_repr}

///|
/// Owns the measurement engine and one evidence transit counter directly.
/// Failed downstream updates also preserve motion and segment allocation.
pub struct EvidenceTransitSession {
  priv mut measurement : MeasurementEngine
  priv transit : @transit.EvidenceTransitCounter
}
