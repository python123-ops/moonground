///|
/// Analyze raw pixel frames only while current landmark evidence permits it.
pub fn moonground_guarded(source : String) -> String {
  @codec.guarded_json(source) catch {
    error => failure(error.message())
  }
}
