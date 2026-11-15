///|
fn calibration_distance_value_json(
  value : @calibration.CalibrationDistanceSensitivity,
) -> Json {
  Json::object({
    "first_position_m": point_json(value.first_position_m),
    "second_position_m": point_json(value.second_position_m),
    "direction": point_json(value.direction),
    "distance_m": Json(value.distance_m),
    "mode_responses_m": Json(value.mode_responses_m()),
    "contribution_m2": Json(value.contribution_m2),
    "std_m": Json(value.std_m),
  })
}

///|
fn distance_segment(
  value : Json,
) -> Array[@types.Point2] raise @types.GroundError {
  let points = array(value, "distance segment", 2)
  if points.length() != 2 {
    raise invalid("distance segment must contain exactly two pixel points")
  }
  points.map(value => point(value, "distance endpoint"))
}

///|
/// Strict bounded shared-calibration comparison of explicit static segments.
/// Each request owns its calibration and ordered parameter modes. Input pixel
/// points are already undistorted; no measurement noise or state is implicit.
pub fn calibration_distance_json(
  source : String,
) -> String raise @types.GroundError {
  let document = parse_document(source)
  sensitivity_number_tokens(document)
  let fields = object(document, "calibration distance request")
  allowed_fields(
    fields,
    ["calibration", "modes", "comparisons"],
    "calibration distance request",
  )
  let calibration = calibration(required(fields, "calibration"))
  let modes = array(required(fields, "modes"), "modes", 32).map(value => {
    numbers(value, 9, "homography mode")
  })
  let model = @calibration.HomographySensitivity::new(calibration, modes)
  let identifiers : Map[String, Bool] = Map([])
  let comparisons : Array[Json] = []
  for value in array(required(fields, "comparisons"), "comparisons", 256) {
    let probe = object(value, "distance comparison")
    allowed_fields(
      probe,
      ["probe_id", "first_segment", "second_segment"],
      "distance comparison",
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
    let first = distance_segment(required(probe, "first_segment"))
    let second = distance_segment(required(probe, "second_segment"))
    let result = model.compare_distances(
      first[0],
      first[1],
      second[0],
      second[1],
    )
    comparisons.push(
      Json::object({
        "probe_id": Json(probe_id),
        "first": calibration_distance_value_json(result.first),
        "second": calibration_distance_value_json(result.second),
        "cross_contribution_m2": Json(result.cross_contribution_m2),
        "difference_m": Json(result.difference_m),
        "difference_mode_responses_m": Json(
          result.difference_mode_responses_m(),
        ),
        "difference_contribution_m2": Json(result.difference_contribution_m2),
        "difference_std_m": Json(result.difference_std_m),
        "ratio": Json(result.ratio),
        "ratio_mode_responses": Json(result.ratio_mode_responses()),
        "ratio_contribution": Json(result.ratio_contribution),
        "ratio_std": Json(result.ratio_std),
      }),
    )
  }
  let result = Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("calibration_distance_comparison"),
    "evidence_scope": Json("first_order_shared_homography_distance_contrasts"),
    "normalized_matrix": Json(model.matrix()),
    "mode_count": Json(modes.length()),
    "comparisons": Json(comparisons),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "calibration distance output exceeds 8388608 UTF-16 code units",
    )
  }
  result
}
