///|
/// Reframe a bounded raw observation stream atomically, without allocating a
/// session handle. The original NDJSON text is parsed by the shared codec.
pub fn moonground_reframe(source : String) -> String {
  @codec.reframe_json(source) catch {
    error => failure(error.message())
  }
}
