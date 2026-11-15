///|
fn calibration_area_value_json(
  value : @calibration.CalibrationAreaSensitivity,
) -> Json {
  Json::object({
    "positions_m": Json(value.positions_m().map(point => point_json(point))),
    "signed_area_m2": Json(value.signed_area_m2),
    "area_m2": Json(value.area_m2),
    "mode_responses_m2": Json(value.mode_responses_m2()),
    "contribution_m4": Json(value.contribution_m4),
    "std_m2": Json(value.std_m2),
  })
}

///|
fn area_polygon(value : Json) -> Array[@types.Point2] raise @types.GroundError {
  let points = array(value, "area polygon", 64)
  if points.length() < 3 {
    raise invalid("area polygon must contain 3 to 64 ordered pixel vertices")
  }
  points.map(value => point(value, "area vertex"))
}

///|
/// Strict bounded shared-calibration comparison of explicit convex polygons.
/// Each request owns its calibration and ordered parameter modes. Input pixel
/// points are already undistorted; no measurement noise or state is implicit.
pub fn calibration_area_json(
  source : String,
) -> String raise @types.GroundError {
  let document = parse_document(source)
  sensitivity_number_tokens(document)
  let fields = object(document, "calibration area request")
  allowed_fields(
    fields,
    ["calibration", "modes", "comparisons"],
    "calibration area request",
  )
  let calibration = calibration(required(fields, "calibration"))
  let modes = array(required(fields, "modes"), "modes", 32).map(value => {
    numbers(value, 9, "homography mode")
  })
  let model = @calibration.HomographySensitivity::new(calibration, modes)
  let identifiers : Map[String, Bool] = Map([])
  let comparisons : Array[Json] = []
  for value in array(required(fields, "comparisons"), "comparisons", 64) {
    let probe = object(value, "area comparison")
    allowed_fields(
      probe,
      ["probe_id", "first_polygon", "second_polygon"],
      "area comparison",
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
    let first = area_polygon(required(probe, "first_polygon"))
    let second = area_polygon(required(probe, "second_polygon"))
    let result = model.compare_areas(first, second)
    comparisons.push(
      Json::object({
        "probe_id": Json(probe_id),
        "first": calibration_area_value_json(result.first),
        "second": calibration_area_value_json(result.second),
        "cross_contribution_m4": Json(result.cross_contribution_m4),
        "difference_m2": Json(result.difference_m2),
        "difference_mode_responses_m2": Json(
          result.difference_mode_responses_m2(),
        ),
        "difference_contribution_m4": Json(result.difference_contribution_m4),
        "difference_std_m2": Json(result.difference_std_m2),
        "ratio": Json(result.ratio),
        "ratio_mode_responses": Json(result.ratio_mode_responses()),
        "ratio_contribution": Json(result.ratio_contribution),
        "ratio_std": Json(result.ratio_std),
      }),
    )
  }
  let result = Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("calibration_area_comparison"),
    "evidence_scope": Json("first_order_shared_homography_area_contrasts"),
    "normalized_matrix": Json(model.matrix()),
    "mode_count": Json(modes.length()),
    "comparisons": Json(comparisons),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid("calibration area output exceeds 8388608 UTF-16 code units")
  }
  result
}
