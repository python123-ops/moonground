///|
fn replaced_projection_configuration(
  configuration : Json,
  calibration : Json,
  camera : @camera.CameraModel?,
  measurement~ : Bool = false,
) -> Json raise @types.GroundError {
  let fields = object(configuration, "guarded configuration").copy()
  // Match the original constructors' canonical key order as well as values.
  // Pixel configuration places optional camera before its calibration;
  // landmark configuration keeps calibration in its original position.
  if measurement {
    fields.remove("calibration")
    fields.remove("camera")
  }
  match camera {
    Some(camera) => fields["camera"] = camera_json(camera)
    None => fields.remove("camera")
  }
  fields["calibration"] = calibration
  Json::object(fields)
}

///|
// Prepare both canonical configurations before changing the owned session.
// The required camera field makes removing Brown correction an explicit choice.
fn projection_replacement(
  fields : Map[String, Json],
) -> (Int64, @calibration.GroundCalibration, Json, @camera.CameraModel?) raise @types.GroundError {
  allowed_fields(
    fields,
    ["replace_projection"],
    "projection replacement envelope",
  )
  let raw = text(required(fields, "replace_projection"), "replace_projection")
  let replacement = object(parse_document(raw), "projection replacement")
  allowed_fields(
    replacement,
    ["timestamp_us", "calibration", "camera"],
    "projection replacement",
  )
  let time = timestamp(required(replacement, "timestamp_us"), "timestamp_us")
  let (calibration, effective) = calibration_configuration(
    required(replacement, "calibration"),
  )
  let camera = match required(replacement, "camera") {
    Null => None
    _ => optional_camera(replacement)
  }
  (time, calibration, effective, camera)
}

///|
fn GuardedReplay::replace_projection_frame(
  self : GuardedReplay,
  fields : Map[String, Json],
) -> Json raise @types.GroundError {
  let (time, calibration, effective, camera) = projection_replacement(fields)
  let analysis_configuration = replaced_projection_configuration(
    self.analysis_configuration,
    effective,
    camera,
    measurement=true,
  )
  let health_configuration = replaced_projection_configuration(
    self.health_configuration,
    effective,
    camera,
  )
  let result = self.session.replace_projection(time, calibration, camera~)
  self.analysis_configuration = analysis_configuration
  self.health_configuration = health_configuration
  guarded_frame_json(
    result,
    self.monitor_id,
    self.diagnostics,
    kind="guarded_projection_replaced",
  )
}
