///|
fn component_invalid(
  action : () -> Unit raise @types.GroundError,
) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("unsupported projection accepted")
  }
}

///|
test "shared component keeps exact and ordinary near orthogonality with compensated cancellation" {
  let diagonal = 0.5.sqrt()
  assert_eq(
    @types.Point2::{ x: 1.0, y: -1.0, }.component_along({
      x: diagonal,
      y: diagonal,
    }),
    0.0,
  )
  assert_eq(
    @types.Point2::{ x: 4.0, y: -3.0, }.component_along({ x: 0.6, y: 0.8, }),
    -2.220446049250313e-16,
  )
  assert_eq(
    @types.Point2::{ x: 1.0e300, y: -7.5e299, }.component_along({
      x: 0.6,
      y: 0.8,
    }),
    -5.551115123125783e283,
  )
  assert_eq(
    @types.Point2::{ x: 0.0, y: 0.0, }.component_along({ x: 1.0, y: 0.0, }),
    0.0,
  )
}

///|
test "shared component validates unit inputs and rejects lost terms and result overflow" {
  for
    direction in [
      @types.Point2::{ x: 0.0, y: 0.0, },
      { x: 1.0, y: 1.0, },
      { x: 1.0 / 0.0, y: 0.0, },
    ] {
    component_invalid(() => {
      ignore(@types.Point2::{ x: 0.0, y: 0.0, }.component_along(direction))
    })
  }
  component_invalid(() => {
    ignore(
      @types.Point2::{ x: 0.0 / 0.0, y: 0.0, }.component_along({
        x: 1.0,
        y: 0.0,
      }),
    )
  })
  component_invalid(() => {
    ignore(
      @types.Point2::{ x: 1.0e308, y: 1.0e-300, }.component_along({
        x: 0.6,
        y: 0.8,
      }),
    )
  })
  component_invalid(() => {
    ignore(
      @types.Point2::{ x: 1.7e308, y: 1.7e308, }.component_along({
        x: 0.6,
        y: 0.8,
      }),
    )
  })
}

///|
test "raw directed line distance preserves exact non-axis boundaries and one ULP side changes" {
  let edge : @types.Point2 = { x: 3.0, y: 4.0, }
  for
    offset in [
      @types.Point2::{ x: 3.0, y: 4.0, },
      { x: 1.5, y: 2.0, },
      { x: -6.0, y: -8.0, },
      { x: 0.0, y: 0.0, },
    ] {
    assert_eq(offset.signed_line_distance(edge), 0.0)
  }
  let above = (4.0.reinterpret_as_int64() + 1L).reinterpret_as_double()
  let below = (4.0.reinterpret_as_int64() - 1L).reinterpret_as_double()
  assert_true(
    @types.Point2::{ x: 3.0, y: above, }.signed_line_distance(edge) > 0.0,
  )
  assert_true(
    @types.Point2::{ x: 3.0, y: below, }.signed_line_distance(edge) < 0.0,
  )
  assert_eq(@types.Point2::{ x: 3.0, y: 0.0, }.signed_line_distance(edge), -2.4)
}

///|
test "raw line determinant scaling avoids large product overflow and retains metric scale and winding" {
  for scale in [1.0e-300, 1.0, 1.0e300] {
    let actual = @types.Point2::{ x: 0.0, y: 5.0 * scale, }.signed_line_distance({
        x: 3.0 * scale,
        y: 4.0 * scale,
      },
    )
    assert_true((actual / scale / 3.0 - 1.0).abs() < 1.0e-14)
    let reverse = @types.Point2::{ x: 0.0, y: 5.0 * scale, }.signed_line_distance({
        x: -3.0 * scale,
        y: -4.0 * scale,
      },
    )
    assert_eq(reverse, -actual)
  }
}

///|
test "raw line domain validates even zero offsets and rejects unrepresentable scaling and distances" {
  component_invalid(() => {
    ignore(
      @types.Point2::{ x: 0.0, y: 0.0, }.signed_line_distance({
        x: 0.0,
        y: 0.0,
      }),
    )
  })
  component_invalid(() => {
    ignore(
      @types.Point2::{ x: 0.0, y: 0.0, }.signed_line_distance({
        x: 1.0 / 0.0,
        y: 0.0,
      }),
    )
  })
  component_invalid(() => {
    ignore(
      @types.Point2::{ x: 0.0, y: 1.0, }.signed_line_distance({
        x: 1.0e-300,
        y: 1.0e300,
      }),
    )
  })
  component_invalid(() => {
    ignore(
      @types.Point2::{ x: 1.7e308, y: 1.7e308, }.signed_line_distance({
        x: 1.0,
        y: -1.0,
      }),
    )
  })
  component_invalid(() => {
    ignore(
      @types.Point2::{ x: 4.9406564584124654e-324, y: 0.0, }.signed_line_distance({
          x: 1.0,
          y: 1.0e-10,
        },
      ),
    )
  })
  component_invalid(() => {
    ignore(
      @types.Point2::{ x: 1.0, y: 0.0, }.signed_line_distance({
        x: 1.0,
        y: 1.0e-310,
      }),
    )
  })
}
