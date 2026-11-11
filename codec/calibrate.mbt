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
/// Robust selection is explicit; an omitted option preserves strict fitting.
pub fn calibrate_json(source : String) -> String raise @types.GroundError {
  let fields = object(parse_document(source), "calibration fit")
  allowed_fields(
    fields,
    [
      "control_pixels", "control_world", "check_pixels", "check_world", "roi", "max_fit_error_m",
      "max_check_error_m", "max_meters_per_pixel", "ground_noise_floor_m", "camera",
      "robust",
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
  let robust = match fields.get("robust") {
    Some(value) => Some(robust_fit_options(value))
    None => None
  }
  let controls = points(required(fields, "control_pixels"), "control_pixels")
  let checks = points(required(fields, "check_pixels"), "check_pixels")
  let control_world = points(required(fields, "control_world"), "control_world")
  let check_world = points(required(fields, "check_world"), "check_world")
  let roi = points(required(fields, "roi"), "roi")
  let max_fit_error_m = optional_number(fields, "max_fit_error_m", 0.1)
  let max_check_error_m = optional_number(fields, "max_check_error_m", 0.2)
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
  let (calibration, robust_report) = match robust {
    None =>
      (
        @calibration.GroundCalibration::fit(
          controls,
          control_world,
          checks,
          check_world,
          roi,
          max_fit_error_m~,
          max_check_error_m~,
          max_meters_per_pixel~,
          ground_noise_floor_m~,
        ),
        None,
      )
    Some(options) => {
      let fitted = @calibration.GroundCalibration::fit_robust(
        controls,
        control_world,
        checks,
        check_world,
        roi,
        options~,
        max_fit_error_m~,
        max_check_error_m~,
        max_meters_per_pixel~,
        ground_noise_floor_m~,
      )
      (fitted.calibration(), Some(robust_fit_report_json(fitted, options)))
    }
  }
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
  if robust_report is Some(value) {
    output["robust_report"] = value
  }
  Json::object(output).stringify()
}
