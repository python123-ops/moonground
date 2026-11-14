///|
fn intersection_ref_square(
  k~ : Double = 1.0,
) -> @zones.ConvexZone raise @types.GroundError {
  @zones.ConvexZone::new(
    "exact-square",
    [
      { x: 0.0, y: 0.0, },
      { x: 1.0, y: 0.0, },
      { x: 1.0, y: 1.0, },
      { x: 0.0, y: 1.0, },
    ],
    sigma_multiplier=k,
  )
}

///|
fn intersection_ref_encloses(
  result : @zones.PositionZoneIntersection,
  exact : Double,
) -> Unit raise {
  assert_true(result.minimum_quadratic_lower >= 0.0)
  assert_true(result.minimum_quadratic_lower <= exact)
  assert_true(result.minimum_quadratic_upper >= exact)
  assert_true(@types.is_finite(result.minimum_quadratic_lower))
  assert_true(@types.is_finite(result.minimum_quadratic_upper))
}

///|
test "intersection exact corner Q2 separates where both old supporting bands touch" {
  let zone = intersection_ref_square()
  let point : @types.Point2 = { x: 1.125, y: 1.125, }
  let covariance = @types.Covariance2::new(0.015625, 0.0, 0.015625)
  assert_eq(
    zone.evaluate(point, covariance).decision,
    @zones.ZoneDecision::Indeterminate,
  )
  let result = zone.intersect_position(point, covariance)
  intersection_ref_encloses(result, 2.0)
  assert_eq(result.decision, @zones.Disjoint)
  assert_true(result.witness_edge_index is Some(_))
  assert_true(result.witness_fraction is Some(_))
}

///|
test "intersection certified centre gives exact zero without requiring full ellipse containment" {
  let result = intersection_ref_square().intersect_position(
    { x: 0.5, y: 0.5, },
    @types.Covariance2::isotropic(100.0),
  )
  assert_eq(result.minimum_quadratic_lower, 0.0)
  assert_eq(result.minimum_quadratic_upper, 0.0)
  assert_eq(result.decision, @zones.Intersects)
  assert_true(result.witness_edge_index is None)
  assert_true(result.witness_fraction is None)
  assert_eq(result.witness_position_m.x, 0.5)
  assert_eq(result.witness_position_m.y, 0.5)
}

///|
test "intersection zero radius does not turn a slanted outside centre into a false zero proof" {
  let zone = @zones.ConvexZone::new(
    "slanted",
    [{ x: 0.0, y: 0.0, }, { x: 3.0, y: 4.0, }, { x: 0.0, y: 5.0, }],
    sigma_multiplier=0.0,
  )
  let covariance = @types.Covariance2::isotropic(1.0)
  let outside = zone.intersect_position(
    { x: 1.5, y: 1.9999999999999998, },
    covariance,
  )
  assert_true(outside.decision != @zones.Intersects)
  assert_true(outside.minimum_quadratic_upper > 0.0)
  let inside = zone.intersect_position(
    { x: 1.5, y: 2.0000000000000004, },
    covariance,
  )
  intersection_ref_encloses(inside, 0.0)
  assert_true(inside.decision != @zones.Disjoint)
}

///|
test "intersection exact tangent may remain indeterminate but never disjoint" {
  let result = intersection_ref_square().intersect_position(
    { x: 1.125, y: 0.5, },
    @types.Covariance2::new(0.015625, 0.0, 0.015625),
  )
  intersection_ref_encloses(result, 1.0)
  assert_true(result.decision != @zones.Disjoint)
}

///|
test "intersection vertex and edge zero scale queries retain original closed geometry" {
  let zone = intersection_ref_square(k=0.0)
  let points : Array[@types.Point2] = [
    { x: 0.0, y: 0.0, },
    { x: 1.0, y: 1.0, },
    { x: 0.5, y: 0.0, },
    { x: 1.0, y: 0.5, },
  ]
  for point in points {
    let result = zone.intersect_position(
      point,
      @types.Covariance2::isotropic(1.0),
    )
    intersection_ref_encloses(result, 0.0)
    assert_true(result.decision != @zones.Disjoint)
  }
  let outside = zone.intersect_position(
    { x: 2.0, y: 0.5, },
    @types.Covariance2::isotropic(1.0),
  )
  intersection_ref_encloses(outside, 1.0)
  assert_eq(outside.decision, @zones.Disjoint)
}

