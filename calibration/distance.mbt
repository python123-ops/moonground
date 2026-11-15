///|
fn distance_direction(
  displacement : @types.Point2,
) -> (Double, @types.Point2) raise @types.GroundError {
  let scale = displacement.x.abs().max(displacement.y.abs())
  if scale == 0.0 {
    raise @types.InvalidInput(
      "distance sensitivity requires distinct represented ground endpoints",
    )
  }
  let x = sensitivity_divide(displacement.x, scale)
  let y = sensitivity_divide(displacement.y, scale)
  let norm = (x * x + y * y).sqrt()
  let distance = sensitivity_product(scale, norm)
  let direction = @types.Point2::new(
    sensitivity_divide(x, norm),
    sensitivity_divide(y, norm),
  )
  (distance, direction)
}

///|
/// Distance between two explicitly supplied already-undistorted pixels in the
/// closed ROI. Uses the existing shared parameter projection domain. A zero
/// ground displacement is rejected because the Euclidean norm has no unique
/// derivative there, including when no modes were supplied.
pub fn HomographySensitivity::distance(
  self : HomographySensitivity,
  first_pixel : @types.Point2,
  second_pixel : @types.Point2,
) -> CalibrationDistanceSensitivity raise @types.GroundError {
  let pair = self.evaluate_pair(first_pixel, second_pixel)
  let (distance_m, direction) = distance_direction(pair.displacement_m)
  let distance_responses : Array[Double] = []
  for i in 0..<self.mode_values.length() {
    let response = @types.Point2::new(
      pair.second.responses[i].x - pair.first.responses[i].x,
      pair.second.responses[i].y - pair.first.responses[i].y,
    )
    distance_responses.push(response.component_along(direction))
  }
  let contribution_m2 = sensitivity_dot(distance_responses, distance_responses)
  {
    first_position_m: pair.first.position_m,
    second_position_m: pair.second.position_m,
    direction,
    distance_m,
    contribution_m2,
    std_m: contribution_m2.sqrt(),
    distance_responses,
  }
}

///|
/// Compare two distances under the same model. Difference is first-second;
/// ratio is first/second. A scalar zero first-order contribution can still
/// have a nonlinear second-order response. These are not probability bounds.
pub fn HomographySensitivity::compare_distances(
  self : HomographySensitivity,
  first_start : @types.Point2,
  first_end : @types.Point2,
  second_start : @types.Point2,
  second_end : @types.Point2,
) -> CalibrationDistanceComparison raise @types.GroundError {
  let first = self.distance(first_start, first_end)
  let second = self.distance(second_start, second_end)
  let ratio = sensitivity_divide(first.distance_m, second.distance_m)
  let difference_responses : Array[Double] = []
  let ratio_responses : Array[Double] = []
  for i in 0..<self.mode_values.length() {
    let a = first.distance_responses[i]
    let b = second.distance_responses[i]
    difference_responses.push(sensitivity_finite(a - b))
    ratio_responses.push(
      sensitivity_divide(
        sensitivity_dot([a, -ratio], [1.0, b]),
        second.distance_m,
      ),
    )
  }
  let difference_contribution_m2 = sensitivity_dot(
    difference_responses, difference_responses,
  )
  let ratio_contribution = sensitivity_dot(ratio_responses, ratio_responses)
  {
    first,
    second,
    cross_contribution_m2: sensitivity_dot(
      first.distance_responses,
      second.distance_responses,
    ),
    difference_m: sensitivity_finite(first.distance_m - second.distance_m),
    difference_contribution_m2,
    difference_std_m: difference_contribution_m2.sqrt(),
    ratio,
    ratio_contribution,
    ratio_std: ratio_contribution.sqrt(),
    difference_responses,
    ratio_responses,
  }
}
