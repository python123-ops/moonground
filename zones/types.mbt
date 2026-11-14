///|
pub(all) enum ZoneDecision {
  Inside
  Outside
  Indeterminate
} derive(Debug, Eq)

///|
pub extend ZoneDecision with @debug.Debug::{to_repr}

///|
pub extend ZoneDecision with Eq::{equal, not_equal}

///|
/// Metric convex polygon, preserving the supplied vertex and edge order.
/// Vertices and outward normals are detached and remain private.
pub struct ConvexZone {
  zone_id : String
  sigma_multiplier : Double
  priv vertices : Array[@types.Point2]
  priv normals : Array[@types.Point2]
  priv orientation : Double
}

///|
pub(all) struct ZoneFaceBand {
  edge_index : Int32
  outward_normal : @types.Point2
  distance_m : Double
  normal_std_m : Double
  lower_m : Double
  upper_m : Double
} derive(Debug)

///|
pub extend ZoneFaceBand with @debug.Debug::{to_repr}

///|
/// Closed supporting-line bands. Outside proves separation by one face;
/// Indeterminate does not assert ellipse/polygon intersection at a corner.
pub(all) struct ZoneBand {
  zone_id : String
  sigma_multiplier : Double
  faces : Array[ZoneFaceBand]
  decision : ZoneDecision
  separating_edge_index : Int32?
} derive(Debug)

///|
pub extend ZoneBand with @debug.Debug::{to_repr}

///|
pub(all) struct ZoneEvidence {
  track_id : Int32
  segment_id : String
  evidence : ZoneBand
} derive(Debug)

///|
pub extend ZoneEvidence with @debug.Debug::{to_repr}

///|
pub(all) enum ZoneUnavailableReason {
  Initializing
  Uncertain
  RejectedInnovation
  NumericalFailure
  RejectedProjection
} derive(Debug, Eq)

///|
pub extend ZoneUnavailableReason with @debug.Debug::{to_repr}

///|
pub extend ZoneUnavailableReason with Eq::{equal, not_equal}

///|
pub(all) struct ZoneUnavailable {
  track_id : Int32
  segment_id : String?
  reason : ZoneUnavailableReason
} derive(Debug)

///|
pub extend ZoneUnavailable with @debug.Debug::{to_repr}

///|
pub(all) struct ZoneEvidenceFrame {
  session_id : String
  timestamp_us : Int64
  evidence : Array[ZoneEvidence]
  unavailable : Array[ZoneUnavailable]
} derive(Debug)

///|
pub extend ZoneEvidenceFrame with @debug.Debug::{to_repr}

///|
/// Independent current-frame evaluation without retained targets or a clock.
pub struct ZoneProjector {
  priv session_id : String
  priv zones : Array[ConvexZone]
  priv max_tracks : Int32
}
