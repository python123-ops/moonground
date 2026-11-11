///|
test "restore revalidates every motion configuration parameter" {
  let checkpoint = MotionEstimator::new(
    "config-validation",
    MotionConfig::new(),
  ).checkpoint()
  let valid = checkpoint.config
  for
    invalid in [
      { ..valid, max_gap_us: 0L, },
      { ..valid, min_observations: 1, },
      { ..valid, min_span_us: -1L, },
      { ..valid, max_tracks: 0, },
      { ..valid, acceleration_spectral_density: -1.0, },
      { ..valid, acceleration_spectral_density: 0.0 / 0.0, },
      { ..valid, initial_velocity_std: 0.0, },
      { ..valid, initial_velocity_std: 1.0e200, },
      { ..valid, initial_velocity_std: 1.0e-200, },
      { ..valid, innovation_gate: 0.0, },
      { ..valid, innovation_gate: 1.0 / 0.0, },
      { ..valid, max_position_std_m: Some(0.0), },
      { ..valid, max_velocity_std_mps: Some(0.0 / 0.0), },
    ] {
    try
      MotionEstimator::from_checkpoint({ ..checkpoint, config: invalid, })
    catch {
      @types.InvalidInput(_) => ()
    } noraise {
      _ => fail("invalid checkpoint configuration restored")
    }
  }
}
