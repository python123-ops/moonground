///|
/// A fixed, independently known landmark in the calibration's ground plane.
pub struct KnownLandmark {
  landmark_id : String
  ground_m : @types.Point2
} derive(Debug)

///|
pub extend KnownLandmark with @debug.Debug::{to_repr}

///|
fn validate_landmark_id(value : String) -> Unit raise @types.GroundError {
  if value.length() < 1 || value.length() > 128 {
    raise @types.InvalidInput(
      "landmark_id must contain 1 to 128 UTF-16 code units",
    )
  }
}

///|
pub fn KnownLandmark::new(
  landmark_id : String,
  ground_m : @types.Point2,
) -> KnownLandmark raise @types.GroundError {
  validate_landmark_id(landmark_id)
  ground_m.validate()
  { landmark_id, ground_m, }
}

///|
/// An observed fixed landmark. Pixel coordinates and covariance follow the
/// monitor's camera convention; detector confidence is not a covariance.
pub(all) struct LandmarkObservation {
  landmark_id : String
  pixel : @types.Point2
  covariance : @types.Covariance2
} derive(Debug)

///|
pub extend LandmarkObservation with @debug.Debug::{to_repr}

///|
pub fn LandmarkObservation::new(
  landmark_id : String,
  pixel : @types.Point2,
  covariance : @types.Covariance2,
) -> LandmarkObservation raise @types.GroundError {
  validate_landmark_id(landmark_id)
  pixel.validate()
  covariance.validate()
  { landmark_id, pixel, covariance, }
}

///|
pub fn LandmarkObservation::reframed(
  self : LandmarkObservation,
  transform : @types.PixelTransform,
) -> LandmarkObservation raise @types.GroundError {
  LandmarkObservation::new(
    self.landmark_id,
    transform.point(self.pixel),
    transform.covariance(self.covariance),
  )
}

///|
/// Metric tolerances and the required span of consecutive sampled evidence.
pub struct HealthConfig {
  min_landmarks : Int32
  rms_limit_m : Double
  max_error_m : Double
  confirmation_us : Int64
  min_observations : Int32
  max_gap_us : Int64
  max_position_std_m : Double?
} derive(Debug)

///|
pub extend HealthConfig with @debug.Debug::{to_repr}

///|
pub fn HealthConfig::new(
  min_landmarks~ : Int32 = 3,
  rms_limit_m~ : Double = 0.1,
  max_error_m~ : Double = 0.2,
  confirmation_us~ : Int64 = 300000L,
  min_observations~ : Int32 = 3,
  max_gap_us~ : Int64 = 500000L,
  max_position_std_m? : Double,
) -> HealthConfig raise @types.GroundError {
  if min_landmarks < 1 ||
    min_landmarks > 64 ||
    min_observations < 1 ||
    min_observations > 1000000 ||
    confirmation_us < 0L ||
    max_gap_us <= 0L {
    raise @types.InvalidInput("invalid landmark health limits")
  }
  if !@types.is_finite(rms_limit_m) ||
    rms_limit_m < 0.0 ||
    !@types.is_finite(max_error_m) ||
    max_error_m < 0.0 {
    raise @types.InvalidInput(
      "landmark metric tolerances must be finite and nonnegative",
    )
  }
  if max_position_std_m is Some(value) &&
    (!@types.is_finite(value) || value <= 0.0) {
    raise @types.InvalidInput(
      "landmark position uncertainty limit must be finite and positive",
    )
  }
  {
    min_landmarks,
    rms_limit_m,
    max_error_m,
    confirmation_us,
    min_observations,
    max_gap_us,
    max_position_std_m,
  }
}

///|
pub(all) enum CalibrationEvidence {
  Insufficient
  WithinTolerance
  BeyondTolerance
} derive(Debug, Eq)

///|
pub extend CalibrationEvidence with @debug.Debug::{to_repr}

///|
pub extend CalibrationEvidence with Eq::{equal, not_equal}

///|
pub(all) enum HealthStatus {
  Insufficient
  Pending
  Healthy
  Drift
} derive(Debug, Eq)

///|
pub extend HealthStatus with @debug.Debug::{to_repr}

///|
pub extend HealthStatus with Eq::{equal, not_equal}

///|
/// One configured landmark, including missing and rejected observations.
/// Residual is projected minus known ground position. A quality or numerical
/// rejection retains the available projection but contributes no residual.
pub(all) struct LandmarkResult {
  landmark_id : String
  projected_position_m : @types.Point2?
  projected_covariance : @types.Covariance2?
  residual_m : @types.Point2?
  error_m : Double?
  position_std_m : Double?
  rejection_reason : String?
} derive(Debug)

///|
pub extend LandmarkResult with @debug.Debug::{to_repr}

///|
/// Current-frame diagnostics and sampled evidence. Missing evidence never
/// carries forward a previous healthy or drift status.
pub(all) struct HealthReport {
  timestamp_us : Int64
  landmarks : Array[LandmarkResult]
  usable_count : Int32
  rms_error_m : Double?
  max_error_m : Double?
  evidence : CalibrationEvidence
  status : HealthStatus
  streak_since_us : Int64?
  streak_observations : Int32
} derive(Debug)

///|
pub extend HealthReport with @debug.Debug::{to_repr}

///|
/// Consecutive within- or beyond-tolerance samples. The observation count is
/// saturated at the configured minimum; it is not a lifetime frame counter.
pub(all) struct HealthStreak {
  evidence : CalibrationEvidence
  since_us : Int64
  observations : Int32
} derive(Debug)

///|
pub extend HealthStreak with @debug.Debug::{to_repr}

///|
/// Complete fixed configuration and the last committed evidence watermark.
pub(all) struct HealthCheckpoint {
  version : Int32
  calibration : @calibration.GroundCalibration
  camera : @camera.CameraModel?
  landmarks : Array[KnownLandmark]
  config : HealthConfig
  last_timestamp_us : Int64?
  streak : HealthStreak?
}

///|
pub impl @debug.Debug for HealthCheckpoint with fn to_repr(self) {
  @debug.Repr::Repr(
    (
      self.version,
      self.calibration.matrix(),
      self.calibration.roi(),
      self.camera,
      self.landmarks,
      self.config,
      self.last_timestamp_us,
      self.streak,
    ),
  )
}

///|
pub extend HealthCheckpoint with @debug.Debug::{to_repr}

///|
/// Checks independent fixed landmarks against one immutable physical calibration.
/// It neither refits that calibration nor changes object measurement sessions.
pub struct CalibrationMonitor {
  priv calibration : @calibration.GroundCalibration
  priv camera : @camera.CameraModel?
  priv landmarks : Array[KnownLandmark]
  priv known : Map[String, @types.Point2]
  priv config : HealthConfig
  priv mut last_timestamp : Int64?
  priv mut streak : HealthStreak?
}
