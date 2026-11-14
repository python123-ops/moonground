///|
/// Bounded metric-position ellipse intersection under the original raw protocol.
pub fn moonground_zone_intersection(source : String) -> String {
  @codec.zone_intersection_json(source) catch {
    error => failure(error.message())
  }
}
