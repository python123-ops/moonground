///|
test "robust calibration refits noisy consensus to a self-consistent fixed point" {
  // Fixed projective measurements with independently generated Gaussian noise
  // and nine larger perturbations (NumPy seed 20261137).
  let pixels = Array::makei(36, i => @types.Point2::{
    x: 230.0 + (i % 6).to_double() * 164.0,
    y: 130.0 + (i / 6).to_double() * 96.0,
  })
  let measured : Array[(Double, Double)] = [
    (0.8662431524943057, 0.743016565820469),
    (4.000959970294157, 0.5884318447668269),
    (7.092219434664715, 0.35988472104326874),
    (9.938413634372347, 0.25152106674009733),
    (12.744655641264382, 0.10466052487591111),
    (15.453041248994081, -0.04698630071362547),
    (1.1643687251951573, 2.8421753813226984),
    (4.211411937265719, 2.712349848627046),
    (7.253238107818562, 2.4997841082644525),
    (10.158405852741312, 2.307466281972536),
    (13.037275524360224, 2.054725816879039),
    (15.705358928295313, 1.9390858689026957),
    (1.2708134070309658, 5.143044028651588),
    (4.444594458637273, 4.8764358911635295),
    (7.579974488194004, 4.565190015782645),
    (10.404054794512103, 4.39654132930643),
    (13.251099817408768, 4.154573480521998),
    (15.964831137886742, 3.922517812826954),
    (1.5781103359608595, 7.291478154342338),
    (4.654691378248395, 7.069612825566994),
    (7.716984300897092, 6.766643105907544),
    (10.663499280305109, 6.497989846210661),
    (13.585093070782218, 6.175350220430297),
    (16.22896607183641, 5.966700501287481),
    (1.685945244898678, 9.630855745571278),
    (4.887193107943039, 9.274222625625352),
    (8.056302714248233, 8.885243468833275),
    (10.904706210981251, 8.607301740332485),
    (13.772453258391733, 8.308601395919245),
    (16.508737049356466, 8.01538370261923),
    (1.9734276109757771, 11.876322565930462),
    (5.102363655675793, 11.504873652792721),
    (8.186348493127317, 11.139665640096402),
    (11.169740016000654, 10.773559230723807),
    (14.109932652948515, 10.362224417090319),
    (16.784353063420475, 10.075920369223883),
  ]
  let world = measured.map(p => @types.Point2::{ x: p.0, y: p.1, })
  let checks : Array[@types.Point2] = [
    { x: 310.0, y: 210.0, },
    { x: 450.0, y: 470.0, },
    { x: 760.0, y: 260.0, },
    { x: 970.0, y: 530.0, },
    { x: 610.0, y: 390.0, },
    { x: 870.0, y: 570.0, },
  ]
  let check_world : Array[@types.Point2] = [
    { x: 2.577591255123951, y: 2.4594963888346677, },
    { x: 5.836420354844999, y: 8.149736790797427, },
    { x: 10.920416511714391, y: 2.993677947192264, },
    { x: 15.224967730038726, y: 8.50082979900424, },
    { x: 8.591160220994476, y: 6.058296818441609, },
    { x: 13.639506634273967, y: 9.568304989721547, },
  ]
  let roi : Array[@types.Point2] = [
    { x: 200.0, y: 100.0, },
    { x: 1080.0, y: 100.0, },
    { x: 1080.0, y: 650.0, },
    { x: 200.0, y: 650.0, },
  ]
  let result = @calibration.GroundCalibration::fit_robust(
    pixels,
    world,
    checks,
    check_world,
    roi,
    options=robust_options(threshold=0.015, ratio=0.6, trials=128, seed=17),
    max_fit_error_m=0.02,
    max_check_error_m=0.05,
  )
  assert_eq(result.inlier_count(), 23)
  assert_eq(result.refinement_steps(), 2)
  assert_eq(result.trials_run(), 128)
  assert_robust_consistent(result, pixels, world, 0.015)
  let mask = result.inlier_mask()
  let inlier_pixels : Array[@types.Point2] = []
  let inlier_world : Array[@types.Point2] = []
  for i in 0..<pixels.length() {
    if mask[i] {
      inlier_pixels.push(pixels[i])
      inlier_world.push(world[i])
    }
  }
  let independently_refitted = @calibration.GroundCalibration::fit(
    inlier_pixels,
    inlier_world,
    checks,
    check_world,
    roi,
    max_fit_error_m=0.02,
    max_check_error_m=0.05,
  )
  assert_eq(independently_refitted.matrix(), result.calibration().matrix())
}
