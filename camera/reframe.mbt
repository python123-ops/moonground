///|
/// Express raw and rectified image coordinates in destination pixels p'=D p+t.
/// Brown distortion and its certified normalized-coordinate disk are unchanged.
pub fn CameraModel::reframed(
  self : CameraModel,
  transform : @types.PixelTransform,
) -> CameraModel raise @types.GroundError {
  let d = self.distortion
  CameraModel::new(
    fx=transform.scale_x * self.fx,
    fy=transform.scale_y * self.fy,
    cx=transform.scale_x * self.cx + transform.offset_x,
    cy=transform.scale_y * self.cy + transform.offset_y,
    k1=d.k1,
    k2=d.k2,
    p1=d.p1,
    p2=d.p2,
    k3=d.k3,
    max_normalized_radius=self.radius,
  )
}
