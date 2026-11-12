///|
/// A finite directed segment in calibrated ground metres. Positive means left
/// of start_m -> end_m. Its closed deadband does not establish or change a side.
pub struct LineGate {
  gate_id : String
  start_m : @types.Point2
  end_m : @types.Point2
  deadband_m : Double
  priv unit_x : Double
  priv unit_y : Double
} derive(Debug)

///|
pub extend LineGate with @debug.Debug::{to_repr}

///|
/// Independent continuity, capacity and optional position-quality limits.
pub struct GateConfig {
  max_gap_us : Int64
  max_tracks : Int32
  max_position_std_m : Double?
} derive(Debug)

///|
pub extend GateConfig with @debug.Debug::{to_repr}

///|
pub fn GateConfig::new(
  max_gap_us~ : Int64 = 500000L,
  max_tracks~ : Int32 = 1000,
  max_position_std_m? : Double,
) -> GateConfig raise @types.GroundError {
  if max_gap_us <= 0L || max_tracks < 1 || max_tracks > 10000 {
    raise @types.InvalidInput("invalid gate continuity or track capacity")
  }
  if max_position_std_m is Some(value) &&
    (!@types.is_finite(value) || value <= 0.0) {
    raise @types.InvalidInput("gate position limit must be finite and positive")
  }
  { max_gap_us, max_tracks, max_position_std_m, }
}

///|
pub(all) enum CrossingDirection {
  NegativeToPositive
  PositiveToNegative
} derive(Debug, Eq)

///|
pub extend CrossingDirection with @debug.Debug::{to_repr}

///|
pub extend CrossingDirection with Eq::{equal, not_equal}

///|
/// Session totals. Counts include every confirmed crossing, including recrosses.
pub(all) struct GateCount {
  gate_id : String
  negative_to_positive : Int64
  positive_to_negative : Int64
} derive(Debug)

///|
pub extend GateCount with @debug.Debug::{to_repr}

///|
/// A crossing of the chord between two stable, opposite-side anchors. The
/// exact Int64 bracket and fractional position avoid floating absolute times.
/// to_timestamp_us is the confirmation frame, after the deadband is cleared.
pub(all) struct GateCrossing {
  gate_id : String
  track_id : Int32
  segment_id : String
  direction : CrossingDirection
  from_timestamp_us : Int64
  to_timestamp_us : Int64
  from_position_m : @types.Point2
  to_position_m : @types.Point2
  position_m : @types.Point2
  crossing_fraction : Double
} derive(Debug)

///|
pub extend GateCrossing with @debug.Debug::{to_repr}

///|
/// Events are ordered by track identity, then the configured gate order.
pub(all) struct GateFrame {
  session_id : String
  timestamp_us : Int64
  crossings : Array[GateCrossing]
  counts : Array[GateCount]
} derive(Debug)

///|
pub extend GateFrame with @debug.Debug::{to_repr}

///|
pub(all) struct GateAnchor {
  timestamp_us : Int64
  point_m : @types.Point2
} derive(Debug)

///|
pub extend GateAnchor with @debug.Debug::{to_repr}

///|
/// An entry exists only for a position accepted in the latest input frame.
pub(all) struct GateTrackCheckpoint {
  track_id : Int32
  segment_id : String
  anchors : Array[GateAnchor?]
} derive(Debug)

///|
pub extend GateTrackCheckpoint with @debug.Debug::{to_repr}

///|
/// Independent event state, detached from both the counter and motion state.
pub(all) struct GateCheckpoint {
  version : Int32
  session_id : String
  gates : Array[LineGate]
  config : GateConfig
  last_timestamp_us : Int64?
  counts : Array[GateCount]
  tracks : Array[GateTrackCheckpoint]
} derive(Debug)

///|
pub extend GateCheckpoint with @debug.Debug::{to_repr}
