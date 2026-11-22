///|
priv struct ErrorAccumulator {
  count : Int32
  mean_absolute : Double
  scale : Double
  scaled_squares : Double
  maximum : Double
}

///|
fn ErrorAccumulator::empty() -> ErrorAccumulator {
  {
    count: 0,
    mean_absolute: 0.0,
    scale: 0.0,
    scaled_squares: 0.0,
    maximum: 0.0,
  }
}

///|
fn evaluation_finite(value : Double) -> Double raise @types.GroundError {
  if !@types.is_finite(value) {
    raise @types.InvalidInput("evaluation arithmetic is not representable")
  }
  value
}

///|
// Avoid overflowing a signed subtraction when averaging opposite extremes.
fn evaluation_mean(
  previous : Double,
  value : Double,
  count : Int32,
) -> Double raise @types.GroundError {
  if count == 1 {
    value
  } else if (previous < 0.0) != (value < 0.0) {
    evaluation_finite(
      previous * ((count - 1).to_double() / count.to_double()) +
      value / count.to_double(),
    )
  } else {
    evaluation_finite(previous + (value - previous) / count.to_double())
  }
}

///|
// Maintain a scaled sum of squares. Neither 1e200 errors nor 1e-200 errors
// require a representable unscaled square to produce a finite RMS.
fn ErrorAccumulator::add(
  self : ErrorAccumulator,
  error : Double,
) -> ErrorAccumulator raise @types.GroundError {
  let value = evaluation_finite(error).abs()
  let count = self.count + 1
  let (scale, scaled_squares) = if value == 0.0 {
    (self.scale, self.scaled_squares)
  } else if value > self.scale {
    let ratio = self.scale / value
    (value, 1.0 + self.scaled_squares * ratio * ratio)
  } else {
    let ratio = value / self.scale
    (self.scale, self.scaled_squares + ratio * ratio)
  }
  {
    count,
    mean_absolute: evaluation_mean(self.mean_absolute, value, count),
    scale,
    scaled_squares,
    maximum: if value > self.maximum {
      value
    } else {
      self.maximum
    },
  }
}

///|
fn ErrorAccumulator::statistics(self : ErrorAccumulator) -> ErrorStatistics {
  if self.count == 0 {
    {
      samples: 0,
      mean_absolute_error: None,
      root_mean_square_error: None,
      maximum_absolute_error: None,
    }
  } else {
    {
      samples: self.count,
      mean_absolute_error: Some(self.mean_absolute),
      root_mean_square_error: Some(
        self.scale * (self.scaled_squares / self.count.to_double()).sqrt(),
      ),
      maximum_absolute_error: Some(self.maximum),
    }
  }
}

///|
fn evaluation_norm(x : Double, y : Double) -> Double raise @types.GroundError {
  let x = x.abs()
  let y = y.abs()
  let (scale, other) = if x > y { (x, y) } else { (y, x) }
  if scale == 0.0 {
    0.0
  } else {
    let ratio = other / scale
    evaluation_finite(scale * (1.0 + ratio * ratio).sqrt())
  }
}

///|
fn evaluation_coverage(count : Int32, references : Int32) -> Double? {
  if references == 0 {
    None
  } else {
    Some(count.to_double() / references.to_double())
  }
}
