///|
fn footprint_geometry_shape() -> Array[@types.Point2] {
  [
    { x: -0.25, y: -0.25, },
    { x: 1.0, y: -0.25, },
    { x: 1.0, y: 0.25, },
    { x: -0.25, y: 0.25, },
  ]
}

///|
fn footprint_geometry_square(
  k~ : Double = 0.0,
) -> @zones.ConvexZone raise @types.GroundError {
  @zones.ConvexZone::new(
    "workspace",
    [
      { x: 0.0, y: 0.0, },
      { x: 4.0, y: 0.0, },
      { x: 4.0, y: 4.0, },
      { x: 0.0, y: 4.0, },
    ],
    sigma_multiplier=k,
  )
}

///|
fn footprint_geometry_invalid(
  action : () -> Unit raise @types.GroundError,
) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("unsupported footprint accepted")
  }
}

///|
test "convex footprint accepts an interior anchor without recentering supplied offsets" {
  let vertices = footprint_geometry_shape()
  let shape = @zones.ConvexFootprint::new(vertices)
  assert_eq(
    @debug.to_string(shape.vertices_offset_m()),
    @debug.to_string(vertices),
  )
  let band = footprint_geometry_square().evaluate_footprint(
    { x: 1.0, y: 1.0, },
    @types.Covariance2::isotropic(0.1),
    shape,
  )
  assert_eq(
    @debug.to_string(band.vertices_offset_m),
    @debug.to_string(vertices),
  )
  assert_eq(band.decision, @zones.Inside)
}

///|
test "convex footprint anchor may lie on its closed edge or vertex" {
  let edge = @zones.ConvexFootprint::new([
    { x: -1.0, y: 0.0, },
    { x: 1.0, y: 0.0, },
    { x: 1.0, y: 1.0, },
    { x: -1.0, y: 1.0, },
  ])
  let vertex = @zones.ConvexFootprint::new([
    { x: 0.0, y: 0.0, },
    { x: 1.0, y: 0.0, },
    { x: 0.0, y: 1.0, },
  ])
  let zone = footprint_geometry_square()
  assert_eq(
    zone.evaluate_footprint(
      { x: 1.0, y: 1.0, },
      @types.Covariance2::isotropic(1.0),
      edge,
    ).decision,
    @zones.Inside,
  )
  assert_eq(
    zone.evaluate_footprint(
      { x: 1.0, y: 1.0, },
      @types.Covariance2::isotropic(1.0),
      vertex,
    ).decision,
    @zones.Inside,
  )
}

///|
test "asymmetric footprint supports retain separate lower and upper extents" {
  let band = footprint_geometry_square().evaluate_footprint(
    { x: 1.0, y: 1.0, },
    @types.Covariance2::isotropic(0.1),
    @zones.ConvexFootprint::new(footprint_geometry_shape()),
  )
  assert_eq(band.faces[1].footprint_lower_m, -0.25)
  assert_eq(band.faces[1].footprint_upper_m, 1.0)
  assert_eq(band.faces[1].lower_m, -3.25)
  assert_eq(band.faces[1].upper_m, -2.0)
  assert_eq(band.faces[3].footprint_lower_m, -1.0)
  assert_eq(band.faces[3].footprint_upper_m, 0.25)
}

///|
test "zero support copies its corresponding statistical endpoint exactly" {
  let zone = footprint_geometry_square(k=2.0)
  let point = @types.Point2::{ x: 1.0, y: 1.0, }
  let covariance = @types.Covariance2::isotropic(0.125)
  let original = zone.evaluate(point, covariance)
  let shape = @zones.ConvexFootprint::new([
    { x: 0.0, y: 0.0, },
    { x: 0.5, y: 0.0, },
    { x: 0.0, y: 0.5, },
  ])
  let band = zone.evaluate_footprint(point, covariance, shape)
  assert_eq(band.faces[1].footprint_lower_m, 0.0)
  assert_eq(band.faces[1].lower_m, original.faces[1].lower_m)
  assert_true(band.faces[1].upper_m > original.faces[1].upper_m)
  assert_eq(band.faces[3].footprint_upper_m, 0.0)
  assert_eq(band.faces[3].upper_m, original.faces[3].upper_m)
}

