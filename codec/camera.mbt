///|
fn optional_limit(
  fields : Map[String, Json],
  name : String,
) -> Double? raise @types.GroundError {
  match fields.get(name) {
    Some(value) => Some(number(value, name))
    None => None
  }
}

///|
fn optional_camera(
  fields : Map[String, Json],
) -> @camera.CameraModel? raise @types.GroundError {
  let value = match fields.get("camera") {
    None => return None
    Some(value) => value
  }
  let fields = object(value, "camera")
  allowed_fields(
    fields,
    [
      "fx", "fy", "cx", "cy", "k1", "k2", "p1", "p2", "k3", "max_normalized_radius",
    ],
    "camera",
  )
  Some(
    @camera.CameraModel::new(
      fx=number(required(fields, "fx"), "fx"),
      fy=number(required(fields, "fy"), "fy"),
      cx=number(required(fields, "cx"), "cx"),
      cy=number(required(fields, "cy"), "cy"),
      k1=optional_number(fields, "k1", 0.0),
      k2=optional_number(fields, "k2", 0.0),
      p1=optional_number(fields, "p1", 0.0),
      p2=optional_number(fields, "p2", 0.0),
      k3=optional_number(fields, "k3", 0.0),
      max_normalized_radius=optional_number(
        fields, "max_normalized_radius", 1.0,
      ),
    ),
  )
}

///|
fn camera_json(camera : @camera.CameraModel) -> Json {
  let p = camera.parameters()
  Json::object({
    "fx": Json(p[0]),
    "fy": Json(p[1]),
    "cx": Json(p[2]),
    "cy": Json(p[3]),
    "k1": Json(p[4]),
    "k2": Json(p[5]),
    "p1": Json(p[6]),
    "p2": Json(p[7]),
    "k3": Json(p[8]),
    "max_normalized_radius": Json(camera.max_normalized_radius()),
  })
}
