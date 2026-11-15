///|
fn sensitivity_angle(y : Double, x : Double) -> Double raise @types.GroundError {
  if x == 0.0 && y == 0.0 {
    raise @types.InvalidInput("segment angle needs a nonzero direction")
  }
  let value = sensitivity_finite(@math.atan2(y, x))
  if y != 0.0 && value == 0.0 {
    raise @types.InvalidInput("segment angle underflows")
  }
  if value == -@math.PI {
    @math.PI
  } else if value == 0.0 {
    0.0
  } else {
    value
  }
}

///|
/// Static ground-segment direction from two already-undistorted pixels in the
/// original closed ROI. Endpoints must map distinctly, including with no modes.
/// Shared translation and radial displacement responses have no angular term.
/// Reuses the original pair domain and the compensated raw-direction kernel.
pub fn HomographySensitivity::segment_direction(
  self : HomographySensitivity,
  first_pixel : @types.Point2,
  second_pixel : @types.Point2,
) -> CalibrationDirectionSensitivity raise @types.GroundError {
  let pair = self.evaluate_pair(first_pixel, second_pixel)
  let (distance_m, direction) = distance_direction(pair.displacement_m)
  let responses : Array[Double] = []
  for i in 0..<self.mode_values.length() {
    let delta = @types.Point2::new(
      pair.second.responses[i].x - pair.first.responses[i].x,
      pair.second.responses[i].y - pair.first.responses[i].y,
    )
    responses.push(
      sensitivity_divide(
        delta.signed_line_distance(pair.displacement_m),
        distance_m,
      ),
    )
  }
  let contribution_rad2 = sensitivity_dot(responses, responses)
  {
    first_position_m: pair.first.position_m,
    second_position_m: pair.second.position_m,
    direction,
    distance_m,
    angle_rad: sensitivity_angle(pair.displacement_m.y, pair.displacement_m.x),
    contribution_rad2,
    std_rad: contribution_rad2.sqrt(),
    responses,
  }
}

///|
/// Signed second-relative-to-first angle, retaining shared rotation cancellation
/// and possibly negative cross contributions. The response is a local circular
/// tangent even at pi; it is not a derivative of the discontinuous displayed
/// real number across that cut. No noise floor or observation noise is added.
pub fn HomographySensitivity::compare_directions(
  self : HomographySensitivity,
  first_start : @types.Point2,
  first_end : @types.Point2,
  second_start : @types.Point2,
  second_end : @types.Point2,
) -> CalibrationAngleComparison raise @types.GroundError {
  let first = self.segment_direction(first_start, first_end)
  let second = self.segment_direction(second_start, second_end)
  let a = @types.Point2::new(
    first.second_position_m.x - first.first_position_m.x,
    first.second_position_m.y - first.first_position_m.y,
  )
  let b = @types.Point2::new(
    second.second_position_m.x - second.first_position_m.x,
    second.second_position_m.y - second.first_position_m.y,
  )
  let responses : Array[Double] = []
  for i in 0..<self.mode_values.length() {
    responses.push(sensitivity_finite(second.responses[i] - first.responses[i]))
  }
  let contribution_rad2 = sensitivity_dot(responses, responses)
  {
    first,
    second,
    cross_contribution_rad2: sensitivity_dot(first.responses, second.responses),
    angle_rad: sensitivity_angle(
      b.signed_line_distance(a),
      b.component_along(first.direction),
    ),
    contribution_rad2,
    std_rad: contribution_rad2.sqrt(),
    responses,
  }
}
