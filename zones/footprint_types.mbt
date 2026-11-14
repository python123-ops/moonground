///|
/// Deterministic strictly convex body offsets, already oriented in the metric
/// ground frame. The modeled anchor belongs to the closed footprint.
pub struct ConvexFootprint {
  priv vertices : Array[@types.Point2]
}

///|
pub(all) struct FootprintZoneFaceBand {
  edge_index : Int32
  outward_normal : @types.Point2
  distance_m : Double
  normal_std_m : Double
  position_lower_m : Double
  position_upper_m : Double
  footprint_lower_m : Double
  footprint_upper_m : Double
  lower_m : Double
  upper_m : Double
} derive(Debug)

///|
pub extend FootprintZoneFaceBand with @debug.Debug::{to_repr}

///|
/// Position perturbation plus an explicit, possibly asymmetric convex body.
/// Outside proves separation by a face, not a complete intersection query.
pub(all) struct FootprintZoneBand {
  zone_id : String
  vertices_offset_m : Array[@types.Point2]
  sigma_multiplier : Double
  faces : Array[FootprintZoneFaceBand]
  decision : ZoneDecision
  separating_edge_index : Int32?
} derive(Debug)

///|
pub extend FootprintZoneBand with @debug.Debug::{to_repr}

///|
pub(all) struct FootprintZoneEvidence {
  track_id : Int32
  segment_id : String
  evidence : FootprintZoneBand
} derive(Debug)

///|
pub extend FootprintZoneEvidence with @debug.Debug::{to_repr}

///|
pub(all) struct FootprintZoneEvidenceFrame {
  session_id : String
  timestamp_us : Int64
  evidence : Array[FootprintZoneEvidence]
  unavailable : Array[ZoneUnavailable]
} derive(Debug)

///|
pub extend FootprintZoneEvidenceFrame with @debug.Debug::{to_repr}

///|
priv struct FootprintSupport {
  lower_m : Double
  upper_m : Double
}
