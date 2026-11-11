///|
/// Versioned motion state after the last committed frame. Int64 fields must use
/// exact decimal strings in wire formats. Arrays are detached from the engine.
pub(all) struct MotionCheckpoint {
  version : Int32
  session_id : String
  config : MotionConfig
  last_timestamp_us : Int64?
  next_segment_id : Int64
  tracks : Array[TrackCheckpoint]
} derive(Debug)

///|
pub extend MotionCheckpoint with @debug.Debug::{to_repr}

///|
/// Accepted state of one active segment. Covariance uses row-major state order
/// [x, y, vx, vy]. Times refer to accepted observations, not missing frames.
pub(all) struct TrackCheckpoint {
  track_id : Int32
  segment_id : Int64
  first_timestamp_us : Int64
  last_timestamp_us : Int64
  accepted_count : Int32
  state : Array[Double]
  covariance : Array[Double]
  first_filtered : @types.Point2
  last_filtered : @types.Point2
  observed_path_length_m : Double
} derive(Debug)

///|
pub extend TrackCheckpoint with @debug.Debug::{to_repr}

///|
/// Copy bounded accepted state without changing frame time or segment allocation.
pub fn MotionEstimator::checkpoint(self : MotionEstimator) -> MotionCheckpoint {
  let tracks = self.tracks
    .values()
    .map(track => TrackCheckpoint::{
      track_id: track.track_id,
      segment_id: track.segment_id,
      first_timestamp_us: track.first_timestamp_us,
      last_timestamp_us: track.last_timestamp_us,
      accepted_count: track.accepted_count,
      state: track.state.copy(),
      covariance: flatten_covariance(track.covariance),
      first_filtered: track.first_filtered,
      last_filtered: track.last_filtered,
      observed_path_length_m: track.observed_path_length_m,
    })
    .collect()
  tracks.sort_by((a, b) => a.track_id.compare(b.track_id))
  {
    version: 1,
    session_id: self.session_id,
    config: self.config,
    last_timestamp_us: self.last_timestamp,
    next_segment_id: self.next_segment,
    tracks,
  }
}

///|
fn restored_track(
  checkpoint : TrackCheckpoint,
  frame_timestamp_us : Int64,
  next_segment_id : Int64,
  config : MotionConfig,
) -> TrackState raise @types.GroundError {
  if checkpoint.track_id <= 0 ||
    checkpoint.segment_id <= 0L ||
    checkpoint.segment_id >= next_segment_id {
    raise @types.InvalidInput("invalid checkpoint track or segment identity")
  }
  let first = checkpoint.first_timestamp_us
  let last = checkpoint.last_timestamp_us
  if first < 0L || last < first || last > frame_timestamp_us {
    raise @types.InvalidInput("invalid checkpoint accepted timestamps")
  }
  if frame_timestamp_us - last >= config.max_gap_us {
    raise @types.InvalidInput("checkpoint contains an expired track")
  }
  let count = checkpoint.accepted_count
  if count < 1 ||
    (count == 1) != (first == last) ||
    Int64::from_int(count - 1) > last - first {
    raise @types.InvalidInput("inconsistent checkpoint observation count")
  }
  if checkpoint.state.length() != 4 || checkpoint.covariance.length() != 16 {
    raise @types.InvalidInput("checkpoint requires state4 and covariance16")
  }
  let state = checkpoint.state.copy()
  let covariance = @kalman.Matrix::from_rows(
    Array::makei(4, row => {
      Array::makei(4, col => checkpoint.covariance[row * 4 + col])
    }),
  )
  if !healthy_state(state, covariance) ||
    covariance_block(covariance, 0) is None ||
    covariance_block(covariance, 2) is None ||
    !@types.is_finite(norm2(state[2], state[3])) {
    raise @types.InvalidInput("invalid checkpoint state or covariance")
  }
  checkpoint.first_filtered.validate()
  checkpoint.last_filtered.validate()
  if checkpoint.last_filtered.x != state[0] ||
    checkpoint.last_filtered.y != state[1] {
    raise @types.InvalidInput(
      "checkpoint last filtered point differs from state",
    )
  }
  let path = checkpoint.observed_path_length_m
  let displacement = norm2(
    checkpoint.last_filtered.x - checkpoint.first_filtered.x,
    checkpoint.last_filtered.y - checkpoint.first_filtered.y,
  )
  if !@types.is_finite(path) || path < 0.0 || !@types.is_finite(displacement) {
    raise @types.InvalidInput("invalid checkpoint filtered path")
  }
  let scale = if path > displacement { path } else { displacement }
  if scale > 0.0 && displacement / scale > path / scale + 0.000000001 {
    raise @types.InvalidInput("checkpoint displacement exceeds filtered path")
  }
  if count == 1 {
    let prior = config.initial_velocity_std * config.initial_velocity_std
    if path != 0.0 ||
      checkpoint.first_filtered.x != state[0] ||
      checkpoint.first_filtered.y != state[1] ||
      state[2] != 0.0 ||
      state[3] != 0.0 ||
      covariance.get(0, 1) != covariance.get(1, 0) ||
      covariance.get(2, 2) != prior ||
      covariance.get(3, 3) != prior {
      raise @types.InvalidInput("inconsistent initial checkpoint state")
    }
    for row in 0..<4 {
      for col in 0..<4 {
        if (
            (row < 2 && col >= 2) ||
            (row >= 2 && col < 2) ||
            (row >= 2 && col >= 2 && row != col)
          ) &&
          covariance.get(row, col) != 0.0 {
          raise @types.InvalidInput(
            "inconsistent initial checkpoint covariance",
          )
        }
      }
    }
  }
  {
    track_id: checkpoint.track_id,
    segment_id: checkpoint.segment_id,
    first_timestamp_us: first,
    last_timestamp_us: last,
    accepted_count: count,
    state,
    covariance,
    first_filtered: checkpoint.first_filtered,
    last_filtered: checkpoint.last_filtered,
    observed_path_length_m: path,
  }
}

