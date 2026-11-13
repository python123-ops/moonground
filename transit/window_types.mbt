///|
/// Classification of closed elapsed intervals against an inclusive limit.
/// These are deterministic interval statements, not probability estimates.
pub(all) struct TransitDurationLimitCount {
  limit_us : Int64
  within : Int64
  exceeded : Int64
  indeterminate : Int64
} derive(Debug)

///|
pub extend TransitDurationLimitCount with @debug.Debug::{to_repr}

///|
pub(all) struct TransitCancellationCount {
  reason : CancellationReason
  count : Int64
} derive(Debug)

///|
pub extend TransitCancellationCount with @debug.Debug::{to_repr}

///|
pub(all) struct TransitWindowSection {
  section_id : String
  completed : Int64
  duration_limits : Array[TransitDurationLimitCount]
  cancellations : Array[TransitCancellationCount]
} derive(Debug)

///|
pub extend TransitWindowSection with @debug.Debug::{to_repr}

///|
/// Outcomes supplied at exact confirmation times in one fixed bucket.
/// A missing exclusive end means the mathematical end exceeds Int64.MAX.
/// Frame counts describe supplied samples, not continuous camera coverage.
pub(all) struct TransitWindow {
  start_us : Int64
  end_exclusive_us : Int64?
  first_timestamp_us : Int64
  last_timestamp_us : Int64
  input_frames : Int64
  sections : Array[TransitWindowSection]
} derive(Debug)

///|
pub extend TransitWindow with @debug.Debug::{to_repr}

///|
pub(all) struct EvidenceTransitWindowFrame {
  session_id : String
  timestamp_us : Int64
  closed_window : TransitWindow?
  current_window : TransitWindow
  unobserved_windows : Int64
} derive(Debug)

///|
pub extend EvidenceTransitWindowFrame with @debug.Debug::{to_repr}

///|
/// Bounded downstream statistics, without upstream tracks or pending entries.
/// The baseline is a checkpoint boundary, not an observed statistics frame.
pub(all) struct EvidenceTransitWindowCheckpoint {
  version : Int32
  session_id : String
  gates : Array[@events.LineGate]
  sections : Array[Section]
  config : @events.GateConfig
  sigma_multiplier : Double
  window_us : Int64
  origin_us : Int64
  duration_limits_us : Array[Int64]
  baseline_timestamp_us : Int64?
  baseline_counts : Array[TransitCount]
  last_timestamp_us : Int64?
  counts : Array[TransitCount]
  current_window : TransitWindow?
} derive(Debug)

///|
pub extend EvidenceTransitWindowCheckpoint with @debug.Debug::{to_repr}

///|
/// Fixed confirmation-time windows. It never owns or mutates the upstream
/// counter, and stores neither completed passage histories nor pending entries.
pub struct EvidenceTransitWindowCounter {
  priv session_id : String
  priv gates : Array[@events.LineGate]
  priv sections : Array[Section]
  priv config : @events.GateConfig
  priv sigma_multiplier : Double
  priv window_us : Int64
  priv origin_us : Int64
  priv duration_limits_us : Array[Int64]
  priv baseline_timestamp_us : Int64?
  priv baseline_counts : Array[TransitCount]
  priv mut last_timestamp_us : Int64?
  priv mut counts : Array[TransitCount]
  priv mut current_window : TransitWindow?
}
