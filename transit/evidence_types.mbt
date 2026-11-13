///|
/// A pending confirmed entry and the original position covariances at its two
/// chord endpoints. They allow side evidence under the saved multiplier to be
/// checked again; they do not authenticate the observation history.
pub(all) struct EvidenceTransitPending {
  section_id : String
  entry : @events.GateCrossing
  from_covariance : @types.Covariance2
  to_covariance : @types.Covariance2
} derive(Debug)

///|
pub extend EvidenceTransitPending with @debug.Debug::{to_repr}

///|
/// A downstream evidence frame and conservative directional transit pairing.
/// Passage times describe filtered mean chords, not probability or route speed.
pub(all) struct EvidenceTransitFrame {
  counting : @events.EvidenceGateFrame
  passages : Array[TransitPassage]
  cancellations : Array[TransitCancellation]
  counts : Array[TransitCount]
  pending_count : Int32
} derive(Debug)

///|
pub extend EvidenceTransitFrame with @debug.Debug::{to_repr}

///|
pub(all) struct EvidenceTransitCheckpoint {
  version : Int32
  counting : @events.EvidenceGateCheckpoint
  sections : Array[Section]
  max_duration_us : Int64
  counts : Array[TransitCount]
  pending : Array[EvidenceTransitPending]
} derive(Debug)

///|
pub extend EvidenceTransitCheckpoint with @debug.Debug::{to_repr}

///|
/// Owns an evidence counter and interval pairing, not upstream measurement or
/// health. A failed frame preserves both downstream engines and their watermark.
pub struct EvidenceTransitCounter {
  priv mut counting : @events.EvidenceGateCounter
  priv sections : Array[Section]
  priv gates : Array[@events.LineGate]
  priv max_duration_us : Int64
  priv max_gap_us : Int64
  priv max_tracks : Int32
  priv mut last_timestamp_us : Int64?
  priv mut counts : Array[TransitCount]
  priv mut pending : Array[Map[Int32, EvidenceTransitPending]]
}
