///|
fn area_half_product(a : Double, b : Double) -> Double raise @types.GroundError {
  if a == 0.0 || b == 0.0 {
    return 0.0
  }
  // Halve the larger factor before multiplying, avoiding an unnecessary
  // overflowing doubled area or the loss of a very small first factor.
  if a.abs() >= b.abs() {
    sensitivity_product(sensitivity_divide(a, 2.0), b)
  } else {
    sensitivity_product(a, sensitivity_divide(b, 2.0))
  }
}

///|
fn area_half_cross(
  a : @types.Point2,
  b : @types.Point2,
) -> Double raise @types.GroundError {
  a.validate()
  b.validate()
  if a.x == 0.0 || b.y == 0.0 {
    return -area_half_product(a.y, b.x)
  }
  if a.y == 0.0 || b.x == 0.0 {
    return area_half_product(a.x, b.y)
  }
  let (length, _) = distance_direction(a)
  area_half_product(length, b.signed_line_distance(a))
}

///|
fn area_polygon_domain(
  points : Array[@types.Point2],
  label : String,
) -> ConvexRoi raise @types.GroundError {
  make_roi(points) catch {
    error => raise @types.InvalidInput(label + ": " + error.message())
  }
}

///|
/// Project 3..64 ordered already-undistorted pixel vertices in the original
/// closed ROI. Both pixel and represented ground polygons follow the existing
/// strict convexity rule: every other normalized edge side must exceed 1e-12.
/// Ground winding is retained; mode responses describe positive absolute area.
pub fn HomographySensitivity::polygon_area(
  self : HomographySensitivity,
  pixels : Array[@types.Point2],
) -> CalibrationAreaSensitivity raise @types.GroundError {
  let input = area_polygon_domain(pixels, "area pixel polygon")
  let projected = input.vertices.map(pixel => self.evaluate(pixel))
  let domain = area_polygon_domain(
    projected.map(point => point.position_m),
    "area ground polygon",
  )
  let offsets = domain.vertices.map(point => {
    @types.Point2::new(
      point.x - domain.vertices[0].x,
      point.y - domain.vertices[0].y,
    )
  })
  let triangle_areas : Array[Double] = []
  for i in 1..<(offsets.length() - 1) {
    let triangle = area_half_cross(offsets[i], offsets[i + 1])
    if domain.orientation * triangle <= 0.0 {
      raise @types.InvalidInput(
        "area triangle has no represented positive area",
      )
    }
    triangle_areas.push(triangle)
  }
  let signed_area_m2 = sensitivity_dot(
    triangle_areas,
    Array::make(triangle_areas.length(), 1.0),
  )
  let area_m2 = signed_area_m2.abs()
  let responses : Array[Double] = []
  for mode in 0..<self.mode_values.length() {
    // Subtract the anchor response first: a shared translation then cancels
    // before any area product, even at a large absolute ground coordinate.
    let deltas = projected.map(point => {
      @types.Point2::new(
        point.responses[mode].x - projected[0].responses[mode].x,
        point.responses[mode].y - projected[0].responses[mode].y,
      )
    })
    let terms : Array[Double] = []
    for i in 1..<(offsets.length() - 1) {
      terms.push(area_half_cross(deltas[i], offsets[i + 1]))
      terms.push(area_half_cross(offsets[i], deltas[i + 1]))
    }
    responses.push(
      domain.orientation *
      sensitivity_dot(terms, Array::make(terms.length(), 1.0)),
    )
  }
  let contribution_m4 = sensitivity_dot(responses, responses)
  {
    signed_area_m2,
    area_m2,
    contribution_m4,
    std_m2: contribution_m4.sqrt(),
    ground_vertices: domain.vertices,
    responses,
  }
}

///|
/// Compare two positive convex polygon areas under the same latent modes.
/// Difference is first-second; ratio is first/second. Contributions exclude
/// observation noise, the ground floor, lens uncertainty and higher orders.
pub fn HomographySensitivity::compare_areas(
  self : HomographySensitivity,
  first_pixels : Array[@types.Point2],
  second_pixels : Array[@types.Point2],
) -> CalibrationAreaComparison raise @types.GroundError {
  let first = self.polygon_area(first_pixels)
  let second = self.polygon_area(second_pixels)
  let ratio = sensitivity_divide(first.area_m2, second.area_m2)
  let difference_responses : Array[Double] = []
  let ratio_responses : Array[Double] = []
  for i in 0..<self.mode_values.length() {
    let a = first.responses[i]
    let b = second.responses[i]
    difference_responses.push(sensitivity_finite(a - b))
    ratio_responses.push(
      sensitivity_divide(sensitivity_dot([a, -ratio], [1.0, b]), second.area_m2),
    )
  }
  let difference_contribution_m4 = sensitivity_dot(
    difference_responses, difference_responses,
  )
  let ratio_contribution = sensitivity_dot(ratio_responses, ratio_responses)
  {
    first,
    second,
    cross_contribution_m4: sensitivity_dot(first.responses, second.responses),
    difference_m2: sensitivity_finite(first.area_m2 - second.area_m2),
    difference_contribution_m4,
    difference_std_m2: difference_contribution_m4.sqrt(),
    ratio,
    ratio_contribution,
    ratio_std: ratio_contribution.sqrt(),
    difference_responses,
    ratio_responses,
  }
}
