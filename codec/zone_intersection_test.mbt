///|
test "ellipse intersection resolves a disjoint corner without changing original face evidence" {
  let source = zone_test_source()
  let raw = zone_test_frame(9007199254740993L, 1.2, 1.2)
  let old = @codec.ZoneEvidenceReplay::open(source)
  let before = old.process_line(raw)
  assert_true(
    @json.parse(before)
    is { "evidence": [{ "decision": String("indeterminate"), .. }], .. },
  )
  let replay = @codec.ZoneIntersectionReplay::open(source)
  guard @json.parse(replay.process_line(raw))
    is {
      "schema_version": String("0.1.0"),
      "kind": String("position_zone_intersection_frame"),
      "evidence_scope": String(
        "model_position_ellipse_convex_zone_intersection"
      ),
      "timestamp_us": String("9007199254740993"),
      "evidence": [
        {
          "decision": String("disjoint"),
          "minimum_quadratic_lower": Number(lower, ..),
          "minimum_quadratic_upper": Number(upper, ..),
          "witness_edge_index": Number(_, ..),
          "witness_fraction": Number(fraction, ..),
          "witness_position_m": [Number(_, ..), Number(_, ..)],
          ..
        },
      ],
      "unavailable": [],
      ..
    } else {
    fail("corner separation missing")
  }
  assert_true(lower > 1.0 && lower <= upper)
  assert_true(lower > 1.27999999 && upper < 1.28000001)
  assert_true(fraction >= 0.0 && fraction <= 1.0)
  assert_eq(old.process_line(raw), before)
}

///|
test "ellipse intersection keeps actual closed tangencies unresolved or intersecting" {
  let replay = @codec.ZoneIntersectionReplay::open(zone_test_source())
  for (x, y) in [(1.25, 0.5), (0.5, 0.5)] {
    guard @json.parse(replay.process_line(zone_test_frame(10L, x, y)))
      is { "evidence": [{ "decision": String(decision), .. }], .. } else {
      fail("intersection result missing")
    }
    assert_true(decision == "intersects" || decision == "indeterminate")
  }
  assert_true(
    @json.parse(replay.process_line(zone_test_frame(10L, 0.5, 0.5)))
    is {
      "evidence": [
        {
          "decision": String("intersects"),
          "minimum_quadratic_lower": Number(0, ..),
          "minimum_quadratic_upper": Number(0, ..),
          "witness_edge_index": Null,
          "witness_fraction": Null,
          ..
        },
      ],
      ..
    },
  )
}

///|
test "ellipse intersection is stateless across frame reordering and failed input" {
  let replay = @codec.ZoneIntersectionReplay::open(zone_test_source())
  let raw = zone_test_frame(100L, 1.2, 1.2)
  let expected = replay.process_line(raw)
  ignore(replay.process_line(zone_test_frame(1L, 0.5, 0.5)))
  try
    replay.process_line(raw.replace(old="\"ready\"", new="\"unknown\""))
  catch {
    _ => ()
  } noraise {
    _ => fail("bad status accepted")
  }
  assert_eq(replay.process_line(raw), expected)
  assert_eq(
    @codec.zone_intersection_json(
      Json::object({
        "source": Json(zone_test_source()),
        "measurements": Json(""),
      }).stringify(),
    ),
    "{\"frames\":[]}",
  )
  assert_true(
    @json.parse(
      @codec.zone_intersection_json(
        Json::object({
          "source": Json(zone_test_source()),
          "measurements": Json(raw + "\r\n" + raw),
        }).stringify(),
      ),
    )
    is { "frames": [_, _], .. },
  )
}

///|
test "ellipse intersection raw configuration retains original strict parsing" {
  let raw = zone_test_source()
  for
    bad in [
      raw.replace(old="{", new="{\"session_id\":\"other\","),
      raw.replace(old="{", new="{\"extra\":0,"),
      raw.replace(
        old="\"max_tracks\":2",
        new="\"max_tracks\":2.0000000000000001",
      ),
      "{\"resume\":{}}",
    ] {
    try @codec.ZoneIntersectionReplay::open(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid intersection configuration accepted")
    }
  }
}

///|
test "ellipse intersection requires current Ready positions and exact original track identities" {
  let replay = @codec.ZoneIntersectionReplay::open(zone_test_source())
  let raw = zone_test_frame(10L, 0.5, 0.5)
  for
    bad in [
      raw.replace(
        old="\"last_accepted_timestamp_us\":\"10\"",
        new="\"last_accepted_timestamp_us\":\"9\"",
      ),
      raw.replace(old="\"track_id\":7", new="\"track_id\":7.0000000000000001"),
      raw.replace(old="\"position_m\":[0.5,0.5]", new="\"position_m\":null"),
    ] {
    assert_true(bad != raw)
    try replay.process_line(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid current position accepted")
    }
  }
  assert_true(
    @json.parse(
      replay.process_line(zone_test_frame(10L, 0.5, 0.5, status="uncertain")),
    )
    is {
      "evidence": [],
      "unavailable": [{ "reason": String("uncertain"), .. }],
      ..
    },
  )
}

///|
test "ellipse intersection pure batch enforces count and all-or-error shape" {
  let source = zone_test_source()
  let empty = "{\"schema_version\":\"0.2.0\",\"session_id\":\"evidence-test\",\"timestamp_us\":\"0\",\"tracks\":[],\"closed_segment_ids\":[]}"
  for
    measurements in [
      Array::make(5001, empty).join("\n"),
      zone_test_frame(1L, 0.5, 0.5) + "\n{}",
    ] {
    try
      @codec.zone_intersection_json(
        Json::object({
          "source": Json(source),
          "measurements": Json(measurements),
        }).stringify(),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid whole batch accepted")
    }
  }
}
