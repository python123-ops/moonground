///|
/// Construct from 0..32 finite row-major nine-coefficient perturbation modes.
/// A caller holding a factor in another gauge must first convert that factor.
pub fn HomographySensitivity::new(
  calibration : GroundCalibration,
  modes : Array[Array[Double]],
) -> HomographySensitivity raise @types.GroundError {
  if modes.length() > 32 {
    raise @types.InvalidInput("homography sensitivity accepts at most 32 modes")
  }
  let values : Array[Array[Double]] = []
  for mode in modes {
    if mode.length() != 9 {
      raise @types.InvalidInput(
        "homography sensitivity mode needs 9 coefficients",
      )
    }
    for coefficient in mode {
      if !@types.is_finite(coefficient) {
        raise @types.InvalidInput("homography sensitivity modes must be finite")
      }
    }
    values.push(mode.copy())
  }
  { calibration, mode_values: values, }
}

///|
fn sensitivity_finite(value : Double) -> Double raise @types.GroundError {
  if !@types.is_finite(value) {
    raise @types.InvalidInput("homography sensitivity arithmetic is not finite")
  }
  value
}

///|
fn sensitivity_product(
  a : Double,
  b : Double,
) -> Double raise @types.GroundError {
  let value = sensitivity_finite(a * b)
  if a != 0.0 && b != 0.0 && value == 0.0 {
    raise @types.InvalidInput("homography sensitivity product underflows")
  }
  value
}

///|
// Neumaier summation preserves a small residual across large cancellation.
// Reject nonrepresentable intermediates instead of silently erasing a mode.
fn sensitivity_dot(
  a : Array[Double],
  b : Array[Double],
) -> Double raise @types.GroundError {
  let mut sum = 0.0
  let mut correction = 0.0
  for i in 0..<a.length() {
    let product = sensitivity_product(a[i], b[i])
    let next = sensitivity_finite(sum + product)
    let error = if sum.abs() >= product.abs() {
      sensitivity_finite(sum - next) + product
    } else {
      sensitivity_finite(product - next) + sum
    }
    correction = sensitivity_finite(correction + sensitivity_finite(error))
    sum = next
  }
  sensitivity_finite(sum + correction)
}

///|
fn sensitivity_divide(
  a : Double,
  b : Double,
) -> Double raise @types.GroundError {
  let result = sensitivity_finite(a / b)
  if a != 0.0 && result == 0.0 {
    raise @types.InvalidInput("homography sensitivity quotient underflows")
  }
  result
}

///|
fn sensitivity_gram(
  responses : Array[@types.Point2],
) -> CalibrationContribution2 raise @types.GroundError {
  let xs = responses.map(point => point.x)
  let ys = responses.map(point => point.y)
  {
    xx: sensitivity_dot(xs, xs),
    xy: sensitivity_dot(xs, ys),
    yy: sensitivity_dot(ys, ys),
  }
}

///|
/// Evaluate one already-undistorted pixel in the original closed ROI. The
/// derivative is analytic at the fixed baseline. Contributions are ordinary
/// binary64 first-order estimates, not outward-rounded finite-error bounds.
pub fn HomographySensitivity::evaluate(
  self : HomographySensitivity,
  pixel : @types.Point2,
) -> CalibrationSensitivityPoint raise @types.GroundError {
  let position_m = self.calibration.map_point(pixel)
  if self.mode_values.is_empty() {
    return {
      position_m,
      responses: [],
      contribution_m2: { xx: 0.0, xy: 0.0, yy: 0.0, },
    }
  }
  let h = self.calibration.coefficients
  let w = sensitivity_dot([h[6], h[7], h[8]], [pixel.x, pixel.y, 1.0])
  if w == 0.0 {
    raise @types.InvalidInput("homography sensitivity denominator is zero")
  }
  let basis = [
    sensitivity_divide(pixel.x, w),
    sensitivity_divide(pixel.y, w),
    sensitivity_divide(1.0, w),
  ]
  let x_denominator = basis.map(value => {
    sensitivity_product(-position_m.x, value)
  })
  let y_denominator = basis.map(value => {
    sensitivity_product(-position_m.y, value)
  })
  let responses = self.mode_values.map(mode => {
    @types.Point2::new(
      sensitivity_dot([mode[0], mode[1], mode[2], mode[6], mode[7], mode[8]], [
        basis[0],
        basis[1],
        basis[2],
        x_denominator[0],
        x_denominator[1],
        x_denominator[2],
      ]),
      sensitivity_dot([mode[3], mode[4], mode[5], mode[6], mode[7], mode[8]], [
        basis[0],
        basis[1],
        basis[2],
        y_denominator[0],
        y_denominator[1],
        y_denominator[2],
      ]),
    )
  })
  { position_m, responses, contribution_m2: sensitivity_gram(responses), }
}

///|
/// Project two pixels under the same latent coefficients. Compute relative
/// contribution from response differences directly, rather than subtracting
/// large marginal/cross covariance blocks. Repeated points have exactly zero
/// displacement contribution, including rank-deficient mode sets.
pub fn HomographySensitivity::evaluate_pair(
  self : HomographySensitivity,
  first_pixel : @types.Point2,
  second_pixel : @types.Point2,
) -> CalibrationSensitivityPair raise @types.GroundError {
  let first = self.evaluate(first_pixel)
  let second = self.evaluate(second_pixel)
  let differences : Array[@types.Point2] = []
  for i in 0..<self.mode_values.length() {
    differences.push(
      @types.Point2::new(
        second.responses[i].x - first.responses[i].x,
        second.responses[i].y - first.responses[i].y,
      ),
    )
  }
  let ax = first.responses.map(point => point.x)
  let ay = first.responses.map(point => point.y)
  let bx = second.responses.map(point => point.x)
  let by = second.responses.map(point => point.y)
  {
    first,
    second,
    displacement_m: @types.Point2::new(
      second.position_m.x - first.position_m.x,
      second.position_m.y - first.position_m.y,
    ),
    displacement_contribution_m2: sensitivity_gram(differences),
    cross_block: [
      sensitivity_dot(ax, bx),
      sensitivity_dot(ax, by),
      sensitivity_dot(ay, bx),
      sensitivity_dot(ay, by),
    ],
  }
}
