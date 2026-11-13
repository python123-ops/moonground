///|
/// Normal-direction covariance evidence for one current accepted target/gate.
/// The interval only establishes a stable side; it is not a probability,
/// finite-endpoint confidence interval or crossing-time confidence interval.
/// side is -1, 0 (unconfirmed), or 1, with closed interval/band boundaries.
pub(all) struct GateEvidence {
  track_id : Int32
  segment_id : String
  gate_id : String
  distance_m : Double
  normal_std_m : Double
  lower_m : Double
  upper_m : Double
  side : Int32
} derive(Debug)

///|
pub extend GateEvidence with @debug.Debug::{to_repr}

///|
/// Rows follow target identity, then gate configuration order. Rejected,
/// missing and position-quality-skipped targets have no current evidence row.
pub(all) struct EvidenceGateFrame {
  counting : GateFrame
  evidence : Array[GateEvidence]
} derive(Debug)

///|
pub extend EvidenceGateFrame with @debug.Debug::{to_repr}

///|
/// The covariance which established this stable side belongs to this exact
/// accepted point and timestamp. Unconfirmed points never refresh this anchor.
pub(all) struct EvidenceGateAnchor {
  timestamp_us : Int64
  point_m : @types.Point2
  covariance : @types.Covariance2
} derive(Debug)

///|
pub extend EvidenceGateAnchor with @debug.Debug::{to_repr}

///|
pub(all) struct EvidenceGateTrackCheckpoint {
  track_id : Int32
  segment_id : String
  anchors : Array[EvidenceGateAnchor?]
} derive(Debug)

///|
pub extend EvidenceGateTrackCheckpoint with @debug.Debug::{to_repr}

///|
/// A complete independent evidence policy and state. It cannot be downgraded
/// to GateCheckpoint without losing the policy and anchor covariances.
pub(all) struct EvidenceGateCheckpoint {
  version : Int32
  session_id : String
  gates : Array[LineGate]
  config : GateConfig
  sigma_multiplier : Double
  last_timestamp_us : Int64?
  counts : Array[GateCount]
  tracks : Array[EvidenceGateTrackCheckpoint]
} derive(Debug)

///|
pub extend EvidenceGateCheckpoint with @debug.Debug::{to_repr}

///|
/// An explicit downstream counter. Legacy GateCounter and its checkpoints
/// remain mean-position counters; neither silently adopts this policy.
pub struct EvidenceGateCounter {
  priv session_id : String
  priv gates : Array[LineGate]
  priv config : GateConfig
  priv sigma_multiplier : Double
  priv mut last_timestamp : Int64?
  priv mut counts : Array[GateCount]
  priv mut tracks : Map[Int32, EvidenceGateTrackCheckpoint]
}
