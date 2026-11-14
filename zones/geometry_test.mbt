///|
fn geometry_invalid(action : () -> Unit raise @types.GroundError) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("unsupported zone geometry or evidence was accepted")
  }
}

///|
fn geometry_close(actual : Double, expected : Double) -> Unit raise {
  if expected == 0.0 {
    assert_true(actual.abs() < 2.0e-14)
  } else {
    assert_true((actual / expected - 1.0).abs() < 2.0e-14)
  }
}

///|
fn geometry_vertices() -> Array[@types.Point2] {
  [
    { x: 0.0, y: 0.0, },
    { x: 1.0, y: 0.0, },
    { x: 1.0, y: 1.0, },
    { x: 0.0, y: 1.0, },
  ]
}

///|
fn geometry_square(
  multiplier~ : Double = 2.0,
) -> @zones.ConvexZone raise @types.GroundError {
  @zones.ConvexZone::new(
    "square",
    geometry_vertices(),
    sigma_multiplier=multiplier,
  )
}

///|
test "zero multiplier includes the original closed axis polygon edges and corners" {
  let zone = geometry_square(multiplier=0.0)
  let covariance = @types.Covariance2::isotropic(0.1)
  let points = geometry_vertices()
  points.push({ x: 0.5, y: 0.0, })
  points.push({ x: 1.0, y: 0.5, })
  points.push({ x: 0.5, y: 1.0, })
  points.push({ x: 0.0, y: 0.5, })
  for point in points {
    let band = zone.evaluate(point, covariance)
    assert_eq(band.decision, @zones.Inside)
    assert_true(band.separating_edge_index is None)
    for face in band.faces {
      assert_eq(face.lower_m, face.distance_m)
      assert_eq(face.upper_m, face.distance_m)
      assert_true(face.normal_std_m > 0.0)
    }
  }
}

///|
test "zero multiplier includes every original slanted vertex and dyadic midpoint" {
  let vertices : Array[@types.Point2] = [
    { x: 0.0, y: 0.0, },
    { x: 3.0, y: 4.0, },
    { x: 0.0, y: 5.0, },
  ]
  let points = vertices.copy()
  points.push({ x: 1.5, y: 2.0, })
  points.push({ x: 1.5, y: 4.5, })
  points.push({ x: 0.0, y: 2.5, })
  let zone = @zones.ConvexZone::new("slanted", vertices, sigma_multiplier=0.0)
  for point in points {
    assert_eq(
      zone.evaluate(point, @types.Covariance2::isotropic(1.0)).decision,
      @zones.Inside,
    )
  }
  assert_eq(
    zone.evaluate(vertices[1], @types.Covariance2::isotropic(1.0)).faces[0].distance_m,
    0.0,
  )
}

///|
test "slanted raw supporting line keeps the sign one ULP on either side without epsilon" {
  let zone = @zones.ConvexZone::new(
    "slanted",
    [{ x: 0.0, y: 0.0, }, { x: 3.0, y: 4.0, }, { x: 0.0, y: 5.0, }],
    sigma_multiplier=0.0,
  )
  let below = (2.0.reinterpret_as_int64() - 1L).reinterpret_as_double()
  let above = (2.0.reinterpret_as_int64() + 1L).reinterpret_as_double()
  let covariance = @types.Covariance2::isotropic(0.1)
  let outside = zone.evaluate({ x: 1.5, y: below, }, covariance)
  assert_eq(outside.decision, @zones.Outside)
  assert_eq(outside.separating_edge_index, Some(0))
  assert_true(outside.faces[0].distance_m > 0.0)
  let inside = zone.evaluate({ x: 1.5, y: above, }, covariance)
  assert_eq(inside.decision, @zones.Inside)
  assert_true(inside.faces[0].distance_m < 0.0)
}

///|
test "closed upper tangency is inside while lower tangency cannot prove separation" {
  let covariance = @types.Covariance2::isotropic(0.25)
  let enclosed = geometry_square().evaluate({ x: 0.5, y: 0.5, }, covariance)
  assert_eq(enclosed.decision, @zones.Inside)
  for face in enclosed.faces {
    assert_eq(face.upper_m, 0.0)
  }
  let touching = geometry_square(multiplier=1.0).evaluate(
    { x: 1.25, y: 0.5, },
    covariance,
  )
  assert_eq(touching.faces[1].lower_m, 0.0)
  assert_eq(touching.decision, @zones.Indeterminate)
  assert_true(touching.separating_edge_index is None)
}

///|
test "a disjoint circle at a corner remains indeterminate without a separating face" {
  let band = geometry_square(multiplier=1.0).evaluate(
    { x: 1.2, y: 1.2, },
    @types.Covariance2::isotropic(0.25),
  )
  assert_true((0.2 * 0.2 + 0.2 * 0.2).sqrt() > 0.25)
  assert_eq(band.decision, @zones.Indeterminate)
  assert_true(band.separating_edge_index is None)
  for face in band.faces {
    assert_true(face.lower_m <= 0.0)
  }
}

