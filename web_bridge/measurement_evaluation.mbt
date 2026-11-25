///|
/// Pure summary from explicitly aligned metric references and measurement logs.
pub fn moonground_measurement_evaluation(source : String) -> String {
  @codec.measurement_evaluation_json(source) catch {
    error => failure(error.message())
  }
}

///|
/// Explicit position/speed acceptance without changing measurement statistics.
pub fn moonground_measurement_acceptance(source : String) -> String {
  @codec.measurement_acceptance_json(source) catch {
    error => failure(error.message())
  }
}

///|
pub fn moonground_measurement_evaluation_checkpoint(source : String) -> String {
  @codec.measurement_evaluation_checkpoint_json(source) catch {
    error => failure(error.message())
  }
}

///|
pub fn moonground_measurement_acceptance_checkpoint(source : String) -> String {
  @codec.measurement_acceptance_checkpoint_json(source) catch {
    error => failure(error.message())
  }
}
