///|
fn assigned_zone_test_document(
  footprints : String,
  timestamp~ : String = "10",
) -> String {
  "{\"timestamp_us\":\"" + timestamp + "\",\"footprints\":" + footprints + "}"
}

///|
fn assigned_zone_test_line(
  measurement : String,
  assignments : String,
) -> String {
  Json::object({
    "measurement": Json(measurement),
    "assignments": Json(assignments),
  }).stringify()
}

///|
fn assigned_zone_test_disk() -> String {
  "{\"track_id\":7,\"segment_id\":\"1\",\"shape\":{\"kind\":\"disk\",\"radius_m\":0.125}}"
}

///|
test "assigned protocol supports different disk and convex shapes in one frame" {
  let measurement = @json.parse(zone_test_frame(10L, 0.5, 0.5))
  guard measurement is { "tracks": Array(tracks), .. } else {
    fail("tracks missing")
  }
  let other = @json.parse(tracks[0].stringify())
  guard other is Object(fields) else { fail("track missing") }
  fields["track_id"] = Json(8)
  fields["segment_id"] = Json("8")
  tracks.push(other)
  let assignments = assigned_zone_test_document(
    "[" +
    assigned_zone_test_disk() +
    ",{\"track_id\":8,\"segment_id\":\"8\",\"shape\":{\"kind\":\"convex\",\"vertices_offset_m\":[[-0.25,-0.25],[1,-0.25],[1,0.25],[-0.25,0.25]]}}]",
  )
  let replay = @codec.AssignedZoneEvidenceReplay::open(zone_test_source(k=0.0))
  assert_true(
    @json.parse(
      replay.process_line(
        assigned_zone_test_line(measurement.stringify(), assignments),
      ),
    )
    is {
      "kind": String("assigned_zone_evidence_frame"),
      "evidence_scope": String(
        "model_position_halfplane_bands_plus_current_target_footprints"
      ),
      "evidence": [
        {
          "track_id": Number(7, ..),
          "shape_kind": String("disk"),
          "decision": String("inside"),
          "faces": [
            {
              "footprint_lower_m": Number(-0.125, ..),
              "footprint_upper_m": Number(0.125, ..),
              ..
            },
            _,
            _,
            _,
          ],
          ..
        },
        {
          "track_id": Number(8, ..),
          "shape_kind": String("convex"),
          "decision": String("indeterminate"),
          ..
        },
      ],
      "unavailable": [],
      ..
    },
  )
}

///|
test "missing assignment is distinct from original unavailable and is never broadcast" {
  let replay = @codec.AssignedZoneEvidenceReplay::open(zone_test_source())
  let empty = assigned_zone_test_document("[]")
  assert_true(
    @json.parse(
      replay.process_line(
        assigned_zone_test_line(zone_test_frame(10L, 0.5, 0.5), empty),
      ),
    )
    is {
      "evidence": [],
      "unavailable": [
        { "track_id": Number(7, ..), "reason": String("missing_footprint"), .. },
      ],
      ..
    },
  )
  for status in ["initializing", "uncertain"] {
    guard @json.parse(
        replay.process_line(
          assigned_zone_test_line(
            zone_test_frame(10L, 0.5, 0.5, status~),
            empty,
          ),
        ),
      )
      is {
        "evidence": [],
        "unavailable": [{ "reason": String(reason), .. }],
        ..
      } else {
      fail("unavailable missing")
    }
    assert_eq(reason, status)
  }
}

///|
test "assigned clock preserves exact Int64 values and rejects stale bundle time" {
  let replay = @codec.AssignedZoneEvidenceReplay::open(zone_test_source())
  let measurement = zone_test_frame(9007199254740993L, 0.5, 0.5)
  let good = assigned_zone_test_document(
    "[" + assigned_zone_test_disk() + "]",
    timestamp="9007199254740993",
  )
  assert_true(
    @json.parse(replay.process_line(assigned_zone_test_line(measurement, good)))
    is { "timestamp_us": String("9007199254740993"), "evidence": [_], .. },
  )
  for
    timestamp in ["9007199254740992", "09007199254740993", "+9007199254740993"] {
    let bad = assigned_zone_test_document("[]", timestamp~)
    try replay.process_line(assigned_zone_test_line(measurement, bad)) catch {
      _ => ()
    } noraise {
      _ => fail("stale or noncanonical assignment clock accepted")
    }
  }
}

///|
test "assigned frame rejects duplicate stale and absent target bindings" {
  let replay = @codec.AssignedZoneEvidenceReplay::open(zone_test_source())
  let raw = zone_test_frame(10L, 0.5, 0.5)
  let disk = assigned_zone_test_disk()
  for
    rows in [
      "[" + disk + "," + disk + "]",
      "[" +
      disk.replace(old="\"segment_id\":\"1\"", new="\"segment_id\":\"2\"") +
      "]",
      "[" + disk.replace(old="\"track_id\":7", new="\"track_id\":8") + "]",
    ] {
    try
      replay.process_line(
        assigned_zone_test_line(raw, assigned_zone_test_document(rows)),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("duplicate or stale target assignment accepted")
    }
  }
}