///|
test "intersection correlated metric uses the closest edge point rather than Euclidean projection" {
  let result = intersection_ref_square(k=0.0).intersect_position(
    { x: 2.0, y: 0.5, },
    @types.Covariance2::new(1.0, 0.5, 1.0),
  )
  // Metric projection lies at (1,0), t=1 on the lower edge or t=0 on right.
  intersection_ref_encloses(result, 1.0)
  assert_eq(result.decision, @zones.Disjoint)
}

///|
test "intersection correlated corner has independently computed two thirds quadratic" {
  let result = intersection_ref_square(k=0.5).intersect_position(
    { x: 2.0, y: 2.0, },
    @types.Covariance2::new(2.0, 1.0, 2.0),
  )
  intersection_ref_encloses(result, 2.0 / 3.0)
  assert_eq(result.decision, @zones.Disjoint)
}

///|
test "intersection reversed and cyclic vertices preserve the same global minimum" {
  let originals : Array[Array[@types.Point2]] = [
    [
      { x: 0.0, y: 0.0, },
      { x: 1.0, y: 0.0, },
      { x: 1.0, y: 1.0, },
      { x: 0.0, y: 1.0, },
    ],
    [
      { x: 0.0, y: 1.0, },
      { x: 1.0, y: 1.0, },
      { x: 1.0, y: 0.0, },
      { x: 0.0, y: 0.0, },
    ],
    [
      { x: 1.0, y: 1.0, },
      { x: 0.0, y: 1.0, },
      { x: 0.0, y: 0.0, },
      { x: 1.0, y: 0.0, },
    ],
  ]
  for vertices in originals {
    let result = @zones.ConvexZone::new("order", vertices, sigma_multiplier=1.0).intersect_position(
      { x: 1.125, y: 1.125, },
      @types.Covariance2::new(0.015625, 0.0, 0.015625),
    )
    intersection_ref_encloses(result, 2.0)
    assert_eq(result.decision, @zones.Disjoint)
  }
}

///|
test "intersection ordinary metric scaling retains dimensionless exact Q2" {
  for scale in [1.0e-100, 1.0, 1.0e100] {
    let zone = @zones.ConvexZone::new(
      "scale",
      [
        { x: 0.0, y: 0.0, },
        { x: scale, y: 0.0, },
        { x: scale, y: scale, },
        { x: 0.0, y: scale, },
      ],
      sigma_multiplier=1.0,
    )
    let result = zone.intersect_position(
      { x: 1.125 * scale, y: 1.125 * scale, },
      @types.Covariance2::new(
        0.015625 * scale * scale,
        0.0,
        0.015625 * scale * scale,
      ),
    )
    // Scaling creates rounded binary64 inputs; the exact rational oracle lives
    // in Python. This broad bracket is only a focused scale regression.
    assert_true(result.minimum_quadratic_lower < 2.0000000000001)
    assert_true(result.minimum_quadratic_upper > 1.9999999999999)
    assert_eq(result.decision, @zones.Disjoint)
  }
}

///|
test "intersection supplied shape arrays cannot mutate the stored polygon" {
  let vertices : Array[@types.Point2] = [
    { x: 0.0, y: 0.0, },
    { x: 1.0, y: 0.0, },
    { x: 1.0, y: 1.0, },
    { x: 0.0, y: 1.0, },
  ]
  let zone = @zones.ConvexZone::new("detach", vertices, sigma_multiplier=1.0)
  vertices[0] = { x: 99.0, y: 99.0, }
  let exported = zone.vertices_m()
  exported.clear()
  let result = zone.intersect_position(
    { x: 1.125, y: 1.125, },
    @types.Covariance2::new(0.015625, 0.0, 0.015625),
  )
  intersection_ref_encloses(result, 2.0)
  assert_eq(result.decision, @zones.Disjoint)
}
