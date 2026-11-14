///|
fn footprint_zone_test_options() -> String {
  "{\"vertices_offset_m\":[[-0.25,-0.25],[1,-0.25],[1,0.25],[-0.25,0.25]]}"
}

///|
fn footprint_zone_test_source(k~ : Double = 1.0) -> String {
  Json::object({
    "position": Json(zone_test_source(k~)),
    "footprint": Json(footprint_zone_test_options()),
  }).stringify()
}

///|
test "convex footprint protocol preserves asymmetric physical and statistical bands" {
  let replay = @codec.FootprintZoneEvidenceReplay::open(
    footprint_zone_test_source(k=0.0),
  )
  assert_true(
    @json.parse(
      replay.process_line(zone_test_frame(9007199254740993L, 0.5, 0.5)),
    )
    is {
      "schema_version": String("0.1.0"),
      "kind": String("footprint_zone_evidence_frame"),
      "evidence_scope": String(
        "model_position_halfplane_bands_plus_explicit_convex_footprint"
      ),
      "timestamp_us": String("9007199254740993"),
      "evidence": [
        {
          "vertices_offset_m": [[_, _], [_, _], [_, _], [_, _]],
          "decision": String("indeterminate"),
          "faces": [
            _,
            {
              "distance_m": Number(-0.5, ..),
              "position_lower_m": Number(-0.5, ..),
              "position_upper_m": Number(-0.5, ..),
              "footprint_lower_m": Number(-0.25, ..),
              "footprint_upper_m": Number(1.0, ..),
              "lower_m": Number(-0.75, ..),
              "upper_m": Number(0.5, ..),
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
}

///|
test "convex footprint accepts a boundary anchor and preserves its zero support side" {
  let replay = @codec.FootprintZoneEvidenceReplay::open(
    Json::object({
      "position": Json(zone_test_source(k=0.0)),
      "footprint": Json(
        "{\"vertices_offset_m\":[[0,0],[0.25,0],[0.25,0.25],[0,0.25]]}",
      ),
    }).stringify(),
  )
  assert_true(
    @json.parse(replay.process_line(zone_test_frame(10L, 0.5, 0.0)))
    is {
      "evidence": [
        {
          "decision": String("inside"),
          "faces": [
            {
              "position_upper_m": Number(0, ..),
              "footprint_upper_m": Number(0, ..),
              "upper_m": Number(0, ..),
              ..
            },
            _,
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
test "convex footprint raw sloped support retains exact closed contact" {
  let position = @json.parse(zone_test_source(k=0.0))
  guard position is { "zones": [Object(zone)], .. } else {
    fail("zone missing")
  }
  zone["vertices_m"] = Json([[0.0, 0.0], [3.0, 4.0], [0.0, 5.0]])
  let replay = @codec.FootprintZoneEvidenceReplay::open(
    Json::object({
      "position": Json(position.stringify()),
      "footprint": Json("{\"vertices_offset_m\":[[0,0],[3,4],[0,5]]}"),
    }).stringify(),
  )
  assert_true(
    @json.parse(replay.process_line(zone_test_frame(10L, 0.0, 0.0)))
    is {
      "evidence": [
        {
          "decision": String("inside"),
          "faces": [
            { "footprint_upper_m": Number(0, ..), "upper_m": Number(0, ..), .. },
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
test "convex footprint raw configuration is strict and leaves older sources unchanged" {
  let wrap = (options : String) => {
    Json::object({
      "position": Json(zone_test_source()),
      "footprint": Json(options),
    }).stringify()
  }
  for
    bad in [
      wrap("{}"),
      wrap("{\"vertices_offset_m\":[]}"),
      wrap("{\"vertices_offset_m\":[[0,0],[1,0],[1,1]],\"extra\":0}"),
      wrap(
        "{\"vertices_offset_m\":[[0,0],[1,0],[1,1]],\"vertices_offset_m\":[]}",
      ),
      wrap("{\"vertices_offset_m\":[[1,1],[2,1],[2,2],[1,2]]}"),
      wrap("{\"vertices_offset_m\":[[0,0],[1,0],[2,0]]}"),
      wrap("{\"vertices_offset_m\":[[0,0],[1,0],[1,1e999]]}"),
      wrap("{\"vertices_offset_m\":[[0,0],[1,0],[1,\"1\"]]}"),
      "{\"resume\":{}}",
      footprint_zone_test_source().replace(
        old="{",
        new="{\"footprint\":\"{}\",",
      ),
      Json::object({
        "position": Json(zone_test_source()),
        "footprint": Json::object({}),
      }).stringify(),
    ] {
    try @codec.FootprintZoneEvidenceReplay::open(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid convex footprint source accepted")
    }
  }
  try
    @codec.ZoneEvidenceReplay::open(
      zone_test_source().replace(old="{", new="{\"vertices_offset_m\":[],"),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("old position source was broadened")
  }
  try @codec.DiskZoneEvidenceReplay::open(footprint_zone_test_source()) catch {
    _ => ()
  } noraise {
    _ => fail("disk accepted convex wrapper")
  }
}

///|
test "convex footprint admission retains unavailable and rejected projection rows" {
  let replay = @codec.FootprintZoneEvidenceReplay::open(
    footprint_zone_test_source(),
  )
  for status in ["initializing", "uncertain"] {
    guard @json.parse(
        replay.process_line(zone_test_frame(10L, 0.5, 0.5, status~)),
      )
      is {
        "evidence": [],
        "unavailable": [{ "reason": String(reason), .. }],
        ..
      } else {
      fail("missing unavailable status")
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
test "convex footprint rejects stale and raw fractional identities without retaining state" {
  let replay = @codec.FootprintZoneEvidenceReplay::open(
    footprint_zone_test_source(),
  )
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
  assert_eq(replay.process_line(raw), expected)
}

///|
test "convex footprint rejects swallowed positive terms and pure batch prefixes" {
  let raw = zone_test_frame(10L, 0.5, 0.5)
  for scale in [1.0e-300, 1.0e150] {
    let options = Json::object({
      "vertices_offset_m": Json([
        Json([Json(-scale), Json(-scale)]),
        Json([Json(scale), Json(-scale)]),
        Json([Json(scale), Json(scale)]),
        Json([Json(-scale), Json(scale)]),
      ]),
    }).stringify()
    let source = Json::object({
      "position": Json(zone_test_source()),
      "footprint": Json(options),
    }).stringify()
    let replay = @codec.FootprintZoneEvidenceReplay::open(source)
    try replay.process_line(raw) catch {
      _ => ()
    } noraise {
      _ => fail("lost positive contribution accepted")
    }
  }
  try
    @codec.footprint_zone_evidence_json(
      Json::object({
        "source": Json(footprint_zone_test_source()),
        "measurements": Json(raw + "\n{}"),
      }).stringify(),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("batch exposed invalid prefix")
  }
}

///|
test "convex footprint pure batch accepts CRLF EOF repeated and empty independent frames" {
  let request = (text : String) => {
    Json::object({
      "source": Json(footprint_zone_test_source()),
      "measurements": Json(text),
    }).stringify()
  }
  assert_eq(@codec.footprint_zone_evidence_json(request("")), "{\"frames\":[]}")
  let raw = zone_test_frame(10L, 0.5, 0.5)
  let expected = @codec.footprint_zone_evidence_json(request(raw + "\n" + raw))
  assert_eq(
    expected,
    @codec.footprint_zone_evidence_json(request(raw + "\r\n" + raw + "\r\n")),
  )
  assert_true(@json.parse(expected) is { "frames": [_, _], .. })
}