///|
test "assigned wrapper shape fields and raw numeric tokens remain strict" {
  let replay = @codec.AssignedZoneEvidenceReplay::open(zone_test_source())
  let raw = zone_test_frame(10L, 0.5, 0.5)
  let disk = assigned_zone_test_disk()
  let valid = assigned_zone_test_document("[" + disk + "]")
  for
    bad in [
      valid.replace(old="{", new="{\"extra\":0,"),
      valid.replace(old="{", new="{\"timestamp_us\":\"10\","),
      assigned_zone_test_document(
        "[" +
        disk.replace(
          old="\"track_id\":7",
          new="\"track_id\":7.0000000000000001",
        ) +
        "]",
      ),
      assigned_zone_test_document(
        "[" +
        disk.replace(old="\"kind\":\"disk\"", new="\"kind\":\"other\"") +
        "]",
      ),
      assigned_zone_test_document(
        "[" +
        disk.replace(
          old="\"radius_m\":0.125",
          new="\"radius_m\":0.125,\"vertices_offset_m\":[]",
        ) +
        "]",
      ),
      "{\"timestamp_us\":10,\"footprints\":[]}",
    ] {
    try replay.process_line(assigned_zone_test_line(raw, bad)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid assigned document accepted")
    }
  }
  let wrapped = assigned_zone_test_line(raw, valid)
  for
    bad in [
      wrapped.replace(old="{", new="{\"extra\":true,"),
      "{\"measurement\":{},\"assignments\":\"{}\"}",
    ] {
    try replay.process_line(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid raw wrapper accepted")
    }
  }
}

///|
test "assigned projection failures remain unavailable and cannot receive a no-segment shape" {
  let measurement = @json.parse(zone_test_frame(10L, 0.5, 0.5))
  guard measurement is { "tracks": Array(tracks), .. } else {
    fail("tracks missing")
  }
  tracks.push(
    Json::object({
      "track_id": Json(8),
      "segment_id": Json::null(),
      "status": Json("rejected_projection"),
      "reason": Json("outside_roi"),
      "position_m": Json::null(),
      "position_covariance": Json::null(),
      "velocity_mps": Json::null(),
      "velocity_covariance": Json::null(),
      "position_std_m": Json::null(),
      "velocity_std_mps": Json::null(),
      "speed_mps": Json::null(),
    }),
  )
  let replay = @codec.AssignedZoneEvidenceReplay::open(zone_test_source())
  assert_true(
    @json.parse(
      replay.process_line(
        assigned_zone_test_line(
          measurement.stringify(),
          assigned_zone_test_document("[]"),
        ),
      ),
    )
    is {
      "evidence": [],
      "unavailable": [
        { "track_id": Number(7, ..), "reason": String("missing_footprint"), .. },
        {
          "track_id": Number(8, ..),
          "segment_id": Null,
          "reason": String("rejected_projection"),
          ..
        },
      ],
      ..
    },
  )
  let bad = assigned_zone_test_document(
    "[" +
    assigned_zone_test_disk().replace(
      old="\"track_id\":7",
      new="\"track_id\":8",
    ) +
    "]",
  )
  try
    replay.process_line(assigned_zone_test_line(measurement.stringify(), bad))
  catch {
    _ => ()
  } noraise {
    _ => fail("projection failure received an assignment")
  }
}

///|
test "assigned independent repeats do not retain a shape for later or reordered calls" {
  let replay = @codec.AssignedZoneEvidenceReplay::open(zone_test_source())
  let raw = zone_test_frame(10L, 0.5, 0.5)
  let bound = assigned_zone_test_line(
    raw,
    assigned_zone_test_document("[" + assigned_zone_test_disk() + "]"),
  )
  let expected = replay.process_line(bound)
  let missing = assigned_zone_test_line(raw, assigned_zone_test_document("[]"))
  assert_true(
    @json.parse(replay.process_line(missing))
    is { "evidence": [], "unavailable": [_], .. },
  )
  ignore(
    replay.process_line(
      assigned_zone_test_line(
        zone_test_frame(1L, 0.5, 0.5),
        assigned_zone_test_document("[]", timestamp="1"),
      ),
    ),
  )
  assert_eq(replay.process_line(bound), expected)
}

///|
test "assigned pure batches preserve CRLF EOF and empty results without invalid prefixes" {
  let request = (frames : String) => {
    Json::object({ "source": Json(zone_test_source()), "frames": Json(frames) }).stringify()
  }
  assert_eq(@codec.assigned_zone_evidence_json(request("")), "{\"frames\":[]}")
  let line = assigned_zone_test_line(
    zone_test_frame(10L, 0.5, 0.5),
    assigned_zone_test_document("[" + assigned_zone_test_disk() + "]"),
  )
  let expected = @codec.assigned_zone_evidence_json(request(line + "\n" + line))
  assert_eq(
    expected,
    @codec.assigned_zone_evidence_json(request(line + "\r\n" + line + "\r\n")),
  )
  assert_true(@json.parse(expected) is { "frames": [_, _], .. })
  try @codec.assigned_zone_evidence_json(request(line + "\n{}")) catch {
    _ => ()
  } noraise {
    _ => fail("invalid pure batch exposed a result")
  }
}
