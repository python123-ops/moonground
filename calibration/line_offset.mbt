///|
fn line_offset_difference(
  a : @types.Point2,
  b : @types.Point2,
) -> @types.Point2 raise @types.GroundError {
  @types.Point2::new(a.x - b.x, a.y - b.y)
}

///|
// h = cross(u, v)/|u|. The line moves with its two anchors:
// dh = n.dv - (n.du/|u|) * (t.v), where t=u/|u| and n=(-t.y,t.x).
// Use the raw-edge compensated normal projection before scalar arithmetic.
fn line_offset_project(
  reference : CalibrationSensitivityPair,
  length : Double,
  direction : @types.Point2,
  offset : @types.Point2,
  deltas : Array[@types.Point2],
) -> (Double, Array[Double]) raise @types.GroundError {
  let edge = reference.displacement_m
  let value = offset.signed_line_distance(edge)
  let responses : Array[Double] = []
  for i in 0..<deltas.length() {
    let line_delta = line_offset_difference(
      reference.second.responses[i],
      reference.first.responses[i],
    )
    let rotation_normal = line_delta.signed_line_distance(edge)
    let normal = deltas[i].signed_line_distance(edge)
    if rotation_normal == 0.0 {
      responses.push(normal)
    } else {
      let rotation = sensitivity_divide(rotation_normal, length)
      let along = offset.component_along(direction)
      responses.push(sensitivity_dot([1.0, -rotation], [normal, along]))
    }
  }
  (value, responses)
}

///|
fn line_offset_value(
  reference : CalibrationSensitivityPair,
  length : Double,
  direction : @types.Point2,
  point : CalibrationSensitivityPoint,
) -> CalibrationLineOffsetSensitivity raise @types.GroundError {
  let deltas : Array[@types.Point2] = []
  for i in 0..<point.responses.length() {
    deltas.push(
      line_offset_difference(point.responses[i], reference.first.responses[i]),
    )
  }
  let (signed_offset_m, responses) = line_offset_project(
    reference,
    length,
    direction,
    line_offset_difference(point.position_m, reference.first.position_m),
    deltas,
  )
  let contribution_m2 = sensitivity_dot(responses, responses)
  {
    position_m: point.position_m,
    signed_offset_m,
    contribution_m2,
    std_m: contribution_m2.sqrt(),
    responses,
  }
}

///|
/// Offset from an infinite directed ground line, positive on its left side.
/// All three pixels are already undistorted and must lie in the original ROI.
/// Both anchors participate in the shared modes. On-line points are valid;
/// coincident represented anchors are rejected even with no modes.
pub fn HomographySensitivity::line_offset(
  self : HomographySensitivity,
  line_start : @types.Point2,
  line_end : @types.Point2,
  pixel : @types.Point2,
) -> CalibrationLineOffsetSensitivity raise @types.GroundError {
  let reference = self.evaluate_pair(line_start, line_end)
  let (length, direction) = distance_direction(reference.displacement_m)
  line_offset_value(reference, length, direction, self.evaluate(pixel))
}

///|
/// Compare two signed offsets against one common infinite line. The difference
/// and its responses are projected directly from first-minus-second positions
/// and responses, avoiding subtraction of large rounded offsets or variances.
/// Contributions describe only the supplied first-order calibration modes.
pub fn HomographySensitivity::compare_line_offsets(
  self : HomographySensitivity,
  line_start : @types.Point2,
  line_end : @types.Point2,
  first_pixel : @types.Point2,
  second_pixel : @types.Point2,
) -> CalibrationLineOffsetComparison raise @types.GroundError {
  let reference = self.evaluate_pair(line_start, line_end)
  let (length, direction) = distance_direction(reference.displacement_m)
  let a = self.evaluate(first_pixel)
  let b = self.evaluate(second_pixel)
  let first = line_offset_value(reference, length, direction, a)
  let second = line_offset_value(reference, length, direction, b)
  let deltas : Array[@types.Point2] = []
  for i in 0..<a.responses.length() {
    deltas.push(line_offset_difference(a.responses[i], b.responses[i]))
  }
  let (difference_m, responses) = line_offset_project(
    reference,
    length,
    direction,
    line_offset_difference(a.position_m, b.position_m),
    deltas,
  )
  let difference_contribution_m2 = sensitivity_dot(responses, responses)
  {
    line_start_m: reference.first.position_m,
    line_end_m: reference.second.position_m,
    direction,
    line_length_m: length,
    first,
    second,
    cross_contribution_m2: sensitivity_dot(first.responses, second.responses),
    difference_m,
    difference_contribution_m2,
    difference_std_m: difference_contribution_m2.sqrt(),
    responses,
  }
}
