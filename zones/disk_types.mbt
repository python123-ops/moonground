///|
/// Explicit deterministic disk centered on the modeled ground anchor.
/// The radius describes physical extent separately from position covariance.
pub struct DiskFootprint {
  radius_m : Double
}

///|
pub(all) struct DiskZoneFaceBand {
  edge_index : Int32
  outward_normal : @types.Point2
  distance_m : Double
  normal_std_m : Double
  position_lower_m : Double
  position_upper_m : Double
  lower_m : Double
  upper_m : Double
} derive(Debug)

///|
pub extend DiskZoneFaceBand with @debug.Debug::{to_repr}

///|
/// Supporting-line bounds for the position perturbation set plus an explicit
/// disk. Outside is sufficient face separation; Indeterminate is not contact.
pub(all) struct DiskZoneBand {
  zone_id : String
  radius_m : Double
  sigma_multiplier : Double
  faces : Array[DiskZoneFaceBand]
  decision : ZoneDecision
  separating_edge_index : Int32?
} derive(Debug)

///|
pub extend DiskZoneBand with @debug.Debug::{to_repr}

///|
pub(all) struct DiskZoneEvidence {
  track_id : Int32
  segment_id : String
  evidence : DiskZoneBand
} derive(Debug)

///|
pub extend DiskZoneEvidence with @debug.Debug::{to_repr}

///|
pub(all) struct DiskZoneEvidenceFrame {
  session_id : String
  timestamp_us : Int64
  evidence : Array[DiskZoneEvidence]
  unavailable : Array[ZoneUnavailable]
} derive(Debug)

///|
pub extend DiskZoneEvidenceFrame with @debug.Debug::{to_repr}
