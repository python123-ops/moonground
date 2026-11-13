///|
/// Complete motion and normal-evidence counting at one committed watermark.
/// The legacy AnalysisCheckpoint remains a mean-position counting checkpoint.
pub(all) struct EvidenceAnalysisCheckpoint {
  version : Int32
  measurement : AnalysisMeasurement
  counting : @events.EvidenceGateCheckpoint
} derive(Debug)

///|
pub extend EvidenceAnalysisCheckpoint with @debug.Debug::{to_repr}

///|
/// One atomic measurement frame and the covariance evidence derived from it.
pub(all) struct EvidenceAnalysisFrame {
  measurement : @moonground.MeasurementFrame
  counting : @events.EvidenceGateFrame
} derive(Debug)

///|
pub extend EvidenceAnalysisFrame with @debug.Debug::{to_repr}

///|
/// A peer of AnalysisSession with explicit covariance-evidence counting.
/// It owns the measurement engine directly, not another analysis session.
pub struct EvidenceAnalysisSession {
  priv mut measurement : MeasurementEngine
  priv mut counting : @events.EvidenceGateCounter
}
