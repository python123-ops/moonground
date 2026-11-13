///|
/// Count filtered measurements using persisted normal-covariance side evidence.
pub fn moonground_gate_evidence(source : String) -> String {
  @codec.gate_evidence_json(source) catch {
    error => failure(error.message())
  }
}
