///|
/// Replay downstream transit timing without allocating a browser session handle.
pub fn moonground_transit(source : String) -> String {
  @codec.transit_json(source) catch {
    error => failure(error.message())
  }
}
