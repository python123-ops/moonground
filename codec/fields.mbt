///|
fn invalid(message : String) -> @types.GroundError {
  @types.InvalidInput(message)
}

///|
fn parse_document(source : String) -> Json raise @types.GroundError {
  if source.length() > 1048576 {
    raise invalid("JSON text exceeds 1048576 UTF-16 code units")
  }
  @json.parse(
    source,
    max_nesting_depth=32,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error => raise invalid("invalid JSON: " + error.to_string())
  }
}

///|
fn object(
  value : Json,
  label : String,
) -> Map[String, Json] raise @types.GroundError {
  match value {
    Object(fields) => fields
    _ => raise invalid(label + " must be an object")
  }
}

///|
fn allowed_fields(
  fields : Map[String, Json],
  names : Array[String],
  label : String,
) -> Unit raise @types.GroundError {
  for name, _ in fields {
    if !names.contains(name) {
      raise invalid(label + ": unknown field " + name)
    }
  }
}

///|
fn required(
  fields : Map[String, Json],
  name : String,
) -> Json raise @types.GroundError {
  match fields.get(name) {
    Some(value) => value
    None => raise invalid("missing field " + name)
  }
}

///|
fn text(value : Json, label : String) -> String raise @types.GroundError {
  match value {
    String(value) => value
    _ => raise invalid(label + " must be a string")
  }
}

///|
fn number(value : Json, label : String) -> Double raise @types.GroundError {
  match value {
    Number(value, ..) if @types.is_finite(value) => value
    _ => raise invalid(label + " must be a finite number")
  }
}

///|
fn positive_int(value : Json, label : String) -> Int32 raise @types.GroundError {
  let numeric = number(value, label)
  if numeric < 1.0 ||
    numeric > 2147483647.0 ||
    numeric.to_int().to_double() != numeric {
    raise invalid(label + " must be a positive 32-bit integer")
  }
  let result = numeric.to_int()
  if value is Number(_, repr=Some(source)) &&
    !integer_token_equals(source, result) {
    raise invalid(label + " must be a positive 32-bit integer")
  }
  result
}

///|
fn timestamp(value : Json, label : String) -> Int64 raise @types.GroundError {
  let source = text(value, label)
  let value = @string.parse_int64(source, base=10) catch {
    _ => raise invalid(label + " must be a nonnegative Int64 decimal string")
  }
  if value < 0L || value.to_string() != source {
    raise invalid(
      label + " must be a canonical nonnegative Int64 decimal string",
    )
  }
  value
}

///|
fn array(
  value : Json,
  label : String,
  limit : Int32,
) -> Array[Json] raise @types.GroundError {
  match value {
    Array(values) if values.length() <= limit => values
    Array(_) => raise invalid(label + " exceeds its record limit")
    _ => raise invalid(label + " must be an array")
  }
}

///|
fn numbers(
  value : Json,
  count : Int32,
  label : String,
) -> Array[Double] raise @types.GroundError {
  let values = array(value, label, count)
  if values.length() != count {
    raise invalid(
      label + " must contain exactly " + count.to_string() + " numbers",
    )
  }
  let result : Array[Double] = []
  for value in values {
    result.push(number(value, label))
  }
  result
}

///|
fn point(
  value : Json,
  label : String,
) -> @types.Point2 raise @types.GroundError {
  let values = numbers(value, 2, label)
  @types.Point2::new(values[0], values[1])
}

///|
fn covariance(value : Json) -> @types.Covariance2 raise @types.GroundError {
  let values = numbers(value, 3, "covariance")
  @types.Covariance2::new(values[0], values[1], values[2])
}

///|
fn optional_number(
  fields : Map[String, Json],
  name : String,
  fallback : Double,
) -> Double raise @types.GroundError {
  match fields.get(name) {
    Some(value) => number(value, name)
    None => fallback
  }
}

///|
fn ids(
  fields : Map[String, Json],
  name : String,
  limit : Int32,
) -> Array[Int32] raise @types.GroundError {
  let values = match fields.get(name) {
    None => return []
    Some(value) => array(value, name, limit)
  }
  let result : Array[Int32] = []
  for value in values {
    result.push(positive_int(value, name))
  }
  result
}

///|
fn point_json(point : @types.Point2) -> Json {
  Json([point.x, point.y])
}

///|
fn covariance_json(value : @types.Covariance2) -> Json {
  Json([value.xx, value.xy, value.yy])
}
