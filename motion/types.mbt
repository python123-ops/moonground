///|
/// Runtime limits and continuous white-acceleration model parameters.
pub struct MotionConfig {
  max_gap_us : Int64
  min_observations : Int32
  min_span_us : Int64
  acceleration_spectral_density : Double
  initial_velocity_std : Double
  innovation_gate : Double
  max_tracks : Int32
  max_position_std_m : Double?
  max_velocity_std_mps : Double?
} derive(Debug)

///|
pub extend MotionConfig with @debug.Debug::{to_repr}

///|
/// Configure SI-unit filtering. q has units m²/s³; timestamps use microseconds.
/// Optional one-sigma limits affect speed availability, not observation updates.
pub fn MotionConfig::new(
  max_gap_us~ : Int64 = 500000L,
  min_observations~ : Int32 = 3,
  min_span_us~ : Int64 = 300000L,
  q~ : Double = 1.0,
  initial_velocity_std~ : Double = 5.0,
  gate~ : Double = 9.210340371976184,
  max_tracks~ : Int32 = 1000,
  max_position_std_m? : Double,
  max_velocity_std_mps? : Double,
) -> MotionConfig raise @types.GroundError {
  if max_gap_us <= 0L ||
    min_observations < 2 ||
    min_span_us < 0L ||
    max_tracks <= 0 {
    raise @types.InvalidInput("invalid motion limits")
  }
  if !@types.is_finite(q) ||
    q < 0.0 ||
    !@types.is_finite(initial_velocity_std) ||
    initial_velocity_std <= 0.0 ||
    !@types.is_finite(initial_velocity_std * initial_velocity_std) ||
    initial_velocity_std * initial_velocity_std <= 0.0 ||
    !@types.is_finite(gate) ||
    gate <= 0.0 {
    raise @types.InvalidInput("invalid motion noise or innovation gate")
  }
  for threshold in [max_position_std_m, max_velocity_std_mps] {
    if threshold is Some(value) && (!@types.is_finite(value) || value <= 0.0) {
      raise @types.InvalidInput(
        "uncertainty limits must be finite and positive",
      )
    }
  }
  {
    max_gap_us,
    min_observations,
    min_span_us,
    acceleration_spectral_density: q,
    initial_velocity_std,
    innovation_gate: gate,
    max_tracks,
    max_position_std_m,
    max_velocity_std_mps,
  }
}

///|
pub fn MotionConfig::max_tracks(self : MotionConfig) -> Int32 {
  self.max_tracks
}

///|
/// Optional worst-direction one-sigma position limit in metres.
pub fn MotionConfig::max_position_std_m(self : MotionConfig) -> Double? {
  self.max_position_std_m
}

///|
/// Optional worst-direction one-sigma velocity limit in metres per second.
pub fn MotionConfig::max_velocity_std_mps(self : MotionConfig) -> Double? {
  self.max_velocity_std_mps
}

///|
/// Readiness refers to motion measurement, not availability of a filtered point.
/// Uncertain has completed warmup but exceeds an enabled uncertainty limit.
pub(all) enum MotionStatus {
  Initializing
  Ready
  Uncertain
  RejectedInnovation
  NumericalFailure
} derive(Debug, Eq)

///|
pub extend MotionStatus with @debug.Debug::{to_repr}

///|
pub extend MotionStatus with Eq::{equal, not_equal}

///|
/// A result for an observation submitted in this frame. Rejections carry no
/// stale position or velocity. Path length is the accepted filtered polyline,
/// and does not claim the object's unobserved travelled distance.
/// Each standard deviation is sqrt(lambda_max) of its 2 by 2 covariance.
/// Initializing has no velocity deviation; Uncertain retains accepted vectors
/// and deviations but withholds speed_mps.
pub(all) struct TrackEstimate {
  track_id : Int32
  segment_id : String
  status : MotionStatus
  position : @types.Point2?
  position_covariance : @types.Covariance2?
  velocity : @types.Point2?
  velocity_covariance : @types.Covariance2?
  position_std_m : Double?
  velocity_std_mps : Double?
  speed_mps : Double?
  observed_path_length_m : Double
  net_displacement_m : Double
  accepted_count : Int32
  last_accepted_timestamp_us : Int64
  filtered_state : Array[Double]?
  filtered_covariance : Array[Double]?
} derive(Debug)

///|
pub extend TrackEstimate with @debug.Debug::{to_repr}

///|
/// Segment identifiers are exact Int64 decimal strings within session_id.
pub(all) struct FrameResult {
  session_id : String
  timestamp_us : Int64
  tracks : Array[TrackEstimate]
  closed_segment_ids : Array[String]
} derive(Debug)

///|
pub extend FrameResult with @debug.Debug::{to_repr}
