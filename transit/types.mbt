///|
/// One directional journey between two distinct configured finite gates.
/// It declares no route length and does not infer actual travelled distance.
pub struct Section {
  section_id : String
  entry_gate_id : String
  entry_direction : @events.CrossingDirection
  exit_gate_id : String
  exit_direction : @events.CrossingDirection
} derive(Debug)

///|
pub extend Section with @debug.Debug::{to_repr}

///|
pub fn Section::new(
  section_id : String,
  entry_gate_id : String,
  entry_direction : @events.CrossingDirection,
  exit_gate_id : String,
  exit_direction : @events.CrossingDirection,
) -> Section raise @types.GroundError {
  for id in [section_id, entry_gate_id, exit_gate_id] {
    if id.length() < 1 || id.length() > 128 {
      raise @types.InvalidInput(
        "section identities require 1 to 128 UTF-16 code units",
      )
    }
  }
  if entry_gate_id == exit_gate_id {
    raise @types.InvalidInput("section entry and exit gates must differ")
  }
  { section_id, entry_gate_id, entry_direction, exit_gate_id, exit_direction, }
}

///|
pub(all) enum CancellationReason {
  Discontinuity
  Expired
  Reentered
  Reversed
  AmbiguousOrder
} derive(Debug, Eq)

///|
pub extend CancellationReason with @debug.Debug::{to_repr}

///|
pub extend CancellationReason with Eq::{equal, not_equal}

///|
pub(all) struct TransitCount {
  section_id : String
  completed : Int64
} derive(Debug)

///|
pub extend TransitCount with @debug.Debug::{to_repr}

///|
/// The original exact brackets enclose both chord crossing times. Integer
/// elapsed bounds are their conservative closure, not confidence intervals.
/// The positive estimate assumes linear time along the filtered chord(s).
pub(all) struct TransitPassage {
  section_id : String
  track_id : Int32
  segment_id : String
  entry : @events.GateCrossing
  exit : @events.GateCrossing
  elapsed_lower_us : Int64
  elapsed_upper_us : Int64
  estimated_elapsed_us : Double
} derive(Debug)

///|
pub extend TransitPassage with @debug.Debug::{to_repr}

///|
/// A discarded entry. Ambiguous simultaneous events also report the current
/// forward entry when no earlier pending entry exists, and retain no new entry.
pub(all) struct TransitCancellation {
  section_id : String
  track_id : Int32
  segment_id : String
  reason : CancellationReason
  entry : @events.GateCrossing
} derive(Debug)

///|
pub extend TransitCancellation with @debug.Debug::{to_repr}

///|
/// Arrays follow section configuration order, then track identity. Repeated
/// cancellations for one identity retain their causal order within the frame.
pub(all) struct TransitFrame {
  counting : @events.GateFrame
  passages : Array[TransitPassage]
  cancellations : Array[TransitCancellation]
  counts : Array[TransitCount]
  pending_count : Int32
} derive(Debug)

///|
pub extend TransitFrame with @debug.Debug::{to_repr}

///|
pub(all) struct TransitPending {
  section_id : String
  entry : @events.GateCrossing
} derive(Debug)

///|
pub extend TransitPending with @debug.Debug::{to_repr}

///|
pub(all) struct TransitCheckpoint {
  version : Int32
  counting : @events.GateCheckpoint
  sections : Array[Section]
  max_duration_us : Int64
  counts : Array[TransitCount]
  pending : Array[TransitPending]
} derive(Debug)

///|
pub extend TransitCheckpoint with @debug.Debug::{to_repr}

///|
pub struct TransitCounter {
  priv mut counting : @events.GateCounter
  priv sections : Array[Section]
  priv gates : Array[@events.LineGate]
  priv max_duration_us : Int64
  priv max_gap_us : Int64
  priv max_tracks : Int32
  priv mut last_timestamp_us : Int64?
  priv mut counts : Array[TransitCount]
  priv mut pending : Array[Map[Int32, @events.GateCrossing]]
}
