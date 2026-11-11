///|
fn points(
  value : Json,
  label : String,
) -> Array[@types.Point2] raise @types.GroundError {
  let result : Array[@types.Point2] = []
  for value in array(value, label, 256) {
    result.push(point(value, label))
  }
  result
}

///|
/// Fit manual ground correspondences and validate independent held-out points.
pub fn calibrate_json(source : String) -> String raise @types.GroundError {
  let fields = object(parse_document(source), "calibration fit")
  allowed_fields(
    fields,
    [
      "control_pixels", "control_world", "check_pixels", "check_world", "roi", "max_fit_error_m",
      "max_check_error_m", "max_meters_per_pixel", "ground_noise_floor_m", "camera",
    ],
    "calibration fit",
  )
  let max_meters_per_pixel = optional_number(
    fields, "max_meters_per_pixel", 0.5,
  )
  let ground_noise_floor_m = optional_number(
    fields, "ground_noise_floor_m", 0.001,
  )
  let camera = optional_camera(fields)
  let controls = points(required(fields, "control_pixels"), "control_pixels")
  let checks = points(required(fields, "check_pixels"), "check_pixels")
  match camera {
    Some(camera) => {
      for i in 0..<controls.length() {
        controls[i] = camera.rectify(controls[i])
      }
      for i in 0..<checks.length() {
        checks[i] = camera.rectify(checks[i])
      }
    }
    None => ()
  }
  let calibration = @calibration.GroundCalibration::fit(
    controls,
    points(required(fields, "control_world"), "control_world"),
    checks,
    points(required(fields, "check_world"), "check_world"),
    points(required(fields, "roi"), "roi"),
    max_fit_error_m=optional_number(fields, "max_fit_error_m", 0.1),
    max_check_error_m=optional_number(fields, "max_check_error_m", 0.2),
    max_meters_per_pixel~,
    ground_noise_floor_m~,
  )
  let report = calibration.report()
  let output : Map[String, Json] = {
    "calibration": Json::object({
      "matrix": Json(calibration.matrix()),
      "roi": Json(calibration.roi().map(p => [p.x, p.y])),
      "max_meters_per_pixel": Json(max_meters_per_pixel),
      "ground_noise_floor_m": Json(ground_noise_floor_m),
    }),
    "report": Json::object({
      "fit_count": Json(report.fit_count()),
      "check_count": Json(report.check_count()),
      "fit_rms_m": optional_number_json(report.fit_rms_m()),
      "fit_max_error_m": optional_number_json(report.fit_max_error_m()),
      "check_rms_m": optional_number_json(report.check_rms_m()),
      "check_max_error_m": optional_number_json(report.check_max_error_m()),
      "roi_scale_bound_m_per_pixel": Json(report.roi_scale_bound_m_per_pixel()),
    }),
  }
  match camera {
    Some(camera) => output["camera"] = camera_json(camera)
    None => ()
  }
  Json::object(output).stringify()
}
