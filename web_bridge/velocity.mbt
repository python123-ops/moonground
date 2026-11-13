///|
/// Project current accepted metric velocities under explicit covariance rules.
pub fn moonground_velocity_evidence(source : String) -> String {
  @codec.velocity_evidence_json(source) catch {
    error => failure(error.message())
  }
}
