///|
/// Analyze and count one bounded raw observation log without session handles.
pub fn moonground_analysis(source : String) -> String {
  @codec.analysis_json(source) catch {
    error => failure(error.message())
  }
}
