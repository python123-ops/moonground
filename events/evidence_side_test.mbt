///|
test "checked evidence side matches current diagnostic rows including zero multiplier" {
  let gate = line()
  for multiplier in [0.0, 2.0] {
    let engine = evidence_counter(multiplier~)
    for index, y in [-1.0, -0.2, 0.0, 0.2, 1.0] {
      let covariance = @types.Covariance2::new(100.0, 0.0, 0.01)
      let time = index.to_int64()
      let result = engine.update(
        frame(time, [evidence_track(1, "1", 5.0, y, time, covariance~)]),
      )
      assert_eq(
        gate.evidence_side(
          { x: 5.0, y, },
          covariance,
          sigma_multiplier=multiplier,
        ),
        result.evidence[0].side,
      )
      if multiplier == 0.0 {
        assert_eq(result.evidence[0].side, gate.side({ x: 5.0, y, }))
      }
    }
  }
}

///|
test "checked evidence side validates public points covariance and multiplier" {
  let gate = line()
  for multiplier in [-1.0, 1.0 / 0.0, 0.0 / 0.0] {
    invalid(() => {
      ignore(
        gate.evidence_side(
          { x: 5.0, y: 1.0, },
          @types.Covariance2::isotropic(0.1),
          sigma_multiplier=multiplier,
        ),
      )
    })
  }
  invalid(() => {
    ignore(
      gate.evidence_side(
        { x: 1.0 / 0.0, y: 1.0, },
        @types.Covariance2::isotropic(0.1),
      ),
    )
  })
  for multiplier in [0.0, 2.0] {
    invalid(() => {
      ignore(
        gate.evidence_side(
          { x: 5.0, y: 1.0, },
          { xx: 1.0, xy: 2.0, yy: 1.0, },
          sigma_multiplier=multiplier,
        ),
      )
    })
  }
}

///|
test "checked evidence side preserves unsupported numerical-domain errors" {
  let gate = line()
  for multiplier in [0.0, 2.0] {
    invalid(() => {
      ignore(
        gate.evidence_side(
          { x: 5.0, y: 1.0, },
          @types.Covariance2::new(1.0, -0.9999999999999999, 1.0),
          sigma_multiplier=multiplier,
        ),
      )
    })
  }
  invalid(() => {
    ignore(
      gate.evidence_side(
        { x: 5.0, y: 1.0e300, },
        @types.Covariance2::isotropic(0.1),
      ),
    )
  })
}
