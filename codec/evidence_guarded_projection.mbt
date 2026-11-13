///|
fn EvidenceGuardedReplay::replace_projection_frame(
  self : EvidenceGuardedReplay,
  fields : Map[String, Json],
) -> Json raise @types.GroundError {
  let (time, calibration, effective, camera) = projection_replacement(fields)
  let analysis_configuration = replaced_projection_configuration(
    self.analysis_configuration,
    effective,
    camera,
    measurement=true,
  )
  let health_configuration = replaced_projection_configuration(
    self.health_configuration,
    effective,
    camera,
  )
  let result = self.session.replace_projection(time, calibration, camera~)
  self.analysis_configuration = analysis_configuration
  self.health_configuration = health_configuration
  evidence_guarded_frame_json(
    result,
    self.monitor_id,
    self.diagnostics,
    self.sigma_multiplier,
    kind="evidence_guarded_projection_replaced",
  )
}
