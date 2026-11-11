///|
fn observation_matrix() -> @kalman.Matrix {
  @kalman.Matrix::from_rows([[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0]])
}

///|
fn measurement_matrix(covariance : @types.Covariance2) -> @kalman.Matrix {
  @kalman.Matrix::from_rows([
    [covariance.xx, covariance.xy],
    [covariance.xy, covariance.yy],
  ])
}

///|
/// The upstream convenience helper models piecewise-constant acceleration.
/// This adapter instead uses continuous white acceleration with intensity q.
fn process_matrix(dt : Double, q : Double) -> @kalman.Matrix {
  let pp = q * dt * dt * dt / 3.0
  let pv = q * dt * dt / 2.0
  let vv = q * dt
  @kalman.Matrix::from_rows([
    [pp, 0.0, pv, 0.0],
    [0.0, pp, 0.0, pv],
    [pv, 0.0, vv, 0.0],
    [0.0, pv, 0.0, vv],
  ])
}

///|
fn healthy_state(state : Array[Double], covariance : @kalman.Matrix) -> Bool {
  if state.length() != 4 ||
    covariance.rows() != 4 ||
    covariance.cols() != 4 ||
    !covariance.is_finite() {
    return false
  }
  for value in state {
    if !@types.is_finite(value) {
      return false
    }
  }
  // Scale before the upstream eigenvalue diagnostic to avoid fixed-unit
  // tolerances and overflow in extreme but finite public input.
  let scale = covariance.max_abs()
  if !@types.is_finite(scale) || scale <= 0.0 {
    return false
  }
  let normalized = covariance.map(value => value / scale)
  normalized.is_finite() && @kalman.covariance_is_psd(normalized, 0.000000001)
}

///|
fn covariance_block(
  covariance : @kalman.Matrix,
  offset : Int32,
) -> @types.Covariance2? {
  let result : @types.Covariance2 = {
    xx: covariance.get(offset, offset),
    xy: covariance.get(offset, offset + 1),
    yy: covariance.get(offset + 1, offset + 1),
  }
  try {
    result.validate()
    Some(result)
  } catch {
    _ => None
  }
}

///|
fn flatten_covariance(covariance : @kalman.Matrix) -> Array[Double] {
  Array::makei(16, i => covariance.get(i / 4, i % 4))
}

///|
fn norm2(x : Double, y : Double) -> Double {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    0.0
  } else {
    let nx = x / scale
    let ny = y / scale
    scale * (nx * nx + ny * ny).sqrt()
  }
}
