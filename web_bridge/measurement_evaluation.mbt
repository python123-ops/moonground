///|
/// Pure summary from explicitly aligned metric references and measurement logs.
pub fn moonground_measurement_evaluation(source : String) -> String {
  @codec.measurement_evaluation_json(source) catch {
    error => failure(error.message())
  }
}
