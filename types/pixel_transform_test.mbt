///|
fn transform_close(actual : Double, expected : Double) -> Unit raise {
  assert_true((actual - expected).abs() <= 1.0e-12 * expected.abs().max(1.0))
}

///|
fn transform_invalid(
  action : () -> Unit raise @types.GroundError,
) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid pixel transformation was accepted")
  }
}

///|
test "pixel resize crop and padding use explicit destination coordinates and correlated covariance" {
  let transform = @types.PixelTransform::new(
    scale_x=2.0,
    scale_y=0.5,
    offset_x=-30.0,
    offset_y=7.0,
  )
  let point = transform.point({ x: 20.0, y: 40.0, })
  assert_eq(point.x, 10.0)
  assert_eq(point.y, 27.0)
  let covariance = transform.covariance(@types.Covariance2::new(4.0, 1.0, 9.0))
  assert_eq(covariance.xx, 16.0)
  assert_eq(covariance.xy, 1.0)
  assert_eq(covariance.yy, 2.25)
  let identity = @types.PixelTransform::new()
  assert_eq(identity.scale_x, 1.0)
  assert_eq(identity.scale_y, 1.0)
  assert_eq(identity.offset_x, 0.0)
  assert_eq(identity.offset_y, 0.0)
}

///|
test "pixel composition follows application order and its inverse restores point and covariance" {
  let first = @types.PixelTransform::new(
    scale_x=0.3,
    scale_y=4.0,
    offset_x=-17.0,
    offset_y=3.0,
  )
  let next = @types.PixelTransform::new(
    scale_x=2.0,
    scale_y=0.25,
    offset_x=8.0,
    offset_y=-9.0,
  )
  let combined = first.then(next)
  let source : @types.Point2 = { x: 120.0, y: -16.0, }
  let expected = next.point(first.point(source))
  let actual = combined.point(source)
  transform_close(actual.x, expected.x)
  transform_close(actual.y, expected.y)
  assert_true(first.point(next.point(source)).x != actual.x)
  let recovered = combined.inverse().point(actual)
  transform_close(recovered.x, source.x)
  transform_close(recovered.y, source.y)
  let covariance = @types.Covariance2::new(4.0, -0.7, 9.0)
  let sequential = next.covariance(first.covariance(covariance))
  let transformed = combined.covariance(covariance)
  transform_close(transformed.xx, sequential.xx)
  transform_close(transformed.xy, sequential.xy)
  transform_close(transformed.yy, sequential.yy)
  let restored = combined.inverse().covariance(transformed)
  transform_close(restored.xx, covariance.xx)
  transform_close(restored.xy, covariance.xy)
  transform_close(restored.yy, covariance.yy)
}

///|
test "pixel covariance scaling avoids premature scale squaring overflow and underflow" {
  for scale in [1.0e200, 1.0e-200] {
    let transform = @types.PixelTransform::new(scale_x=scale, scale_y=scale)
    let source = @types.Covariance2::new(1.0 / scale, 0.1 / scale, 2.0 / scale)
    let actual = transform.covariance(source)
    assert_true((actual.xx / scale - 1.0).abs() < 1.0e-14)
    assert_true((actual.xy / scale - 0.1).abs() < 1.0e-14)
    assert_true((actual.yy / scale - 2.0).abs() < 1.0e-14)
  }
}

///|
test "pixel transformations reject invalid scales public inputs and unrepresentable arithmetic" {
  for scale in [0.0, -1.0, 1.0 / 0.0, 0.0 / 0.0] {
    transform_invalid(() => ignore(@types.PixelTransform::new(scale_x=scale)))
    transform_invalid(() => ignore(@types.PixelTransform::new(scale_y=scale)))
  }
  for offset in [1.0 / 0.0, 0.0 / 0.0] {
    transform_invalid(() => ignore(@types.PixelTransform::new(offset_x=offset)))
    transform_invalid(() => ignore(@types.PixelTransform::new(offset_y=offset)))
  }
  let large = @types.PixelTransform::new(scale_x=1.0e200, scale_y=1.0e200)
  transform_invalid(() => ignore(large.point({ x: 1.0e200, y: 0.0, })))
  transform_invalid(() => ignore(large.then(large)))
  transform_invalid(() => {
    ignore(@types.PixelTransform::new(scale_x=1.0e-320).inverse())
  })
  let identity = @types.PixelTransform::new()
  transform_invalid(() => ignore(identity.point({ x: 0.0 / 0.0, y: 0.0, })))
  transform_invalid(() => {
    ignore(identity.covariance({ xx: 1.0, xy: 2.0, yy: 1.0, }))
  })
  transform_invalid(() => {
    ignore(large.covariance(@types.Covariance2::isotropic(1.0)))
  })
  transform_invalid(() => {
    ignore(
      @types.PixelTransform::new(scale_x=1.0e-200, scale_y=1.0e-200).covariance(
        @types.Covariance2::isotropic(1.0),
      ),
    )
  })
}
