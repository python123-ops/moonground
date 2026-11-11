///|
fn cross(a : @types.Point2, b : @types.Point2, p : @types.Point2) -> Double {
  (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
}

///|
fn make_roi(
  vertices : Array[@types.Point2],
) -> ConvexRoi raise @types.GroundError {
  if vertices.length() < 3 || vertices.length() > 64 {
    raise @types.GroundError::InvalidInput("ROI needs 3 to 64 convex vertices")
  }
  let first = vertices[0]
  first.validate()
  let mut low_x = first.x
  let mut low_y = first.y
  let mut high_x = first.x
  let mut high_y = first.y
  for point in vertices {
    point.validate()
    low_x = low_x.min(point.x)
    low_y = low_y.min(point.y)
    high_x = high_x.max(point.x)
    high_y = high_y.max(point.y)
  }
  let extent = (high_x - low_x).max(high_y - low_y)
  if !@types.is_finite(extent) || extent <= 0.0 {
    raise @types.GroundError::InvalidInput("ROI has no finite spatial extent")
  }
  let origin = @types.Point2::new(low_x, low_y)
  let normalized = vertices.map(fn(point) {
    @types.Point2::{
      x: (point.x - low_x) / extent,
      y: (point.y - low_y) / extent,
    }
  })
  let turn = cross(normalized[0], normalized[1], normalized[2])
  if !@types.is_finite(turn) || turn.abs() <= 1.0e-12 {
    raise @types.GroundError::InvalidInput("ROI must be strictly convex")
  }
  let orientation = if turn > 0.0 { 1.0 } else { -1.0 }
  // Every other vertex must lie strictly inside each directed edge. This also
  // rejects repeated vertices and self-intersecting stars with equal turns.
  for i in 0..<normalized.length() {
    let next = (i + 1) % normalized.length()
    for j in 0..<normalized.length() {
      if j != i &&
        j != next &&
        orientation * cross(normalized[i], normalized[next], normalized[j]) <=
        1.0e-12 {
        raise @types.GroundError::InvalidInput(
          "ROI must be simple, strictly convex and contain no repeated vertices",
        )
      }
    }
  }
  { vertices: vertices.copy(), normalized, origin, extent, orientation, }
}

///|
fn ConvexRoi::contains(self : ConvexRoi, point : @types.Point2) -> Bool {
  let p = @types.Point2::{
    x: (point.x - self.origin.x) / self.extent,
    y: (point.y - self.origin.y) / self.extent,
  }
  if !@types.is_finite(p.x) || !@types.is_finite(p.y) {
    return false
  }
  for i in 0..<self.normalized.length() {
    let side = self.orientation *
      cross(
        self.normalized[i],
        self.normalized[(i + 1) % self.normalized.length()],
        p,
      )
    if !@types.is_finite(side) || side < -1.0e-12 {
      return false
    }
  }
  true
}

///|
fn require_domain_point(
  domain : ConvexRoi,
  point : @types.Point2,
) -> Unit raise @types.GroundError {
  point.validate()
  if !domain.contains(point) {
    raise @types.GroundError::InvalidInput("point is outside calibration ROI")
  }
}
