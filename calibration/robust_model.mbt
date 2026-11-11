///|
/// Bounded, reproducible consensus search in ground metres. Trial counts are
/// computational budgets, rather than statistical confidence guarantees.
pub struct RobustFitOptions {
  inlier_threshold_m : Double
  min_inlier_ratio : Double
  max_trials : Int32
  seed : Int32
} derive(Debug)

///|
pub extend RobustFitOptions with @debug.Debug::{to_repr}

///|
pub fn RobustFitOptions::new(
  inlier_threshold_m~ : Double = 0.05,
  min_inlier_ratio~ : Double = 0.6,
  max_trials~ : Int32 = 512,
  seed~ : Int32 = 1,
) -> RobustFitOptions raise @types.GroundError {
  if !@types.is_finite(inlier_threshold_m) ||
    inlier_threshold_m <= 0.0 ||
    !@types.is_finite(min_inlier_ratio) ||
    min_inlier_ratio <= 0.0 ||
    min_inlier_ratio > 1.0 ||
    max_trials < 1 ||
    max_trials > 4096 ||
    seed < 1 {
    raise @types.InvalidInput("invalid robust calibration options")
  }
  { inlier_threshold_m, min_inlier_ratio, max_trials, seed, }
}

///|
/// Validated calibration and diagnostics in the original control-pair order.
/// Residuals are forward ground distances conditional on the fixed camera.
pub struct RobustCalibration {
  priv calibration_value : GroundCalibration
  priv mask_value : Array[Bool]
  priv errors_value : Array[Double]
  priv inlier_count_value : Int32
  priv trials_value : Int32
  priv valid_hypotheses_value : Int32
  priv refinement_steps_value : Int32
}

///|
pub fn RobustCalibration::calibration(
  self : RobustCalibration,
) -> GroundCalibration {
  self.calibration_value
}

///|
pub fn RobustCalibration::inlier_mask(self : RobustCalibration) -> Array[Bool] {
  self.mask_value.copy()
}

///|
pub fn RobustCalibration::control_errors_m(
  self : RobustCalibration,
) -> Array[Double] {
  self.errors_value.copy()
}

///|
pub fn RobustCalibration::inlier_count(self : RobustCalibration) -> Int32 {
  self.inlier_count_value
}

///|
/// Draws attempted, including degenerate or repeated subsets.
pub fn RobustCalibration::trials_run(self : RobustCalibration) -> Int32 {
  self.trials_value
}

///|
/// Candidates solved, passing the complete ROI policy, with finite residuals.
pub fn RobustCalibration::valid_hypotheses(self : RobustCalibration) -> Int32 {
  self.valid_hypotheses_value
}

///|
/// Refit-and-reclassify passes, including the pass establishing a fixed mask.
pub fn RobustCalibration::refinement_steps(self : RobustCalibration) -> Int32 {
  self.refinement_steps_value
}