///|
test "first separating face follows original edge order and every face remains available" {
  let band = geometry_square(multiplier=1.0).evaluate(
    { x: 2.0, y: 2.0, },
    @types.Covariance2::isotropic(0.25),
  )
  assert_eq(band.decision, @zones.Outside)
  assert_eq(band.separating_edge_index, Some(1))
  assert_eq(band.faces.length(), 4)
  for index in 0..<4 {
    assert_eq(band.faces[index].edge_index, index)
  }
  assert_eq(band.faces[0].outward_normal.y, -1.0)
  assert_eq(band.faces[1].outward_normal.x, 1.0)
  assert_eq(band.faces[2].outward_normal.y, 1.0)
  assert_eq(band.faces[3].outward_normal.x, -1.0)
  assert_true(band.faces[1].lower_m > 0.0)
  assert_true(band.faces[2].lower_m > 0.0)
}

///|
test "construction accessors and returned diagnostics do not alias zone geometry" {
  let vertices = geometry_vertices()
  let zone = @zones.ConvexZone::new("detached", vertices)
  vertices[0] = { x: -10.0, y: -10.0, }
  let exported = zone.vertices_m()
  exported.clear()
  assert_eq(zone.vertices_m().length(), 4)
  assert_eq(zone.vertices_m()[0].x, 0.0)
  let covariance = @types.Covariance2::isotropic(0.1)
  let first = zone.evaluate({ x: 0.5, y: 0.5, }, covariance)
  first.faces.clear()
  assert_eq(zone.evaluate({ x: 0.5, y: 0.5, }, covariance).faces.length(), 4)
}

///|
test "clockwise and cyclic vertex orders preserve the original geometric relation" {
  let vertices = geometry_vertices()
  let zones = [
    @zones.ConvexZone::new("ccw", vertices),
    @zones.ConvexZone::new("cw", [
      vertices[3],
      vertices[2],
      vertices[1],
      vertices[0],
    ]),
    @zones.ConvexZone::new("cyclic", [
      vertices[2],
      vertices[3],
      vertices[0],
      vertices[1],
    ]),
  ]
  for
    point in [
      @types.Point2::{ x: 0.5, y: 0.5, },
      { x: 2.0, y: 0.5, },
      { x: 1.0, y: 1.0, },
    ] {
    let expected = zones[0].evaluate(point, @types.Covariance2::isotropic(0.1)).decision
    for zone in zones {
      assert_eq(
        zone.evaluate(point, @types.Covariance2::isotropic(0.1)).decision,
        expected,
      )
    }
  }
}

///|
test "rotation reflection translation and metric scaling preserve ordinary inside evidence" {
  for (scale, reflected) in [(1.0, false), (3.5, false), (1.0, true)] {
    let transform = (point : @types.Point2) => {
      let x = if reflected { -point.x } else { point.x }
      @types.Point2::{
        x: 10.0 + scale * (0.6 * x - 0.8 * point.y),
        y: -20.0 + scale * (0.8 * x + 0.6 * point.y),
      }
    }
    let zone = @zones.ConvexZone::new(
      "transformed",
      geometry_vertices().map(transform),
    )
    let band = zone.evaluate(
      transform({ x: 0.5, y: 0.5, }),
      @types.Covariance2::isotropic(0.1 * scale),
    )
    assert_eq(band.decision, @zones.Inside)
    for face in band.faces {
      geometry_close(face.distance_m / scale, -0.5)
      geometry_close(face.normal_std_m / scale, 0.1)
    }
  }
}

///|
test "anisotropic and correlated covariance use each face normal rather than a global deviation" {
  let zone = @zones.ConvexZone::new("wide", [
    { x: -100.0, y: -1.0, },
    { x: 100.0, y: -1.0, },
    { x: 100.0, y: 1.0, },
    { x: -100.0, y: 1.0, },
  ])
  let anisotropic = zone.evaluate(
    { x: 0.0, y: 0.0, },
    @types.Covariance2::new(100.0, 0.0, 0.0001),
  )
  assert_eq(anisotropic.decision, @zones.Inside)
  geometry_close(anisotropic.faces[0].normal_std_m, 0.01)
  geometry_close(anisotropic.faces[1].normal_std_m, 10.0)
  let diamond = @zones.ConvexZone::new("diamond", [
    { x: 0.0, y: -10.0, },
    { x: 10.0, y: 0.0, },
    { x: 0.0, y: 10.0, },
    { x: -10.0, y: 0.0, },
  ])
  let correlated = diamond.evaluate(
    { x: 0.0, y: 0.0, },
    @types.Covariance2::new(1.0, 0.9, 1.0),
  )
  geometry_close(correlated.faces[0].normal_std_m, 0.1.sqrt())
  geometry_close(correlated.faces[1].normal_std_m, 1.9.sqrt())
}

