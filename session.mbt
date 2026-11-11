///|
pub using @types {
  type Point2,
  type Covariance2,
  type GroundObservation,
  type GroundError,
  is_finite,
}

///|
pub using @calibration {type GroundCalibration}

///|
pub using @camera {type CameraModel}

///|
pub using @motion {type MotionConfig, type MotionEstimator}

///|
/// A finite measured pixel. With a camera model this uses raw image pixels;
/// otherwise it uses the same rectified pixel space as calibration.
pub(all) struct PixelObservation {
  track_id : Int32
  position : @types.Point2
  covariance : @types.Covariance2
}

///|
/// Validate a pixel observation; confidence scores are not measurement noise.
pub fn PixelObservation::new(
  track_id : Int32,
  position : @types.Point2,
  covariance : @types.Covariance2,
) -> PixelObservation raise @types.GroundError {
  ignore(@types.GroundObservation::new(track_id, position, covariance))
  { track_id, position, covariance, }
}

///|
/// A well-formed observation that could not be measured in this calibration.
pub(all) struct ProjectionFailure {
  track_id : Int32
  reason : String
}

///|
/// Motion results and per-target projection rejections for a committed frame.
pub(all) struct MeasurementFrame {
  motion : @motion.FrameResult
  projection_failures : Array[ProjectionFailure]
}

///|
/// One fixed calibration and one independently named object-measurement stream.
pub struct MeasurementSession {
  calibration : @calibration.GroundCalibration
  estimator : @motion.MotionEstimator
  max_tracks : Int32
  priv camera_model : @camera.CameraModel?
}

///|
/// Changing calibration requires a new session, preventing cross-calibration paths.
pub fn MeasurementSession::new(
  session_id : String,
  calibration : @calibration.GroundCalibration,
  config : @motion.MotionConfig,
  camera? : @camera.CameraModel,
) -> MeasurementSession raise @types.GroundError {
  {
    calibration,
    estimator: @motion.MotionEstimator::new(session_id, config),
    max_tracks: config.max_tracks(),
    camera_model: camera,
  }
}

///|
fn MeasurementSession::project_observation(
  self : MeasurementSession,
  observation : PixelObservation,
) -> @calibration.GroundPoint raise @types.GroundError {
  match self.camera_model {
    Some(camera) =>
      camera.project(
        self.calibration,
        observation.position,
        observation.covariance,
      )
    None =>
      self.calibration.project(observation.position, observation.covariance)
  }
}

///|
/// Validate the original identities before removing any unmeasurable observations.
pub fn MeasurementSession::update(
  self : MeasurementSession,
  timestamp_us : Int64,
  observations : Array[PixelObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> MeasurementFrame raise @types.GroundError {
  if observations.length() > self.max_tracks ||
    lost.length() > self.max_tracks ||
    removed.length() > self.max_tracks {
    raise @types.InvalidInput("frame exceeds target capacity")
  }
  let seen : Map[Int32, Bool] = Map([])
  for observation in observations {
    ignore(
      PixelObservation::new(
        observation.track_id,
        observation.position,
        observation.covariance,
      ),
    )
    if seen.contains(observation.track_id) {
      raise @types.InvalidInput("duplicate observation identity")
    }
    seen[observation.track_id] = true
  }
  for id in lost {
    if id <= 0 || seen.contains(id) {
      raise @types.InvalidInput(
        "lost identities must be positive, unique and disjoint",
      )
    }
    seen[id] = true
  }
  for id in removed {
    if id <= 0 || seen.contains(id) {
      raise @types.InvalidInput(
        "removed identities must be positive, unique and disjoint",
      )
    }
    seen[id] = true
  }
  let projected : Array[@types.GroundObservation] = []
  let failures : Array[ProjectionFailure] = []
  for observation in observations {
    let ground = self.project_observation(observation) catch {
      error => {
        failures.push({
          track_id: observation.track_id,
          reason: error.message(),
        })
        continue
      }
    }
    projected.push(
      @types.GroundObservation::new(
        observation.track_id,
        ground.position(),
        ground.covariance(),
      ),
    )
  }
  let result = self.estimator.update(timestamp_us, projected, lost~, removed~)
  { motion: result, projection_failures: failures, }
}

///|
/// Current bounded state count, including short pending observation gaps.
pub fn MeasurementSession::active_track_count(
  self : MeasurementSession,
) -> Int32 {
  self.estimator.active_track_count()
}
