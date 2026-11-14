///|
fn assigned_binding_disk(
  id : Int32,
  segment : String,
) -> @zones.FootprintAssignment raise @types.GroundError {
  @zones.FootprintAssignment::new(
    id,
    segment,
    @zones.Disk(@zones.DiskFootprint::new(0.125)),
  )
}

///|
fn assigned_binding_invalid(
  action : () -> Unit raise @types.GroundError,
) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid footprint assignment accepted")
  }
}

///|
test "assignment identities require positive IDs and canonical positive Int64 segments" {
  for id in [0, -1] {
    assigned_binding_invalid(() => ignore(assigned_binding_disk(id, "1")))
  }
  for segment in ["", "0", "-1", "01", "+1", "1.0", "9223372036854775808"] {
    assigned_binding_invalid(() => ignore(assigned_binding_disk(1, segment)))
  }
  let max = assigned_binding_disk(2147483647, "9223372036854775807")
  assert_eq(max.track_id, 2147483647)
  assert_eq(max.segment_id, "9223372036854775807")
}

///|
test "assignment bundles require exact nonnegative clocks and reject repeated IDs" {
  assigned_binding_invalid(() => {
    ignore(@zones.FootprintAssignments::new(-1L, []))
  })
  let entry = assigned_binding_disk(1, "1")
  assigned_binding_invalid(() => {
    ignore(@zones.FootprintAssignments::new(0L, [entry, entry]))
  })
  assigned_binding_invalid(() => {
    ignore(
      @zones.FootprintAssignments::new(0L, [
        entry,
        assigned_binding_disk(1, "2"),
      ]),
    )
  })
  assert_eq(
    @zones.FootprintAssignments::new(9223372036854775807L, []).timestamp_us,
    9223372036854775807L,
  )
}

///|
test "bundle capacity accepts ten thousand explicit identities and rejects the next" {
  let entries = Array::makei(10000, i => {
    assigned_binding_disk(i + 1, (i + 1).to_string())
  })
  ignore(@zones.FootprintAssignments::new(0L, entries))
  entries.push(assigned_binding_disk(10001, "10001"))
  assigned_binding_invalid(() => {
    ignore(@zones.FootprintAssignments::new(0L, entries))
  })
}

///|
test "bundle construction detaches its assignment array" {
  let frame = ready_frame()
  let entries = [assigned_binding_disk(1, frame.tracks[0].segment_id)]
  let bundle = @zones.FootprintAssignments::new(frame.timestamp_us, entries)
  entries.clear()
  assert_eq(projector().evaluate_assigned(frame, bundle).evidence.length(), 1)
}

///|
test "assignment clock binds exact current frame beyond Double integer precision" {
  let original = ready_frame()
  let time = 9007199254740993L
  let frame = {
    ..original,
    timestamp_us: time,
    tracks: [{ ..original.tracks[0], last_accepted_timestamp_us: time, }],
  }
  let correct = @zones.FootprintAssignments::new(time, [
    assigned_binding_disk(1, frame.tracks[0].segment_id),
  ])
  assert_eq(projector().evaluate_assigned(frame, correct).timestamp_us, time)
  let wrong = @zones.FootprintAssignments::new(time - 1L, [
    assigned_binding_disk(1, frame.tracks[0].segment_id),
  ])
  assigned_binding_invalid(() => {
    ignore(projector().evaluate_assigned(frame, wrong))
  })
}

///|
test "same target ID cannot reuse a footprint from an earlier segment" {
  let original = ready_frame()
  let frame = {
    ..original,
    tracks: [{ ..original.tracks[0], segment_id: "9007199254740993", }],
  }
  let stale = @zones.FootprintAssignments::new(frame.timestamp_us, [
    assigned_binding_disk(1, original.tracks[0].segment_id),
  ])
  assigned_binding_invalid(() => {
    ignore(projector().evaluate_assigned(frame, stale))
  })
  let current = @zones.FootprintAssignments::new(frame.timestamp_us, [
    assigned_binding_disk(1, "9007199254740993"),
  ])
  assert_eq(
    projector().evaluate_assigned(frame, current).evidence[0].segment_id,
    "9007199254740993",
  )
}

///|
test "unreported and closed only targets are not assignment candidates" {
  let original = ready_frame()
  let extra = @zones.FootprintAssignments::new(original.timestamp_us, [
    assigned_binding_disk(2, "2"),
  ])
  assigned_binding_invalid(() => {
    ignore(projector().evaluate_assigned(original, extra))
  })
  let closed = { ..original, tracks: [], closed_segment_ids: ["1"], }
  let bundle = @zones.FootprintAssignments::new(original.timestamp_us, [
    assigned_binding_disk(1, "1"),
  ])
  assigned_binding_invalid(() => {
    ignore(projector().evaluate_assigned(closed, bundle))
  })
}

