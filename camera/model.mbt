///|
/// Immutable zero-skew pinhole intrinsics and Brown-Conrady distortion.
/// The radius bounds ideal (undistorted) normalized coordinates, not pixels.
pub struct CameraModel {
  priv fx : Double
  priv fy : Double
  priv cx : Double
  priv cy : Double
  priv distortion : @brown.Distortion
  priv radius : Double
  priv perturbation_bound : Double
} derive(Debug)

///|
pub extend CameraModel with @debug.Debug::{to_repr}

///|
fn norm2(x : Double, y : Double) -> Double {
  let scale = x.abs().max(y.abs())
  if scale == 0.0 {
    return 0.0
  }
  scale * (x / scale * (x / scale) + y / scale * (y / scale)).sqrt()
}

///|
/// Construct a camera whose forward normalized distortion has a unique inverse
/// branch on the specified closed disk. The analytic bound
/// 3|k1|R² + 5|k2|R⁴ + 7|k3|R⁶ + 6R sqrt(p1²+p2²) < 1
/// bounds ||J_distortion-I||₂ there. Since the Brown Jacobian is symmetric,
/// its eigenvalues are positive and the forward map is strongly monotone.
/// Unsafe parameters are rejected rather than selecting an arbitrary root.
pub fn CameraModel::new(
  fx~ : Double,
  fy~ : Double,
  cx~ : Double,
  cy~ : Double,
  k1~ : Double = 0.0,
  k2~ : Double = 0.0,
  p1~ : Double = 0.0,
  p2~ : Double = 0.0,
  k3~ : Double = 0.0,
  max_normalized_radius~ : Double = 1.0,
) -> CameraModel raise @types.GroundError {
  for value in [fx, fy, cx, cy, k1, k2, p1, p2, k3, max_normalized_radius] {
    if !@types.is_finite(value) {
      raise @types.InvalidInput("camera parameters must be finite")
    }
  }
  if fx <= 0.0 || fy <= 0.0 || max_normalized_radius <= 0.0 {
    raise @types.InvalidInput(
      "camera focal lengths and radius must be positive",
    )
  }
  let r = max_normalized_radius
  let r2 = r * r
  let r4 = r2 * r2
  let r6 = r4 * r2
  if !@types.is_finite(r6) || !@types.is_finite(r4) || !@types.is_finite(r2) {
    raise @types.InvalidInput(
      "camera radius exceeds finite distortion arithmetic",
    )
  }
  let bound = 3.0 * (k1.abs() * r2) +
    5.0 * (k2.abs() * r4) +
    7.0 * (k3.abs() * r6) +
    6.0 * (r * norm2(p1, p2))
  if !@types.is_finite(bound) ||
    bound >= 1.0 ||
    !@types.is_finite((1.0 + bound) * r) {
    raise @types.InvalidInput(
      "camera distortion cannot certify a unique inverse within radius",
    )
  }
  {
    fx,
    fy,
    cx,
    cy,
    distortion: @brown.Distortion::brown_conrady(k1~, k2~, p1~, p2~, k3~),
    radius: r,
    perturbation_bound: bound,
  }
}

///|
/// Defensive parameter copy: fx, fy, cx, cy, k1, k2, p1, p2, k3.
pub fn CameraModel::parameters(self : CameraModel) -> Array[Double] {
  let d = self.distortion
  [self.fx, self.fy, self.cx, self.cy, d.k1, d.k2, d.p1, d.p2, d.k3]
}

///|
pub fn CameraModel::max_normalized_radius(self : CameraModel) -> Double {
  self.radius
}