///|
/// Restore a new engine only after the complete checkpoint validates. Original
/// covariance entries are preserved, including roundoff asymmetry; no filter
/// prediction, covariance repair or wall-clock expiration happens here.
pub fn MotionEstimator::from_checkpoint(
  checkpoint : MotionCheckpoint,
) -> MotionEstimator raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput("unsupported motion checkpoint version")
  }
  let source = checkpoint.config
  let config = MotionConfig::new(
    max_gap_us=source.max_gap_us,
    min_observations=source.min_observations,
    min_span_us=source.min_span_us,
    q=source.acceleration_spectral_density,
    initial_velocity_std=source.initial_velocity_std,
    gate=source.innovation_gate,
    max_tracks=source.max_tracks,
    max_position_std_m?=source.max_position_std_m,
    max_velocity_std_mps?=source.max_velocity_std_mps,
  )
  let estimator = MotionEstimator::new(checkpoint.session_id, config)
  if checkpoint.next_segment_id < 1L ||
    checkpoint.tracks.length() > config.max_tracks {
    raise @types.InvalidInput("invalid checkpoint segment counter or capacity")
  }
  let tracks : Map[Int32, TrackState] = Map([])
  let segments : Map[Int64, Bool] = Map([])
  match checkpoint.last_timestamp_us {
    None =>
      if checkpoint.tracks.length() != 0 || checkpoint.next_segment_id != 1L {
        raise @types.InvalidInput(
          "unstarted checkpoint contains allocated state",
        )
      }
    Some(timestamp) => {
      if timestamp < 0L {
        raise @types.InvalidInput(
          "checkpoint frame timestamp must be nonnegative",
        )
      }
      for track in checkpoint.tracks {
        if tracks.contains(track.track_id) ||
          segments.contains(track.segment_id) {
          raise @types.InvalidInput(
            "duplicate checkpoint track or segment identity",
          )
        }
        let restored = restored_track(
          track,
          timestamp,
          checkpoint.next_segment_id,
          config,
        )
        tracks[restored.track_id] = restored
        segments[restored.segment_id] = true
      }
    }
  }
  estimator.tracks = tracks
  estimator.last_timestamp = checkpoint.last_timestamp_us
  estimator.next_segment = checkpoint.next_segment_id
  estimator
}
