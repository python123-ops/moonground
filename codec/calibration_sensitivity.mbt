///|
fn sensitivity_contribution_json(
  value : @calibration.CalibrationContribution2,
) -> Json {
  Json([value.xx, value.xy, value.yy])
}

///|
fn sensitivity_point_json(
  value : @calibration.CalibrationSensitivityPoint,
) -> Json {
  Json::object({
    "position_m": point_json(value.position_m),
    "mode_responses_m": Json(value.mode_responses_m().map(point_json)),
    "contribution_m2": sensitivity_contribution_json(value.contribution_m2),
  })
}

///|
fn sensitivity_number_tokens(value : Json) -> Unit raise @types.GroundError {
  match value {
    Number(value, repr~) => {
      if !@types.is_finite(value) {
        raise invalid("calibration sensitivity numbers must be finite")
      }
      if value == 0.0 && repr is Some(source) {
        for code in source.iter() {
          if code == 'e' || code == 'E' {
            break
          }
          if code >= '1' && code <= '9' {
            raise invalid(
              "nonzero calibration sensitivity number underflows binary64",
            )
          }
        }
      }
    }
    Array(values) =>
      for child in values {
        sensitivity_number_tokens(child)
      }
    Object(fields) =>
      for _, child in fields {
        sensitivity_number_tokens(child)
      }
    _ => ()
  }
}

///|
/// Strict stateless diagnostic. Modes are expressed in calibration.matrix()'s
/// normalized gauge. Probes contain already-undistorted pixel pairs; no camera,
/// filter, residual-derived uncertainty or observation noise is implicit.
pub fn calibration_sensitivity_json(
  source : String,
) -> String raise @types.GroundError {
  let document = parse_document(source)
  sensitivity_number_tokens(document)
  let fields = object(document, "calibration sensitivity request")
  allowed_fields(
    fields,
    ["calibration", "modes", "probes"],
    "calibration sensitivity request",
  )
  let calibration = calibration(required(fields, "calibration"))
  let modes = array(required(fields, "modes"), "modes", 32).map(value => {
    numbers(value, 9, "homography mode")
  })
  let model = @calibration.HomographySensitivity::new(calibration, modes)
  let identifiers : Map[String, Bool] = Map([])
  let rows : Array[Json] = []
  for value in array(required(fields, "probes"), "probes", 256) {
    let probe = object(value, "calibration sensitivity probe")
    allowed_fields(
      probe,
      ["probe_id", "first_pixel", "second_pixel"],
      "calibration sensitivity probe",
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
    let result = model.evaluate_pair(
      point(required(probe, "first_pixel"), "first_pixel"),
      point(required(probe, "second_pixel"), "second_pixel"),
    )
    rows.push(
      Json::object({
        "probe_id": Json(probe_id),
        "first": sensitivity_point_json(result.first),
        "second": sensitivity_point_json(result.second),
        "displacement_m": point_json(result.displacement_m),
        "cross_contribution_m2": Json(result.cross_contribution_m2()),
        "displacement_contribution_m2": sensitivity_contribution_json(
          result.displacement_contribution_m2,
        ),
      }),
    )
  }
  let result = Json::object({
    "schema_version": Json("0.1.0"),
    "kind": Json("calibration_sensitivity"),
    "evidence_scope": Json("first_order_shared_homography_parameters"),
    "normalized_matrix": Json(model.matrix()),
    "mode_count": Json(modes.length()),
    "probes": Json(rows),
  }).stringify()
  if result.length() > 8388608 {
    raise invalid(
      "calibration sensitivity output exceeds 8388608 UTF-16 code units",
    )
  }
  result
}
