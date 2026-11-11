///|
fn robust_fit_options(
  value : Json,
) -> @calibration.RobustFitOptions raise @types.GroundError {
  let fields = object(value, "robust fitting options")
  allowed_fields(
    fields,
    ["inlier_threshold_m", "min_inlier_ratio", "max_trials", "seed"],
    "robust fitting options",
  )
  @calibration.RobustFitOptions::new(
    inlier_threshold_m=optional_number(fields, "inlier_threshold_m", 0.05),
    min_inlier_ratio=optional_number(fields, "min_inlier_ratio", 0.6),
    max_trials=match fields.get("max_trials") {
      Some(value) => positive_int(value, "max_trials")
      None => 512
    },
    seed=match fields.get("seed") {
      Some(value) => positive_int(value, "seed")
      None => 1
    },
  )
}

///|
fn robust_fit_report_json(
  fitted : @calibration.RobustCalibration,
  options : @calibration.RobustFitOptions,
) -> Json {
  let mask = fitted.inlier_mask()
  let excluded : Array[Int32] = []
  for i in 0..<mask.length() {
    if !mask[i] {
      excluded.push(i)
    }
  }
  Json::object({
    "control_count": Json(mask.length()),
    "inlier_count": Json(fitted.inlier_count()),
    "inlier_mask": Json(mask),
    "control_errors_m": Json(fitted.control_errors_m()),
    "outlier_indices": Json(excluded),
    "options": Json::object({
      "inlier_threshold_m": Json(options.inlier_threshold_m),
      "min_inlier_ratio": Json(options.min_inlier_ratio),
      "max_trials": Json(options.max_trials),
      "seed": Json(options.seed),
    }),
    "trials_run": Json(fitted.trials_run()),
    "valid_hypotheses": Json(fitted.valid_hypotheses()),
    "refinement_steps": Json(fitted.refinement_steps()),
  })
}
