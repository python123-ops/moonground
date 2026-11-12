///|
/// The complete fixed measurement configuration and committed motion state.
pub(all) enum AnalysisMeasurement {
  Pixel(@moonground.MeasurementCheckpoint)
  Ground(@motion.MotionCheckpoint)
} derive(Debug)

///|
pub extend AnalysisMeasurement with @debug.Debug::{to_repr}

///|
/// A single watermark for both measurement and metric gate counting. Exported
/// arrays are detached; restoration validates each state and their relationship.
pub(all) struct AnalysisCheckpoint {
  version : Int32
  measurement : AnalysisMeasurement
  counting : @events.GateCheckpoint
} derive(Debug)

///|
pub extend AnalysisCheckpoint with @debug.Debug::{to_repr}

///|
/// A committed measurement frame and the gate events derived from that frame.
pub(all) struct AnalysisFrame {
  measurement : @moonground.MeasurementFrame
  counting : @events.GateFrame
} derive(Debug)

///|
pub extend AnalysisFrame with @debug.Debug::{to_repr}

///|
priv enum MeasurementEngine {
  Pixel(@moonground.MeasurementSession)
  Ground(@motion.MotionEstimator)
}

///|
/// Owns one pixel or metric measurement stream and its gate counter. A failed
/// update leaves both engines, their watermark and segment allocation unchanged.
pub struct AnalysisSession {
  priv mut measurement : MeasurementEngine
  priv mut counting : @events.GateCounter
}