///|
test "raw slanted support preserves closed collinearity at a footprint vertex" {
  let vertices : Array[@types.Point2] = [
    { x: 0.0, y: 0.0, },
    { x: 3.0, y: 4.0, },
    { x: 0.0, y: 5.0, },
  ]
  let zone = @zones.ConvexZone::new("slanted", vertices, sigma_multiplier=0.0)
  let band = zone.evaluate_footprint(
    { x: 0.0, y: 0.0, },
    @types.Covariance2::isotropic(1.0),
    @zones.ConvexFootprint::new(vertices),
  )
  assert_eq(band.decision, @zones.Inside)
  for face in band.faces {
    assert_eq(face.upper_m, 0.0)
  }
  assert_eq(band.faces[0].footprint_upper_m, 0.0)
}

///|
test "slanted physical tangency keeps one ULP neighboring signs without epsilon" {
  let zone = @zones.ConvexZone::new(
    "slanted",
    [{ x: 0.0, y: 0.0, }, { x: 6.0, y: 8.0, }, { x: 0.0, y: 10.0, }],
    sigma_multiplier=0.0,
  )
  let shape = @zones.ConvexFootprint::new([
    { x: 0.0, y: 0.0, },
    { x: 3.0, y: 4.0, },
    { x: 0.0, y: 5.0, },
  ])
  let covariance = @types.Covariance2::isotropic(1.0)
  let below = (2.0.reinterpret_as_int64() - 1L).reinterpret_as_double()
  let above = (2.0.reinterpret_as_int64() + 1L).reinterpret_as_double()
  assert_eq(
    zone.evaluate_footprint({ x: 1.5, y: 2.0, }, covariance, shape).decision,
    @zones.Inside,
  )
  let crossed = zone.evaluate_footprint(
    { x: 1.5, y: below, },
    covariance,
    shape,
  )
  assert_eq(crossed.decision, @zones.Indeterminate)
  assert_true(crossed.faces[0].upper_m > 0.0)
  assert_eq(
    zone.evaluate_footprint({ x: 1.5, y: above, }, covariance, shape).decision,
    @zones.Inside,
  )
}

///|
test "footprint winding and cyclic vertex origin preserve supports" {
  let vertices = footprint_geometry_shape()
  let variants = [
    vertices,
    [vertices[3], vertices[2], vertices[1], vertices[0]],
    [vertices[2], vertices[3], vertices[0], vertices[1]],
  ]
  let zone = footprint_geometry_square(k=2.0)
  let covariance = @types.Covariance2::{ xx: 0.04, xy: 0.01, yy: 0.09, }
  let baseline = zone.evaluate_footprint(
    { x: 1.0, y: 1.0, },
    covariance,
    @zones.ConvexFootprint::new(vertices),
  )
  for points in variants {
    let band = zone.evaluate_footprint(
      { x: 1.0, y: 1.0, },
      covariance,
      @zones.ConvexFootprint::new(points),
    )
    for i in 0..<4 {
      assert_eq(
        band.faces[i].footprint_lower_m,
        baseline.faces[i].footprint_lower_m,
      )
      assert_eq(
        band.faces[i].footprint_upper_m,
        baseline.faces[i].footprint_upper_m,
      )
      assert_eq(band.faces[i].lower_m, baseline.faces[i].lower_m)
      assert_eq(band.faces[i].upper_m, baseline.faces[i].upper_m)
    }
  }
}

///|
test "footprint support follows ground frame rotation and metric scales" {
  for scale in [1.0e-100, 1.0, 1.0e100] {
    let points = footprint_geometry_shape().map(p => @types.Point2::{
      x: -p.y * scale,
      y: p.x * scale,
    })
    let shape = @zones.ConvexFootprint::new(points)
    let zone = @zones.ConvexZone::new(
      "scaled",
      [
        { x: -4.0 * scale, y: 0.0, },
        { x: 0.0, y: 0.0, },
        { x: 0.0, y: 4.0 * scale, },
        { x: -4.0 * scale, y: 4.0 * scale, },
      ],
      sigma_multiplier=0.0,
    )
    let band = zone.evaluate_footprint(
      { x: -scale, y: scale, },
      @types.Covariance2::isotropic(0.1 * scale),
      shape,
    )
    assert_eq(band.decision, @zones.Inside)
    assert_true(
      (band.faces[2].footprint_lower_m / scale + 0.25).abs() < 1.0e-14,
    )
    assert_true((band.faces[2].footprint_upper_m / scale - 1.0).abs() < 1.0e-14)
  }
}

