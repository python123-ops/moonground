///|
// Compare the exact decimal token with the already range-checked Int32.
// Removing decimal zeros permits 4.0, 4e0 and 40e-1 without rounding a fraction.
// Counters and exponents are bounded by the maximum accepted document length.
fn integer_token_equals(source : String, expected : Int32) -> Bool {
  let length = source.length()
  if length == 0 || length > 8388608 || source[0] == 45 {
    return false
  }
  let mut index = 0
  let mut fractional = false
  let mut fraction_digits = 0
  let mut significant_digits = 0
  let mut trailing_zeros = 0
  let mut first_nonzero = -1
  let mut last_nonzero = -1
  while index < length && source[index] != 101 && source[index] != 69 {
    let character = source[index].to_int()
    if character == 46 {
      if fractional {
        return false
      }
      fractional = true
    } else {
      if character < 48 || character > 57 {
        return false
      }
      if fractional {
        fraction_digits += 1
      }
      if character != 48 {
        if first_nonzero == -1 {
          first_nonzero = index
        }
        last_nonzero = index
        trailing_zeros = 0
      } else if first_nonzero != -1 {
        trailing_zeros += 1
      }
      if first_nonzero != -1 {
        significant_digits += 1
      }
    }
    index += 1
  }
  if first_nonzero == -1 || significant_digits - trailing_zeros > 10 {
    return false
  }
  let mut exponent = 0
  let mut negative_exponent = false
  if index < length {
    index += 1
    if index < length && (source[index] == 45 || source[index] == 43) {
      negative_exponent = source[index] == 45
      index += 1
    }
    if index == length {
      return false
    }
    let limit = length + 10
    while index < length {
      let digit = source[index].to_int() - 48
      if digit < 0 ||
        digit > 9 ||
        exponent > limit / 10 ||
        (exponent == limit / 10 && digit > limit % 10) {
        return false
      }
      exponent = exponent * 10 + digit
      index += 1
    }
  }
  if negative_exponent {
    exponent = -exponent
  }
  let mut coefficient = 0L
  for index in first_nonzero..<=last_nonzero {
    let digit = source[index].to_int() - 48
    if digit != -2 {
      coefficient = coefficient * 10L + Int64::from_int(digit)
    }
  }
  let mut expected_coefficient = expected
  let mut expected_power = 0
  while expected_coefficient % 10 == 0 {
    expected_coefficient = expected_coefficient / 10
    expected_power += 1
  }
  coefficient == Int64::from_int(expected_coefficient) &&
  exponent - fraction_digits + trailing_zeros == expected_power
}
