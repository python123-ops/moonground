///|
pub(all) enum VelocityDecision {
  Above
  AtOrBelow
  Indeterminate
} derive(Debug, Eq)

///|
pub extend VelocityDecision with @debug.Debug::{to_repr}

///|
pub extend VelocityDecision with Eq::{equal, not_equal}

///|
/// Signed velocity along one normalized metric direction and a fixed threshold.
pub struct VelocityProbe {
  probe_id : String
  direction : @types.Point2
  threshold_mps : Double
  sigma_multiplier : Double
} derive(Debug)

///|
pub extend VelocityProbe with @debug.Debug::{to_repr}

///|
/// A closed interval for the model velocity component, not Euclidean speed
/// or a probability statement. Equality belongs to AtOrBelow when upper<=limit.
pub(all) struct VelocityBand {
  probe_id : String
  component_mps : Double
  axis_std_mps : Double
  lower_mps : Double
  upper_mps : Double
  threshold_mps : Double
  sigma_multiplier : Double
  decision : VelocityDecision
} derive(Debug)

///|
pub extend VelocityBand with @debug.Debug::{to_repr}

///|
pub(all) struct VelocityEvidence {
  track_id : Int32
  segment_id : String
  evidence : VelocityBand
} derive(Debug)

///|
pub extend VelocityEvidence with @debug.Debug::{to_repr}

///|
pub(all) enum VelocityUnavailableReason {
  Initializing
  Uncertain
  RejectedInnovation
  NumericalFailure
  RejectedProjection
} derive(Debug, Eq)

///|
pub extend VelocityUnavailableReason with @debug.Debug::{to_repr}

///|
pub extend VelocityUnavailableReason with Eq::{equal, not_equal}

///|
pub(all) struct VelocityUnavailable {
  track_id : Int32
  segment_id : String?
  reason : VelocityUnavailableReason
} derive(Debug)

///|
pub extend VelocityUnavailable with @debug.Debug::{to_repr}

///|
/// Evaluation has no freshness clock. Independent frames may be replayed or
/// reordered, and no missing or rejected sample becomes an invented velocity.
pub(all) struct VelocityEvidenceFrame {
  session_id : String
  timestamp_us : Int64
  evidence : Array[VelocityEvidence]
  unavailable : Array[VelocityUnavailable]
} derive(Debug)

///|
pub extend VelocityEvidenceFrame with @debug.Debug::{to_repr}

///|
pub struct VelocityProjector {
  priv session_id : String
  priv probes : Array[VelocityProbe]
  priv max_tracks : Int32
}
