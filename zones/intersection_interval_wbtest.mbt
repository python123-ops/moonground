///|
test "outward binary neighbours include signed zeros and subnormal transitions" {
  let tiny = 1L.reinterpret_as_double()
  assert_eq(intersection_next_up(0.0), tiny)
  assert_eq(intersection_next_up(-0.0), tiny)
  assert_eq(intersection_next_down(0.0), -tiny)
  assert_eq(intersection_next_down(-0.0), -tiny)
  assert_eq(intersection_next_up(-tiny), 0.0)
  assert_eq(intersection_next_down(tiny), 0.0)
  assert_true(intersection_next_up(1.0) > 1.0)
  assert_true(intersection_next_down(-1.0) < -1.0)
}

///|
test "power of two multiplication and division enclose halfway normal subnormal boundaries in both signs" {
  let almost = 0x001fffffffffffffL.reinterpret_as_double()
  let normal = 2.2250738585072014e-308
  for sign in [1.0, -1.0] {
    let product = intersection_scalar_mul(sign * almost, 0.5)
    let quotient = intersection_scalar_div(sign * almost, 2.0)
    if sign > 0.0 {
      assert_true(product.lower < normal && product.upper >= normal)
      assert_true(quotient.lower < normal && quotient.upper >= normal)
    } else {
      assert_true(product.lower <= -normal && product.upper > -normal)
      assert_true(quotient.lower <= -normal && quotient.upper > -normal)
    }
  }
}

///|
test "positive subnormal operations are enclosed instead of silently becoming zero" {
  let tiny = 1L.reinterpret_as_double()
  let product = intersection_scalar_mul(tiny, 0.5)
  assert_true(product.lower <= 0.0 && product.upper >= tiny)
  let quotient = intersection_scalar_div(tiny, 2.0)
  assert_true(quotient.lower <= 0.0 && quotient.upper >= tiny)
  let sum = intersection_scalar_add(tiny, tiny)
  assert_eq(sum.lower, 2L.reinterpret_as_double())
  assert_eq(sum.upper, 2L.reinterpret_as_double())
}

///|
test "finite sums retain outward bounds when TwoSum intermediate overflows" {
  let large = 0x7fefffffffffffffL.reinterpret_as_double()
  let correction = -0x7ca8000000000000L.reinterpret_as_double()
  let positive = intersection_scalar_add(correction, large)
  let rounded = correction + large
  assert_true(positive.lower < rounded)
  assert_true(positive.upper > rounded)
  let negative = intersection_scalar_add(-correction, -large)
  assert_true(negative.lower < -rounded)
  assert_true(negative.upper > -rounded)
}
