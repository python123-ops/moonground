///|
fn disk_zone_test_source(radius~ : Double = 0.25, k~ : Double = 1.0) -> String {
  Json::object({
    "position": Json(zone_test_source(k~)),
    "disk": Json(Json::object({ "radius_m": Json(radius) }).stringify()),
  }).stringify()
}

///|
test "disk evidence preserves statistical bounds when physical extent crosses a boundary" {
  let raw = zone_test_frame(9007199254740993L, 0.875, 0.5)
  let replay = @codec.DiskZoneEvidenceReplay::open(disk_zone_test_source(k=0.0))
  assert_true(
    @json.parse(replay.process_line(raw))
    is {
      "schema_version": String("0.1.0"),
      "kind": String("disk_zone_evidence_frame"),
      "evidence_scope": String(
        "model_position_halfplane_bands_plus_explicit_disk"
      ),
      "timestamp_us": String("9007199254740993"),
      "evidence": [
        {
          "radius_m": Number(0.25, ..),
          "decision": String("indeterminate"),
          "separating_edge_index": Null,
          "faces": [
            _,
            {
              "distance_m": Number(-0.125, ..),
              "normal_std_m": Number(0.25, ..),
              "position_lower_m": Number(-0.125, ..),
              "position_upper_m": Number(-0.125, ..),
              "lower_m": Number(-0.375, ..),
              "upper_m": Number(0.125, ..),
              ..
            },
            _,
            _,
          ],
          ..
        },
      ],
      "unavailable": [],
      ..
    },
  )
  assert_true(
    @json.parse(
      @codec.ZoneEvidenceReplay::open(zone_test_source(k=0.0)).process_line(raw),
    )
    is { "evidence": [{ "decision": String("inside"), .. }], .. },
  )
}

///|
test "disk support retains closed inner tangency and strict outer separation" {
  let replay = @codec.DiskZoneEvidenceReplay::open(disk_zone_test_source())
  for
    (x, expected) in [
      (0.5, "inside"),
      (1.5, "indeterminate"),
      (1.75, "outside"),
    ] {
    guard @json.parse(replay.process_line(zone_test_frame(10L, x, 0.5)))
      is { "evidence": [{ "decision": String(actual), .. }], .. } else {
      fail("disk decision missing")
    }
    assert_eq(actual, expected)
  }
  assert_true(
    @json.parse(replay.process_line(zone_test_frame(10L, 1.75, 0.5)))
    is { "evidence": [{ "separating_edge_index": Number(1, ..), .. }], .. },
  )
}

///|
test "zero disk radius preserves original sloped closed boundaries and point evidence" {
  let position = @json.parse(zone_test_source(k=0.0))
  guard position is { "zones": [Object(zone)], .. } else {
    fail("zone missing")
  }
  zone["vertices_m"] = Json([[0.0, 0.0], [3.0, 4.0], [0.0, 5.0]])
  let replay = @codec.DiskZoneEvidenceReplay::open(
    Json::object({
      "position": Json(position.stringify()),
      "disk": Json("{\"radius_m\":0}"),
    }).stringify(),
  )
  assert_true(
    @json.parse(replay.process_line(zone_test_frame(10L, 3.0, 4.0)))
    is {
      "evidence": [
        {
          "radius_m": Number(0, ..),
          "decision": String("inside"),
          "faces": [
            {
              "position_lower_m": Number(0, ..),
              "position_upper_m": Number(0, ..),
              "lower_m": Number(0, ..),
              "upper_m": Number(0, ..),
              ..
            },
            _,
            _,
          ],
          ..
        },
      ],
      ..
    },
  )
}

