///|
/// Recheck fixed landmarks without changing calibration or motion sessions.
pub fn moonground_health(source : String) -> String {
  @codec.health_json(source) catch {
    error => failure(error.message())
  }
}