///|
test "axis aligned square and disk share exact per face support intervals" {
  let zone = footprint_geometry_square(k=2.0)
  let shape = @zones.ConvexFootprint::new([
    { x: -0.25, y: -0.25, },
    { x: 0.25, y: -0.25, },
    { x: 0.25, y: 0.25, },
    { x: -0.25, y: 0.25, },
  ])
  let point = @types.Point2::{ x: 1.0, y: 1.0, }
  let covariance = @types.Covariance2::isotropic(0.125)
  let polygon = zone.evaluate_footprint(point, covariance, shape)
  let disk = zone.evaluate_disk(
    point,
    covariance,
    @zones.DiskFootprint::new(0.25),
  )
  assert_eq(polygon.decision, disk.decision)
  for i in 0..<4 {
    assert_eq(polygon.faces[i].lower_m, disk.faces[i].lower_m)
    assert_eq(polygon.faces[i].upper_m, disk.faces[i].upper_m)
  }
}

///|
test "footprints reject degeneracy exterior origin concavity repeated and nonfinite vertices" {
  let bad : Array[Array[@types.Point2]] = [
    [],
    [{ x: 0.0, y: 0.0, }],
    [{ x: 0.0, y: 0.0, }, { x: 1.0, y: 0.0, }],
    [{ x: 0.0, y: 0.0, }, { x: 0.0, y: 0.0, }, { x: 0.0, y: 0.0, }],
    [{ x: 1.0, y: 1.0, }, { x: 2.0, y: 1.0, }, { x: 1.0, y: 2.0, }],
    [{ x: 0.0, y: 0.0, }, { x: 1.0, y: 0.0, }, { x: 2.0, y: 0.0, }],
    [
      { x: 0.0, y: 0.0, },
      { x: 1.0, y: 1.0, },
      { x: 0.0, y: 1.0, },
      { x: 1.0, y: 0.0, },
    ],
    [
      { x: 0.0, y: 0.0, },
      { x: 1.0, y: 0.0, },
      { x: 0.25, y: 0.25, },
      { x: 0.0, y: 1.0, },
    ],
    [{ x: 0.0 / 0.0, y: 0.0, }, { x: 1.0, y: 0.0, }, { x: 0.0, y: 1.0, }],
  ]
  for points in bad {
    footprint_geometry_invalid(() => ignore(@zones.ConvexFootprint::new(points)))
  }
}

///|
test "footprint expansion rejects hidden positive contributions and old unsupported center bands" {
  let zone = footprint_geometry_square(k=2.0)
  let tiny = @zones.ConvexFootprint::new(
    footprint_geometry_shape().map(p => @types.Point2::{
      x: p.x * 1.0e-30,
      y: p.y * 1.0e-30,
    }),
  )
  footprint_geometry_invalid(() => {
    ignore(
      zone.evaluate_footprint(
        { x: 1.0, y: 1.0, },
        @types.Covariance2::isotropic(0.1),
        tiny,
      ),
    )
  })
  let normal = @zones.ConvexFootprint::new(footprint_geometry_shape())
  footprint_geometry_invalid(() => {
    ignore(
      zone.evaluate_footprint(
        { x: 1.0e300, y: 1.0, },
        @types.Covariance2::isotropic(1.0),
        normal,
      ),
    )
  })
  footprint_geometry_invalid(() => {
    ignore(
      zone.evaluate_footprint(
        { x: 1.0, y: 1.0, },
        @types.Covariance2::{ xx: 1.0, xy: 2.0, yy: 1.0, },
        normal,
      ),
    )
  })
}

///|
test "footprint source accessor and returned band arrays are detached" {
  let points = footprint_geometry_shape()
  let shape = @zones.ConvexFootprint::new(points)
  points.clear()
  let copy = shape.vertices_offset_m()
  copy.clear()
  assert_eq(shape.vertices_offset_m().length(), 4)
  let zone = footprint_geometry_square()
  let band = zone.evaluate_footprint(
    { x: 1.0, y: 1.0, },
    @types.Covariance2::isotropic(0.1),
    shape,
  )
  band.vertices_offset_m.clear()
  band.faces.clear()
  let repeated = zone.evaluate_footprint(
    { x: 1.0, y: 1.0, },
    @types.Covariance2::isotropic(0.1),
    shape,
  )
  assert_eq(repeated.vertices_offset_m.length(), 4)
  assert_eq(repeated.faces.length(), 4)
}
