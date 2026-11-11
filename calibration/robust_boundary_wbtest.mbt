///|
test "consensus includes an exact binary threshold and excludes its next larger residual" {
  let model = GroundCalibration::from_homography(
    [0.125, 0.0, 0.0, 0.0, 0.125, 0.0, 0.0, 0.0, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 100.0, y: 0.0, },
      { x: 100.0, y: 100.0, },
      { x: 0.0, y: 100.0, },
    ],
  )
  let pixels = Array::makei(6, i => @types.Point2::{ x: i.to_double(), y: 0.0, })
  let world = pixels.map(p => @types.Point2::{ x: p.x * 0.125, y: 0.0, })
  world[4] = { x: 0.5, y: 0.125, }
  world[5] = { x: 0.625, y: 0.12500000000000003, }
  let classified = classify_controls(model, pixels, world, 0.125)
  assert_eq(classified.errors[4], 0.125)
  assert_eq(classified.errors[5], 0.12500000000000003)
  assert_eq(classified.mask, [true, true, true, true, true, false])
  assert_eq(classified.count, 5)
}
