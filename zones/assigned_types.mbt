///|
/// Explicit physical shape for one current target, already in ground units.
pub(all) enum FootprintShape {
  Disk(DiskFootprint)
  Convex(ConvexFootprint)
}

///|
/// A shape bound to an exact reported target and motion segment.
pub struct FootprintAssignment {
  track_id : Int32
  segment_id : String
  priv shape : FootprintShape
}

///|
/// Detached assignments for one exact timestamp. This is an immutable value,
/// not a retained identity map or a session with an advancing clock.
pub struct FootprintAssignments {
  timestamp_us : Int64
  priv assignments : Array[FootprintAssignment]
}

///|
pub(all) enum AssignedFootprintBand {
  Disk(DiskZoneBand)
  Convex(FootprintZoneBand)
} derive(Debug)

///|
pub extend AssignedFootprintBand with @debug.Debug::{to_repr}

///|
pub(all) struct AssignedFootprintEvidence {
  track_id : Int32
  segment_id : String
  evidence : AssignedFootprintBand
} derive(Debug)

///|
pub extend AssignedFootprintEvidence with @debug.Debug::{to_repr}

///|
pub(all) enum AssignedFootprintUnavailableReason {
  Position(ZoneUnavailableReason)
  MissingFootprint
} derive(Debug, Eq)

///|
pub extend AssignedFootprintUnavailableReason with @debug.Debug::{to_repr}

///|
pub extend AssignedFootprintUnavailableReason with Eq::{equal, not_equal}

///|
pub(all) struct AssignedFootprintUnavailable {
  track_id : Int32
  segment_id : String?
  reason : AssignedFootprintUnavailableReason
} derive(Debug)

///|
pub extend AssignedFootprintUnavailable with @debug.Debug::{to_repr}

///|
pub(all) struct AssignedFootprintZoneEvidenceFrame {
  session_id : String
  timestamp_us : Int64
  evidence : Array[AssignedFootprintEvidence]
  unavailable : Array[AssignedFootprintUnavailable]
} derive(Debug)

///|
pub extend AssignedFootprintZoneEvidenceFrame with @debug.Debug::{to_repr}