///|
test "finite tiny and huge metric polygons retain their scaled distances and covariance evidence" {
  for scale in [1.0e-150, 1.0, 1.0e150] {
    let zone = @zones.ConvexZone::new(
      "scaled",
      geometry_vertices().map(point => @types.Point2::{
        x: point.x * scale,
        y: point.y * scale,
      }),
    )
    let band = zone.evaluate(
      { x: 0.5 * scale, y: 0.5 * scale, },
      @types.Covariance2::isotropic(0.125 * scale),
    )
    assert_eq(band.decision, @zones.Inside)
    for face in band.faces {
      geometry_close(face.distance_m / scale, -0.5)
      geometry_close(face.normal_std_m / scale, 0.125)
    }
  }
}

///|
test "concavity duplicate collinear crossed and same turn star polygons are rejected" {
  for
    vertices in [
      [@types.Point2::{ x: 0.0, y: 0.0, }, { x: 1.0, y: 0.0, }],
      [
        { x: 0.0, y: 0.0, },
        { x: 1.0, y: 0.0, },
        { x: 1.0, y: 0.0, },
        { x: 0.0, y: 1.0, },
      ],
      [
        { x: 0.0, y: 0.0, },
        { x: 1.0, y: 0.0, },
        { x: 2.0, y: 0.0, },
        { x: 0.0, y: 1.0, },
      ],
      [
        { x: 0.0, y: 0.0, },
        { x: 2.0, y: 0.0, },
        { x: 0.5, y: 0.5, },
        { x: 0.0, y: 2.0, },
      ],
      [
        { x: 0.0, y: 0.0, },
        { x: 1.0, y: 1.0, },
        { x: 0.0, y: 1.0, },
        { x: 1.0, y: 0.0, },
      ],
      [
        { x: 0.0, y: 3.0, },
        { x: 2.0, y: -3.0, },
        { x: -3.0, y: 1.0, },
        { x: 3.0, y: 1.0, },
        { x: -2.0, y: -3.0, },
      ],
    ] {
    geometry_invalid(() => ignore(@zones.ConvexZone::new("invalid", vertices)))
  }
}

///|
test "invalid identity multiplier position and covariance are rejected even when k is zero" {
  for
    (identity, multiplier) in [
      ("", 2.0),
      ("zone", -1.0),
      ("zone", 0.0 / 0.0),
      ("zone", 1.0 / 0.0),
    ] {
    geometry_invalid(() => {
      ignore(
        @zones.ConvexZone::new(
          identity,
          geometry_vertices(),
          sigma_multiplier=multiplier,
        ),
      )
    })
  }
  let zone = geometry_square(multiplier=0.0)
  geometry_invalid(() => {
    ignore(zone.evaluate({ x: 0.5, y: 0.5, }, { xx: 1.0, xy: 2.0, yy: 1.0, }))
  })
  geometry_invalid(() => {
    ignore(
      zone.evaluate(
        { x: 0.0 / 0.0, y: 0.5, },
        @types.Covariance2::isotropic(1.0),
      ),
    )
  })
}

///|
test "overflow underflow collapsed intervals and unsupported covariance precision never become indeterminate" {
  geometry_invalid(() => {
    ignore(
      geometry_square().evaluate(
        { x: 1.0e300, y: 0.5, },
        @types.Covariance2::isotropic(1.0),
      ),
    )
  })
  geometry_invalid(() => {
    ignore(
      geometry_square(multiplier=1.0e308).evaluate(
        { x: 0.5, y: 0.5, },
        @types.Covariance2::new(1.0e308, 0.0, 1.0e308),
      ),
    )
  })
  geometry_invalid(() => {
    ignore(
      geometry_square(multiplier=5.0e-324).evaluate(
        { x: 0.5, y: 0.5, },
        @types.Covariance2::new(5.0e-324, 0.0, 5.0e-324),
      ),
    )
  })
  let diamond = @zones.ConvexZone::new("diamond", [
    { x: 0.0, y: -2.0, },
    { x: 2.0, y: 0.0, },
    { x: 0.0, y: 2.0, },
    { x: -2.0, y: 0.0, },
  ])
  let almost_one = (1.0.reinterpret_as_int64() - 1L).reinterpret_as_double()
  geometry_invalid(() => {
    ignore(
      diamond.evaluate(
        { x: 0.0, y: 0.0, },
        @types.Covariance2::new(1.0, almost_one, 1.0),
      ),
    )
  })
  geometry_invalid(() => {
    ignore(
      @zones.ConvexZone::new("overflow", [
        { x: -1.0e308, y: 0.0, },
        { x: 1.0e308, y: 0.0, },
        { x: 0.0, y: 1.0e308, },
      ]),
    )
  })
  geometry_invalid(() => {
    ignore(
      @zones.ConvexZone::new("lost-normal", [
        { x: 0.0, y: 0.0, },
        { x: 1.0e300, y: 1.0e-300, },
        { x: 1.0e300, y: 1.0e300, },
        { x: 0.0, y: 1.0e300, },
      ]),
    )
  })
}
