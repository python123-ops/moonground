///|
/// Confirmation thresholds for consecutive available evidence samples.
pub struct FootprintRunConfig {
  max_gap_us : Int64
  confirmation_us : Int64
  min_samples : Int64
}

///|
pub fn FootprintRunConfig::new(
  max_gap_us~ : Int64 = 500000L,
  confirmation_us~ : Int64 = 1000000L,
  min_samples~ : Int64 = 2L,
) -> FootprintRunConfig raise @types.GroundError {
  if max_gap_us <= 0L || confirmation_us < 0L || min_samples <= 0L {
    raise @types.InvalidInput("invalid footprint run confirmation limits")
  }
  { max_gap_us, confirmation_us, min_samples, }
}

///|
/// A sampled evidence sequence, not a physical visit or uninterrupted dwell.
pub(all) struct FootprintRun {
  zone_id : String
  track_id : Int32
  segment_id : String
  decision : ZoneDecision
  first_timestamp_us : Int64
  last_timestamp_us : Int64
  sample_count : Int64
  sample_span_us : Int64
  confirmed : Bool
} derive(Debug)

///|
pub extend FootprintRun with @debug.Debug::{to_repr}

///|
pub(all) enum FootprintRunEndReason {
  GapExceeded
  SegmentClosed
  SegmentChanged
  MissingTarget
  UnavailableEvidence
  ShapeChanged
  IndeterminateEvidence
  DecisionChanged
} derive(Debug, Eq)

///|
pub extend FootprintRunEndReason with @debug.Debug::{to_repr}

///|
pub extend FootprintRunEndReason with Eq::{equal, not_equal}

///|
pub(all) struct ClosedFootprintRun {
  run : FootprintRun
  closed_at_timestamp_us : Int64
  reason : FootprintRunEndReason
} derive(Debug)

///|
pub extend ClosedFootprintRun with @debug.Debug::{to_repr}

///|
pub(all) struct FootprintRunFrame {
  evidence : AssignedFootprintZoneEvidenceFrame
  active : Array[FootprintRun]
  confirmed : Array[FootprintRun]
  closed : Array[ClosedFootprintRun]
} derive(Debug)

///|
pub extend FootprintRunFrame with @debug.Debug::{to_repr}

///|
/// Retained current evidence anchor and exact explicitly assigned shape.
pub(all) struct FootprintRunState {
  run : FootprintRun
  shape : FootprintShape
  last_position_m : @types.Point2
  last_position_covariance : @types.Covariance2
}

///|
pub(all) struct FootprintRunCheckpoint {
  version : Int32
  session_id : String
  zones : Array[ConvexZone]
  max_tracks : Int32
  config : FootprintRunConfig
  last_timestamp_us : Int64?
  states : Array[FootprintRunState]
}

///|
/// Owns a projector and only current sampled runs, with no completed history.
pub struct FootprintRunMonitor {
  priv projector : ZoneProjector
  priv config : FootprintRunConfig
  priv mut last_timestamp : Int64?
  priv mut states : Array[FootprintRunState]
}
