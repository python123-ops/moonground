///|
/// Count a bounded measurement log without allocating a persistent session handle.
pub fn moonground_gates(source : String) -> String {
  @codec.gates_json(source) catch {
    error => failure(error.message())
  }
}
