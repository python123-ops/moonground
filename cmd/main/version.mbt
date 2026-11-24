///|
fn cli_version() -> String {
  "0.43.0"
}

///|
fn cli_version_json() -> String {
  "{\"name\":\"moonground\",\"version\":\"" +
  cli_version() +
  "\",\"measurement_schema_version\":\"0.2.0\"}"
}