///|
test "disk admission preserves unavailable statuses and fully validated projection failures" {
  let replay = @codec.DiskZoneEvidenceReplay::open(disk_zone_test_source())
  for status in ["initializing", "uncertain"] {
    guard @json.parse(
        replay.process_line(zone_test_frame(10L, 0.5, 0.5, status~)),
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
  let frame = @json.parse(zone_test_frame(10L, 0.5, 0.5))
  guard frame is { "tracks": Array(tracks), .. } else { fail("tracks missing") }
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
  assert_true(
    @json.parse(replay.process_line(frame.stringify()))
    is {
      "evidence": [_],
      "unavailable": [
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
}

///|
test "disk source preserves raw strict options and does not broaden the original point source" {
  let wrap = (disk : String) => {
    Json::object({ "position": Json(zone_test_source()), "disk": Json(disk) }).stringify()
  }
  for
    bad in [
      wrap("{\"radius_m\":-1}"),
      wrap("{\"radius_m\":1e999}"),
      wrap("{\"radius_m\":0,\"radius_m\":1}"),
      wrap("{\"radius_m\":1,\"extra\":0}"),
      wrap("{}"),
      "{\"resume\":{}}",
      disk_zone_test_source().replace(old="{", new="{\"disk\":\"{}\","),
      Json::object({
        "position": Json(zone_test_source()),
        "disk": Json::object({ "radius_m": Json(1) }),
      }).stringify(),
    ] {
    try @codec.DiskZoneEvidenceReplay::open(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid disk source accepted")
    }
  }
  try
    @codec.ZoneEvidenceReplay::open(
      zone_test_source().replace(old="{", new="{\"radius_m\":0.25,"),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("old point configuration was broadened")
  }
}

///|
test "disk frame rejects stale Ready values and fractional raw identity without retaining state" {
  let replay = @codec.DiskZoneEvidenceReplay::open(disk_zone_test_source())
  let raw = zone_test_frame(10L, 0.5, 0.5)
  let stale = @json.parse(raw)
  guard stale is { "tracks": [Object(track)], .. } else {
    fail("track missing")
  }
  track["last_accepted_timestamp_us"] = Json("9")
  for
    bad in [
      stale.stringify(),
      raw.replace(old="\"track_id\":7", new="\"track_id\":7.0000000000000001"),
    ] {
    try replay.process_line(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid frame accepted")
    }
  }
  let expected = replay.process_line(raw)
  ignore(replay.process_line(zone_test_frame(1L, 1.75, 0.5)))
  assert_eq(expected, replay.process_line(raw))
}

///|
test "disk positive contributions and endpoints cannot be silently swallowed" {
  let raw = zone_test_frame(10L, 0.5, 0.5)
  for radius in [1.0e308, 1.0e-300] {
    let replay = @codec.DiskZoneEvidenceReplay::open(
      disk_zone_test_source(radius~),
    )
    try replay.process_line(raw) catch {
      _ => ()
    } noraise {
      _ => fail("lost disk or position contribution accepted")
    }
  }
  let normal = @codec.DiskZoneEvidenceReplay::open(disk_zone_test_source())
  assert_true(@json.parse(normal.process_line(raw)) is { "evidence": [_], .. })
  try
    @codec.disk_zone_evidence_json(
      Json::object({
        "source": Json(disk_zone_test_source()),
        "measurements": Json(raw + "\n{}"),
      }).stringify(),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("invalid batch exposed a prefix")
  }
}

///|
test "disk pure batches preserve CRLF EOF empty input and repeated independent frames" {
  let request = (text : String) => {
    Json::object({
      "source": Json(disk_zone_test_source()),
      "measurements": Json(text),
    }).stringify()
  }
  assert_eq(@codec.disk_zone_evidence_json(request("")), "{\"frames\":[]}")
  let raw = zone_test_frame(10L, 0.5, 0.5)
  let expected = @codec.disk_zone_evidence_json(request(raw + "\n" + raw))
  assert_eq(
    expected,
    @codec.disk_zone_evidence_json(request(raw + "\r\n" + raw + "\r\n")),
  )
  assert_true(@json.parse(expected) is { "frames": [_, _], .. })
}
