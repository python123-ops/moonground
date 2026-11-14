///|
priv struct IntersectionInterval {
  lower : Double
  upper : Double
}

///|
fn intersection_finite(value : Double) -> Double raise @types.GroundError {
  if !@types.is_finite(value) {
    raise @types.InvalidInput("ellipse intersection bound is not representable")
  }
  value
}

///|
fn intersection_next_up(value : Double) -> Double raise @types.GroundError {
  ignore(intersection_finite(value))
  if value == 0.0 {
    return 1L.reinterpret_as_double()
  }
  let bits = value.reinterpret_as_int64()
  intersection_finite(
    (if value > 0.0 { bits + 1L } else { bits - 1L }).reinterpret_as_double(),
  )
}

///|
fn intersection_next_down(value : Double) -> Double raise @types.GroundError {
  ignore(intersection_finite(value))
  if value == 0.0 {
    return -1L.reinterpret_as_double()
  }
  let bits = value.reinterpret_as_int64()
  intersection_finite(
    (if value > 0.0 { bits - 1L } else { bits + 1L }).reinterpret_as_double(),
  )
}

///|
fn intersection_point(
  value : Double,
) -> IntersectionInterval raise @types.GroundError {
  let value = intersection_finite(value)
  { lower: value, upper: value, }
}

///|
fn intersection_neg(value : IntersectionInterval) -> IntersectionInterval {
  { lower: -value.upper, upper: -value.lower, }
}

///|
// TwoSum determines which neighbour is needed; a zero residual certifies exact
// addition, including cancellation and gradual-underflow sums of binary64s.
fn intersection_scalar_add(
  a : Double,
  b : Double,
) -> IntersectionInterval raise @types.GroundError {
  let sum = intersection_finite(a + b)
  let displaced = sum - a
  if !@types.is_finite(displaced) {
    return {
      lower: intersection_next_down(sum),
      upper: intersection_next_up(sum),
    }
  }
  let error = a - (sum - displaced) + (b - displaced)
  if !@types.is_finite(error) {
    return {
      lower: intersection_next_down(sum),
      upper: intersection_next_up(sum),
    }
  }
  {
    lower: if error < 0.0 {
      intersection_next_down(sum)
    } else {
      sum
    },
    upper: if error > 0.0 {
      intersection_next_up(sum)
    } else {
      sum
    },
  }
}

///|
fn intersection_add(
  a : IntersectionInterval,
  b : IntersectionInterval,
) -> IntersectionInterval raise @types.GroundError {
  {
    lower: intersection_scalar_add(a.lower, b.lower).lower,
    upper: intersection_scalar_add(a.upper, b.upper).upper,
  }
}

///|
fn intersection_sub(
  a : IntersectionInterval,
  b : IntersectionInterval,
) -> IntersectionInterval raise @types.GroundError {
  intersection_add(a, intersection_neg(b))
}

///|
fn intersection_normal_power_two(value : Double) -> Bool {
  let bits = value.abs().reinterpret_as_int64()
  (bits & 0x7ff0000000000000L) != 0L && (bits & 0x000fffffffffffffL) == 0L
}

///|
fn intersection_scalar_mul(
  a : Double,
  b : Double,
) -> IntersectionInterval raise @types.GroundError {
  if a == 0.0 || b == 0.0 {
    return { lower: 0.0, upper: 0.0, }
  }
  let product = intersection_finite(a * b)
  if product.abs() > 2.2250738585072014e-308 &&
    (intersection_normal_power_two(a) || intersection_normal_power_two(b)) {
    return { lower: product, upper: product, }
  }
  {
    lower: intersection_next_down(product),
    upper: intersection_next_up(product),
  }
}

///|
fn intersection_mul(
  a : IntersectionInterval,
  b : IntersectionInterval,
) -> IntersectionInterval raise @types.GroundError {
  let first = intersection_scalar_mul(a.lower, b.lower)
  let second = intersection_scalar_mul(a.lower, b.upper)
  let third = intersection_scalar_mul(a.upper, b.lower)
  let fourth = intersection_scalar_mul(a.upper, b.upper)
  {
    lower: first.lower.min(second.lower).min(third.lower).min(fourth.lower),
    upper: first.upper.max(second.upper).max(third.upper).max(fourth.upper),
  }
}

///|
fn intersection_square(
  value : IntersectionInterval,
) -> IntersectionInterval raise @types.GroundError {
  let first = intersection_scalar_mul(value.lower, value.lower)
  let second = intersection_scalar_mul(value.upper, value.upper)
  {
    lower: if value.lower <= 0.0 && value.upper >= 0.0 {
      0.0
    } else {
      first.lower.min(second.lower).max(0.0)
    },
    upper: first.upper.max(second.upper),
  }
}

///|
fn intersection_scalar_div(
  a : Double,
  b : Double,
) -> IntersectionInterval raise @types.GroundError {
  let value = intersection_finite(a / b)
  if a == 0.0 ||
    a == b ||
    (value.abs() > 2.2250738585072014e-308 && intersection_normal_power_two(b)) {
    return { lower: value, upper: value, }
  }
  { lower: intersection_next_down(value), upper: intersection_next_up(value), }
}

///|
fn intersection_div(
  a : IntersectionInterval,
  b : IntersectionInterval,
) -> IntersectionInterval raise @types.GroundError {
  if b.lower <= 0.0 && b.upper >= 0.0 {
    raise @types.InvalidInput(
      "ellipse intersection interval divisor includes zero",
    )
  }
  let first = intersection_scalar_div(a.lower, b.lower)
  let second = intersection_scalar_div(a.lower, b.upper)
  let third = intersection_scalar_div(a.upper, b.lower)
  let fourth = intersection_scalar_div(a.upper, b.upper)
  {
    lower: first.lower.min(second.lower).min(third.lower).min(fourth.lower),
    upper: first.upper.max(second.upper).max(third.upper).max(fourth.upper),
  }
}

///|
fn intersection_scale(largest : Double) -> (Double, Int32) {
  let exponent = largest.reinterpret_as_int64() & 0x7ff0000000000000L
  if exponent == 0L {
    (2.2250738585072014e-308, -1022)
  } else {
    (exponent.reinterpret_as_double(), (exponent >> 52).to_int() - 1023)
  }
}

///|
fn intersection_rescale(
  input : IntersectionInterval,
  exponent : Int32,
) -> IntersectionInterval raise @types.GroundError {
  let mut value = { lower: input.lower.max(0.0), upper: input.upper, }
  let mut remaining = exponent
  while remaining != 0 {
    let step = if remaining > 512 {
      512
    } else if remaining < -512 {
      -512
    } else {
      remaining
    }
    let scale = ((step + 1023).to_int64() << 52).reinterpret_as_double()
    value = intersection_mul(value, intersection_point(scale))
    remaining -= step
  }
  { lower: value.lower.max(0.0), upper: value.upper, }
}
