///|
/// Bound-aware duration classifications by exact confirmation-frame windows.
pub fn moonground_transit_windows(source : String) -> String {
  @codec.transit_windows_json(source) catch {
    error => failure(error.message())
  }
}