///|
test "Ready without a footprint produces one explicit unavailable row per target" {
  let frame = ready_frame()
  let result = projector().evaluate_assigned(
    frame,
    @zones.FootprintAssignments::new(frame.timestamp_us, []),
  )
  assert_eq(result.evidence.length(), 0)
  assert_eq(result.unavailable.length(), 1)
  assert_eq(result.unavailable[0].reason, @zones.MissingFootprint)
  assert_eq(result.unavailable[0].segment_id, Some(frame.tracks[0].segment_id))
}

///|
test "matching nonReady assignments keep original lifecycle reasons without evaluating support" {
  let original = ready_frame()
  let shape = @zones.ConvexFootprint::new([
    { x: -1.0e100, y: -1.0e100, },
    { x: 1.0e100, y: -1.0e100, },
    { x: 1.0e100, y: 1.0e100, },
    { x: -1.0e100, y: 1.0e100, },
  ])
  for
    status in [
      @motion.Initializing,
      @motion.Uncertain,
      @motion.RejectedInnovation,
      @motion.NumericalFailure,
    ] {
    let frame = { ..original, tracks: [{ ..original.tracks[0], status, }], }
    let bundle = @zones.FootprintAssignments::new(frame.timestamp_us, [
      @zones.FootprintAssignment::new(
        1,
        frame.tracks[0].segment_id,
        @zones.Convex(shape),
      ),
    ])
    let result = projector().evaluate_assigned(frame, bundle)
    assert_eq(result.evidence.length(), 0)
    assert_true(result.unavailable[0].reason is @zones.Position(_))
    assert_eq(
      @debug.to_string(result.unavailable[0].reason),
      @debug.to_string(
        projector().evaluate_assigned(
          frame,
          @zones.FootprintAssignments::new(frame.timestamp_us, []),
        ).unavailable[0].reason,
      ),
    )
  }
}

///|
test "reported rejected and closed segment binding remains legal" {
  let original = ready_frame()
  let frame = {
    ..original,
    tracks: [{ ..original.tracks[0], status: @motion.RejectedInnovation, }],
    closed_segment_ids: [original.tracks[0].segment_id],
  }
  let result = projector().evaluate_assigned(
    frame,
    @zones.FootprintAssignments::new(frame.timestamp_us, [
      assigned_binding_disk(1, frame.tracks[0].segment_id),
    ]),
  )
  assert_eq(
    result.unavailable[0].reason,
    @zones.Position(@zones.RejectedInnovation),
  )
  assigned_binding_invalid(() => {
    ignore(
      projector().evaluate_assigned(
        { ..frame, tracks: original.tracks, },
        @zones.FootprintAssignments::new(frame.timestamp_us, []),
      ),
    )
  })
}

///|
test "missing footprint cannot bypass old Ready position numerical validation" {
  let original = ready_frame()
  let frame = {
    ..original,
    tracks: [
      {
        ..original.tracks[0],
        position: Some({ x: 1.0e300, y: 0.5, }),
        position_covariance: Some(@types.Covariance2::isotropic(1.0)),
      },
    ],
  }
  let zone = @zones.ConvexZone::new("domain", [
    { x: 0.0, y: 0.0, },
    { x: 1.0, y: 0.0, },
    { x: 1.0, y: 1.0, },
    { x: 0.0, y: 1.0, },
  ])
  let p = @zones.ZoneProjector::new(frame.session_id, [zone])
  assigned_binding_invalid(() => {
    ignore(
      p.evaluate_assigned(
        frame,
        @zones.FootprintAssignments::new(frame.timestamp_us, []),
      ),
    )
  })
}

///|
test "independent assignment bundles can be repeated reordered and retried after failure" {
  let frame = ready_frame()
  let p = projector()
  let correct = @zones.FootprintAssignments::new(frame.timestamp_us, [
    assigned_binding_disk(1, frame.tracks[0].segment_id),
  ])
  let first = @debug.to_string(p.evaluate_assigned(frame, correct))
  let bad = @zones.FootprintAssignments::new(frame.timestamp_us + 1L, [])
  assigned_binding_invalid(() => ignore(p.evaluate_assigned(frame, bad)))
  assert_eq(@debug.to_string(p.evaluate_assigned(frame, correct)), first)
  let early = {
    ..frame,
    timestamp_us: 0L,
    tracks: [{ ..frame.tracks[0], last_accepted_timestamp_us: 0L, }],
  }
  ignore(
    p.evaluate_assigned(
      early,
      @zones.FootprintAssignments::new(0L, [
        assigned_binding_disk(1, frame.tracks[0].segment_id),
      ]),
    ),
  )
  assert_eq(@debug.to_string(p.evaluate_assigned(frame, correct)), first)
}
