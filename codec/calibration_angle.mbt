///|
fn calibration_direction_value_json(
  value : @calibration.CalibrationDirectionSensitivity,
) -> Json {
  Json::object({
    "first_position_m": point_json(value.first_position_m),
    "second_position_m": point_json(value.second_position_m),
    "direction": point_json(value.direction),
    "distance_m": Json(value.distance_m),
    "angle_rad": Json(value.angle_rad),
    "mode_responses_rad": Json(value.mode_responses_rad()),
    "contribution_rad2": Json(value.contribution_rad2),
    "std_rad": Json(value.std_rad),
  })
}

///|
fn angle_segment(value : Json) -> Array[@types.Point2] raise @types.GroundError {
  let points = array(value, "angle segment", 2)
  if points.length() != 2 {
    raise invalid("angle segment must contain exactly two pixel points")
  }
  points.map(value => point(value, "angle endpoint"))
}

///|
/// Strict bounded comparison of explicitly directed static pixel segments.
/// Angles use ground +x and counterclockwise radians; comparison is second
/// relative to first, canonical (-pi, pi]. Contributions are circular tangents.
pub fn calibration_angle_json(
  source : String,
) -> String raise @types.GroundError {
  let document = parse_document(source)
  sensitivity_number_tokens(document)
  let fields = object(document, "calibration angle request")
  allowed_fields(
    fields,
    ["calibration", "modes", "comparisons"],
    "calibration angle request",
  )
  let calibration = calibration(required(fields, "calibration"))
  let modes = array(required(fields, "modes"), "modes", 32).map(value => {
    numbers(value, 9, "homography mode")
  })
  let model = @calibration.HomographySensitivity::new(calibration, modes)
  let identifiers : Map[String, Bool] = Map([])
  let comparisons : Array[Json] = []
  for value in array(required(fields, "comparisons"), "comparisons", 256) {
    let probe = object(value, "angle comparison")
    allowed_fields(
      probe,
      ["probe_id", "first_segment", "second_segment"],
      "angle comparison",
    )
    let probe_id = text(required(probe, "probe_id"), "probe_id")
    if probe_id.length() < 1 ||
      probe_id.length() > 128 ||
      identifiers.contains(probe_id) {
      raise invalid(
        "probe_id must be unique and contain 1 to 128 UTF-16 code units",
      )
    }
    identifiers[probe_id] = true
    let first = angle_segment(required(probe, "first_segment"))
    let second = angle_segment(required(probe, "second_segment"))
    let result = model.compare_directions(
      first[0],
      first[1],
      second[0],
      second[1],
    )
    comparisons.push(
      Json::object({
        "probe_id": Json(probe_id),
        "first": calibration_direction_value_json(result.first),
        "second": calibration_direction_value_json(result.second),
        "cross_contribution_rad2": Json(result.cross_contribution_rad2),
        "angle_rad": Json(result.angle_rad),
        "mode_responses_rad": Json(result.mode_responses_rad()),
        "contribution_rad2": Json(result.contribution_rad2),
        "std_rad": Json(result.std_rad),
      }),
    )
  }
  let result = Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("calibration_angle_comparison"),
    "evidence_scope": Json("first_order_shared_homography_angular_tangents"),
    "angle_convention": Json("second_relative_to_first_ccw"),
    "normalized_matrix": Json(model.matrix()),
    "mode_count": Json(modes.length()),
    "comparisons": Json(comparisons),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("calibration angle output exceeds 8388608 UTF-16 code units")
  }
  result
}
