///|
fn linear_invalid(action : () -> Unit raise @types.GroundError) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("unsupported linear covariance accepted")
  }
}

///|
test "zero linear coefficients still validate the original covariance and finite input" {
  let covariance = @types.Covariance2::isotropic(2.0)
  assert_eq(covariance.linear_std({ x: 0.0, y: 0.0, }), 0.0)
  linear_invalid(() => {
    ignore(
      @types.Covariance2::{ xx: 1.0, xy: 2.0, yy: 1.0, }.linear_std({
        x: 0.0,
        y: 0.0,
      }),
    )
  })
  linear_invalid(() => ignore(covariance.linear_std({ x: 1.0 / 0.0, y: 0.0, })))
  linear_invalid(() => ignore(covariance.linear_std({ x: 0.0, y: 0.0 / 0.0, })))
}

///|
test "linear covariance keeps independent tiny and huge variances without using a worst direction scalar" {
  let covariance = @types.Covariance2::new(1.0e200, 0.0, 1.0e-100)
  assert_eq(covariance.linear_std({ x: 1.0, y: 0.0, }), 1.0e100)
  assert_eq(covariance.linear_std({ x: 0.0, y: 1.0, }), 1.0e-50)
  let ordinary = @types.Covariance2::new(4.0, 0.0, 9.0)
  assert_true(
    (ordinary.linear_std({ x: 3.0, y: 4.0, }) / 180.0.sqrt() - 1.0).abs() <
    1.0e-15,
  )
  assert_eq(ordinary.linear_std({ x: -1.0, y: 0.0, }), 2.0)
}

///|
test "power of two covariance scaling preserves correlated linear forms and coefficient scale" {
  for scale in [1.0e-300, 1.0, 1.0e300] {
    for correlation in [-0.9, 0.9] {
      let covariance = @types.Covariance2::new(
        scale,
        correlation * scale,
        scale,
      )
      let actual = covariance.linear_std({ x: 0.6, y: 0.8, })
      assert_true(
        (actual / scale.sqrt() / (1.0 + 0.96 * correlation).sqrt() - 1.0).abs() <
        1.0e-14,
      )
    }
  }
  let covariance = @types.Covariance2::new(1.0e-300, 0.2e-300, 1.0e-300)
  let actual = covariance.linear_std({ x: 1.0e150, y: 0.0, })
  assert_true((actual - 1.0).abs() < 1.0e-15)
}

///|
test "linear covariance rejects unsupported near singular and unrepresentable deviations" {
  for scale in [1.0e-300, 1.0, 1.0e300] {
    let covariance = @types.Covariance2::new(
      scale,
      -0.9999999999999999 * scale,
      scale,
    )
    linear_invalid(() => ignore(covariance.linear_std({ x: 0.6, y: 0.8, })))
  }
  linear_invalid(() => {
    ignore(
      @types.Covariance2::new(1.0e-300, 0.0, 1.0e-300).linear_std({
        x: 1.0e-300,
        y: 0.0,
      }),
    )
  })
  linear_invalid(() => {
    ignore(
      @types.Covariance2::new(1.0e300, 0.0, 1.0e300).linear_std({
        x: 1.0e300,
        y: 0.0,
      }),
    )
  })
}
