///|
/// Axis-aligned pixel coordinates p' = (scale_x*x + offset_x,
/// scale_y*y + offset_y). Positive scales preserve image orientation. This
/// changes coordinates for resize, crop or padding; it does not resample images.
pub struct PixelTransform {
  scale_x : Double
  scale_y : Double
  offset_x : Double
  offset_y : Double
} derive(Debug)

///|
pub extend PixelTransform with @debug.Debug::{to_repr}

///|
/// Construct a finite transformation with strictly positive axis scales.
pub fn PixelTransform::new(
  scale_x~ : Double = 1.0,
  scale_y~ : Double = 1.0,
  offset_x~ : Double = 0.0,
  offset_y~ : Double = 0.0,
) -> PixelTransform raise GroundError {
  if !is_finite(scale_x) ||
    !is_finite(scale_y) ||
    scale_x <= 0.0 ||
    scale_y <= 0.0 ||
    !is_finite(offset_x) ||
    !is_finite(offset_y) {
    raise InvalidInput(
      "pixel scales must be finite and positive; offsets must be finite",
    )
  }
  { scale_x, scale_y, offset_x, offset_y, }
}

///|
/// Transform a finite source pixel into destination pixel coordinates.
pub fn PixelTransform::point(
  self : PixelTransform,
  point : Point2,
) -> Point2 raise GroundError {
  point.validate()
  Point2::new(
    self.scale_x * point.x + self.offset_x,
    self.scale_y * point.y + self.offset_y,
  )
}

///|
/// Propagate pixel covariance as D Sigma D^T; translation adds no noise.
pub fn PixelTransform::covariance(
  self : PixelTransform,
  covariance : Covariance2,
) -> Covariance2 raise GroundError {
  covariance.validate()
  Covariance2::new(
    self.scale_x * covariance.xx * self.scale_x,
    self.scale_x * covariance.xy * self.scale_y,
    self.scale_y * covariance.yy * self.scale_y,
  )
}

///|
/// Invert coordinates, rejecting an unrepresentable inverse.
pub fn PixelTransform::inverse(
  self : PixelTransform,
) -> PixelTransform raise GroundError {
  PixelTransform::new(
    scale_x=1.0 / self.scale_x,
    scale_y=1.0 / self.scale_y,
    offset_x=-self.offset_x / self.scale_x,
    offset_y=-self.offset_y / self.scale_y,
  )
}

///|
/// Compose in application order: self.then(next).point(p) = next(self(p)).
pub fn PixelTransform::then(
  self : PixelTransform,
  next : PixelTransform,
) -> PixelTransform raise GroundError {
  PixelTransform::new(
    scale_x=next.scale_x * self.scale_x,
    scale_y=next.scale_y * self.scale_y,
    offset_x=next.scale_x * self.offset_x + next.offset_x,
    offset_y=next.scale_y * self.offset_y + next.offset_y,
  )
}
