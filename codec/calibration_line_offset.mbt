///|
fn calibration_line_offset_value_json(
  value : @calibration.CalibrationLineOffsetSensitivity,
) -> Json {
  Json::object({
    "position_m": point_json(value.position_m),
    "signed_offset_m": Json(value.signed_offset_m),
    "mode_responses_m": Json(value.mode_responses_m()),
    "contribution_m2": Json(value.contribution_m2),
    "std_m": Json(value.std_m),
  })
}

///|
/// Strict bounded comparison of two points against one directed infinite line.
/// The two line anchors and both probes share the request's parameter modes.
pub fn calibration_line_offset_json(
  source : String,
) -> String raise @types.GroundError {
  let document = parse_document(source)
  sensitivity_number_tokens(document)
  let fields = object(document, "calibration line offset request")
  allowed_fields(
    fields,
    ["calibration", "modes", "comparisons"],
    "calibration line offset request",
  )
  let calibration = calibration(required(fields, "calibration"))
  let modes = array(required(fields, "modes"), "modes", 32).map(value => {
    numbers(value, 9, "homography mode")
  })
  let model = @calibration.HomographySensitivity::new(calibration, modes)
  let identifiers : Map[String, Bool] = Map([])
  let comparisons : Array[Json] = []
  for value in array(required(fields, "comparisons"), "comparisons", 256) {
    let probe = object(value, "line offset comparison")
    allowed_fields(
      probe,
      ["probe_id", "line_start", "line_end", "first_pixel", "second_pixel"],
      "line offset comparison",
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
    let result = model.compare_line_offsets(
      point(required(probe, "line_start"), "line_start"),
      point(required(probe, "line_end"), "line_end"),
      point(required(probe, "first_pixel"), "first_pixel"),
      point(required(probe, "second_pixel"), "second_pixel"),
    )
    comparisons.push(
      Json::object({
        "probe_id": Json(probe_id),
        "line_start_m": point_json(result.line_start_m),
        "line_end_m": point_json(result.line_end_m),
        "direction": point_json(result.direction),
        "line_length_m": Json(result.line_length_m),
        "first": calibration_line_offset_value_json(result.first),
        "second": calibration_line_offset_value_json(result.second),
        "cross_contribution_m2": Json(result.cross_contribution_m2),
        "difference_m": Json(result.difference_m),
        "difference_mode_responses_m": Json(
          result.difference_mode_responses_m(),
        ),
        "difference_contribution_m2": Json(result.difference_contribution_m2),
        "difference_std_m": Json(result.difference_std_m),
      }),
    )
  }
  let result = Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("calibration_line_offset_comparison"),
    "evidence_scope": Json("first_order_shared_homography_line_offsets"),
    "normalized_matrix": Json(model.matrix()),
    "mode_count": Json(modes.length()),
    "comparisons": Json(comparisons),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "calibration line offset output exceeds 8388608 UTF-16 code units",
    )
  }
  result
}
