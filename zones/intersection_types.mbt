///|
pub(all) enum ZoneIntersectionDecision {
  Disjoint
  Intersects
  Unresolved
} derive(Debug, Eq)

///|
pub extend ZoneIntersectionDecision with @debug.Debug::{to_repr}

///|
pub extend ZoneIntersectionDecision with Eq::{equal, not_equal}

///|
/// Outward bounds on the ellipse quadratic minimum over the closed polygon.
/// The witness fraction is an exact binary64 edge parameter; its world point
/// is rounded diagnostic output and is not asserted to be the exact minimizer.
pub(all) struct PositionZoneIntersection {
  zone_id : String
  sigma_multiplier : Double
  minimum_quadratic_lower : Double
  minimum_quadratic_upper : Double
  witness_edge_index : Int32?
  witness_fraction : Double?
  witness_position_m : @types.Point2
  decision : ZoneIntersectionDecision
} derive(Debug)

///|
pub extend PositionZoneIntersection with @debug.Debug::{to_repr}

///|
pub(all) struct PositionZoneIntersectionEvidence {
  track_id : Int32
  segment_id : String
  evidence : PositionZoneIntersection
} derive(Debug)

///|
pub extend PositionZoneIntersectionEvidence with @debug.Debug::{to_repr}

///|
pub(all) struct PositionZoneIntersectionFrame {
  session_id : String
  timestamp_us : Int64
  evidence : Array[PositionZoneIntersectionEvidence]
  unavailable : Array[ZoneUnavailable]
} derive(Debug)

///|
pub extend PositionZoneIntersectionFrame with @debug.Debug::{to_repr}
