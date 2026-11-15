///|
test "packaged distance comparison retains common scale cancellation and shared cross contribution" {
  let model = consumer_sensitivity()
  let result = model.compare_distances(
    { x: 0.0, y: 0.0, },
    { x: 4.0, y: 0.0, },
    { x: 0.0, y: 1.0, },
    { x: 8.0, y: 1.0, },
  )
  assert_eq(result.first.distance_m, 4.0)
  assert_eq(result.second.distance_m, 8.0)
  assert_eq(result.first.mode_responses_m(), [0.0, 0.5])
  assert_eq(result.cross_contribution_m2, 0.5)
  assert_eq(result.difference_m, -4.0)
  assert_eq(result.difference_contribution_m2, 0.25)
  assert_eq(result.ratio, 0.5)
  assert_eq(result.ratio_contribution, 0.0)
}

///|
test "packaged Euclidean scalar projection handles nonaxis geometry and endpoint reversal" {
  let model = consumer_sensitivity()
  let forward = model.distance({ x: 0.0, y: 0.0, }, { x: 3.0, y: 4.0, })
  let reverse = model.distance({ x: 3.0, y: 4.0, }, { x: 0.0, y: 0.0, })
  assert_eq(forward.distance_m, 5.0)
  assert_eq(forward.direction.x, 0.6)
  assert_eq(forward.direction.y, 0.8)
  assert_eq(forward.mode_responses_m(), [0.0, 0.22499999999999998])
  assert_eq(reverse.mode_responses_m(), forward.mode_responses_m())
  assert_eq(reverse.contribution_m2, forward.contribution_m2)
}

///|
test "packaged distance response copies and degenerate failures preserve independent subsequent queries" {
  let model = consumer_sensitivity()
  let origin : @moonground.Point2 = { x: 0.0, y: 0.0, }
  let short : @moonground.Point2 = { x: 4.0, y: 0.0, }
  let long : @moonground.Point2 = { x: 8.0, y: 0.0, }
  let result = model.compare_distances(origin, short, origin, long)
  let distance = result.first.mode_responses_m()
  distance.clear()
  let differences = result.difference_mode_responses_m()
  differences[1] = 999.0
  let ratios = result.ratio_mode_responses()
  ratios.clear()
  try model.compare_distances(origin, short, origin, origin) catch {
    _ => ()
  } noraise {
    _ => fail("undefined norm derivative accepted")
  }
  try model.distance(origin, { x: 11.0, y: 0.0, }) catch {
    _ => ()
  } noraise {
    _ => fail("outside ROI accepted")
  }
  let repeated = model.compare_distances(origin, short, origin, long)
  assert_eq(repeated.first.mode_responses_m(), [0.0, 0.5])
  assert_eq(repeated.difference_mode_responses_m(), [0.0, -0.5])
  assert_eq(repeated.ratio_mode_responses(), [0.0, 0.0])
}
