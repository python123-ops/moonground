///|
/// Invalid input or a numerical failure at a measurement boundary.
pub(all) suberror GroundError {
  InvalidInput(String)
} derive(Debug)

///|
pub extend GroundError with @debug.Debug::{to_repr}

///|
/// Stable description suitable for a command-line diagnostic.
pub fn GroundError::message(self : GroundError) -> String {
  match self {
    InvalidInput(message) => message
  }
}

///|
/// Test a scalar before using it in geometry, time, or covariance arithmetic.
pub fn is_finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
/// Two-dimensional point, interpreted in the coordinate space of its API.
pub(all) struct Point2 {
  x : Double
  y : Double
} derive(Debug)

///|
pub extend Point2 with @debug.Debug::{to_repr}

///|
/// Construct a finite two-dimensional point.
pub fn Point2::new(x : Double, y : Double) -> Point2 raise GroundError {
  if !is_finite(x) || !is_finite(y) {
    raise InvalidInput("point coordinates must be finite")
  }
  { x, y, }
}

///|
/// Validate even values constructed through public record syntax.
pub fn Point2::validate(self : Point2) -> Unit raise GroundError {
  if !is_finite(self.x) || !is_finite(self.y) {
    raise InvalidInput("point coordinates must be finite")
  }
}

///|
/// Symmetric covariance matrix [[xx, xy], [xy, yy]].
pub(all) struct Covariance2 {
  xx : Double
  xy : Double
  yy : Double
} derive(Debug)

///|
pub extend Covariance2 with @debug.Debug::{to_repr}

///|
/// Construct a finite, positive-definite measurement covariance.
pub fn Covariance2::new(
  xx : Double,
  xy : Double,
  yy : Double,
) -> Covariance2 raise GroundError {
  let covariance = { xx, xy, yy, }
  covariance.validate()
  covariance
}

///|
/// Isotropic covariance from a strictly positive standard deviation.
pub fn Covariance2::isotropic(stddev : Double) -> Covariance2 raise GroundError {
  if !is_finite(stddev) || stddev <= 0.0 {
    raise InvalidInput("standard deviation must be finite and positive")
  }
  Covariance2::new(stddev * stddev, 0.0, stddev * stddev)
}

///|
/// Validate positive definiteness without overflowing a determinant product.
pub fn Covariance2::validate(self : Covariance2) -> Unit raise GroundError {
  if !is_finite(self.xx) ||
    !is_finite(self.xy) ||
    !is_finite(self.yy) ||
    self.xx <= 0.0 ||
    self.yy <= 0.0 {
    raise InvalidInput(
      "measurement covariance must be finite and positive definite",
    )
  }
  let scale = if self.xx > self.yy { self.xx } else { self.yy }
  let determinant = self.xx / scale * (self.yy / scale) -
    self.xy / scale * (self.xy / scale)
  if !is_finite(determinant) || determinant <= 0.0 {
    raise InvalidInput("measurement covariance must be positive definite")
  }
}

///|
/// A measured ground point and its covariance, in metres and metres squared.
pub(all) struct GroundObservation {
  track_id : Int32
  position : Point2
  covariance : Covariance2
} derive(Debug)

///|
pub extend GroundObservation with @debug.Debug::{to_repr}

///|
/// Build a validated ground observation with a positive object identity.
pub fn GroundObservation::new(
  track_id : Int32,
  position : Point2,
  covariance : Covariance2,
) -> GroundObservation raise GroundError {
  if track_id <= 0 {
    raise InvalidInput("track_id must be positive")
  }
  position.validate()
  covariance.validate()
  { track_id, position, covariance, }
}

///|
/// Revalidate observations submitted through public record syntax.
pub fn GroundObservation::validate(
  self : GroundObservation,
) -> Unit raise GroundError {
  ignore(GroundObservation::new(self.track_id, self.position, self.covariance))
}
