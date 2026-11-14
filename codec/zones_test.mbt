///|
fn zone_test_source(k~ : Double = 1.0) -> String {
  Json::object({
    "session_id": Json("evidence-test"),
    "zones": Json([
      Json::object({
        "zone_id": Json("aisle"),
        "vertices_m": Json([[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]),
        "sigma_multiplier": Json(k),
      }),
    ]),
    "max_tracks": Json(2),
  }).stringify()
}

///|
fn zone_test_frame(
  time : Int64,
  x : Double,
  y : Double,
  status~ : String = "ready",
) -> String raise {
  let value = @json.parse(velocity_test_frame(time, status~))
  guard value is { "tracks": [Object(track)], .. } else {
    fail("track missing")
  }
  track["position_m"] = Json([x, y])
  track["position_covariance"] = Json([0.0625, 0.0, 0.0625])
  track["position_std_m"] = Json(0.25)
  if status == "initializing" {
    track["accepted_count"] = Json(1)
    track["velocity_mps"] = Json::null()
    track["velocity_covariance"] = Json::null()
    track["velocity_std_mps"] = Json::null()
  }
  value.stringify()
}

///|
test "zone evidence preserves closed containment and full per-face support bands" {
  let replay = @codec.ZoneEvidenceReplay::open(zone_test_source(k=2.0))
  let value = @json.parse(
    replay.process_line(zone_test_frame(9007199254740993L, 0.5, 0.5)),
  )
  assert_true(
    value
    is {
      "schema_version": String("0.1.0"),
      "kind": String("zone_evidence_frame"),
      "evidence_scope": String("model_position_halfplane_bands"),
      "timestamp_us": String("9007199254740993"),
      "evidence": [
        {
          "decision": String("inside"),
          "separating_edge_index": Null,
          "faces": [
            {
              "edge_index": Number(0, ..),
              "outward_normal": [Number(0, ..), Number(-1, ..)],
              "distance_m": Number(-0.5, ..),
              "normal_std_m": Number(0.25, ..),
              "lower_m": Number(-1, ..),
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
      "unavailable": [],
      ..
    },
  )
  assert_true(
    @json.parse(
      @codec.ZoneEvidenceReplay::open(zone_test_source(k=0.0)).process_line(
        zone_test_frame(0L, 1.0, 1.0),
      ),
    )
    is { "evidence": [{ "decision": String("inside"), .. }], .. },
  )
}

///|
test "zone face separation stays conservative at tangencies and disjoint corners" {
  let replay = @codec.ZoneEvidenceReplay::open(zone_test_source())
  for (x, y) in [(1.2, 1.2), (1.25, 0.5)] {
    assert_true(
      @json.parse(replay.process_line(zone_test_frame(10L, x, y)))
      is {
        "evidence": [
          {
            "decision": String("indeterminate"),
            "separating_edge_index": Null,
            ..
          },
        ],
        ..
      },
    )
  }
  assert_true(
    @json.parse(replay.process_line(zone_test_frame(10L, 1.5, 1.5)))
    is {
      "evidence": [
        {
          "decision": String("outside"),
          "separating_edge_index": Number(1, ..),
          ..
        },
      ],
      ..
    },
  )
}

///|
test "zone frame evaluation is stateless for repeated reordered input and empty batches" {
  let replay = @codec.ZoneEvidenceReplay::open(zone_test_source())
  let raw = zone_test_frame(100L, 0.5, 0.5)
  let expected = replay.process_line(raw)
  ignore(replay.process_line(zone_test_frame(1L, 2.0, 0.5)))
  assert_eq(replay.process_line(raw), expected)
  assert_eq(
    @codec.zone_evidence_json(
      Json::object({
        "source": Json(zone_test_source()),
        "measurements": Json(""),
      }).stringify(),
    ),
    "{\"frames\":[]}",
  )
}

///|
test "zone unavailable rows preserve initialization quality and projection failure identities" {
  let replay = @codec.ZoneEvidenceReplay::open(zone_test_source())
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
  let raw = @json.parse(zone_test_frame(20L, 0.5, 0.5, status="initializing"))
  guard raw is { "tracks": Array(tracks), .. } else { fail("tracks missing") }
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
    @json.parse(replay.process_line(raw.stringify()))
    is {
      "evidence": [],
      "unavailable": [
        _,
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
test "zone protocol rejects unknown duplicate geometry and capacity configuration" {
  let raw = zone_test_source()
  for
    bad in [
      raw.replace(old="{", new="{\"session_id\":\"other\","),
      raw.replace(old="{", new="{\"extra\":0,"),
      "{\"resume\":{}}",
      "{\"session_id\":\"s\",\"zones\":[]}",
      "{\"session_id\":\"s\",\"zones\":[{\"zone_id\":\"a\",\"vertices_m\":[[0,0],[1,1],[0,1],[1,0]]}]}",
      raw.replace(
        old="\"max_tracks\":2",
        new="\"max_tracks\":2.0000000000000001",
      ),
    ] {
    try @codec.ZoneEvidenceReplay::open(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid zone configuration accepted")
    }
  }
  let config = @json.parse(raw)
  guard config is Object(fields) && fields.get("zones") is Some(Array(zones)) else {
    fail("zones missing")
  }
  zones.push(zones[0])
  try @codec.ZoneEvidenceReplay::open(config.stringify()) catch {
    _ => ()
  } noraise {
    _ => fail("duplicate zone identity accepted")
  }
}

///|
test "zone input preserves exact identities and requires a current Ready position" {
  let replay = @codec.ZoneEvidenceReplay::open(zone_test_source())
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
      raw.replace(old="\"timestamp_us\":\"10\"", new="\"timestamp_us\":\"01\""),
    ] {
    try replay.process_line(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid current zone frame accepted")
    }
  }
  assert_true(@json.parse(replay.process_line(raw)) is { "evidence": [_], .. })
}

///|
test "zone numeric rejection does not poison later evaluation or expose a failed batch prefix" {
  let replay = @codec.ZoneEvidenceReplay::open(zone_test_source(k=1.0e308))
  let raw = zone_test_frame(10L, 0.5, 0.5)
  let huge = @json.parse(raw)
  guard huge is { "tracks": [Object(track)], .. } else { fail("track missing") }
  track["position_covariance"] = Json([4.0, 0.0, 9.0])
  track["position_std_m"] = Json(3.0)
  try replay.process_line(huge.stringify()) catch {
    _ => ()
  } noraise {
    _ => fail("overflowing face interval accepted")
  }
  assert_true(@json.parse(replay.process_line(raw)) is { "evidence": [_], .. })
  try
    @codec.zone_evidence_json(
      Json::object({
        "source": Json(zone_test_source()),
        "measurements": Json(raw + "\n{}"),
      }).stringify(),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("failed batch returned a prefix")
  }
}

///|
test "zone pure protocol preserves CRLF EOF and independent inter-frame order" {
  let frames = [zone_test_frame(10L, 0.5, 0.5), zone_test_frame(5L, 2.0, 0.5)]
  let request = (text : String) => {
    Json::object({
      "source": Json(zone_test_source()),
      "measurements": Json(text),
    }).stringify()
  }
  let expected = @codec.zone_evidence_json(request(frames.join("\n")))
  assert_eq(
    expected,
    @codec.zone_evidence_json(request(frames.join("\r\n") + "\r\n")),
  )
  assert_true(@json.parse(expected) is { "frames": [_, _], .. })
}

///|
test "zone raw sloped edges keep their own vertices inside the closed polygon" {
  let config = @json.parse(zone_test_source(k=0.0))
  guard config is { "zones": [Object(zone)], .. } else { fail("zone missing") }
  zone["vertices_m"] = Json([[0.0, 0.0], [3.0, 4.0], [0.0, 5.0]])
  let replay = @codec.ZoneEvidenceReplay::open(config.stringify())
  for (x, y) in [(0.0, 0.0), (3.0, 4.0), (0.0, 5.0), (1.5, 2.0)] {
    assert_true(
      @json.parse(replay.process_line(zone_test_frame(10L, x, y)))
      is { "evidence": [{ "decision": String("inside"), .. }], .. },
    )
  }
}
