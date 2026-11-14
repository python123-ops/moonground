///|
fn guarded_run_test_source() -> String raise {
  guard @json.parse(guarded_test_source())
    is { "analysis": String(raw), "health": health, .. } &&
    @json.parse(raw) is { "measurement": measurement, .. } else {
    fail("missing guarded fixture")
  }
  let zones =
    #|{"session_id":"guarded-test","zones":[{"zone_id":"wide","vertices_m":[[-5,-5],[10,-5],[10,10],[-5,10]],"sigma_multiplier":0}],"max_tracks":2}
  Json::object({
    "analysis": Json(
      Json::object({
        "measurement": measurement,
        "runs": Json(
          Json::object({
            "position": Json(zones),
            "options": Json("{\"confirmation_us\":\"0\",\"min_samples\":\"2\"}"),
          }).stringify(),
        ),
      }).stringify(),
    ),
    "health": health,
  }).stringify()
}

///|
fn guarded_run_test_assignments(
  time : Int64,
  segment~ : String = "1",
  empty~ : Bool = false,
) -> String {
  Json::object({
    "timestamp_us": Json(time.to_string()),
    "footprints": if empty {
      Json::array([])
    } else {
      Json([
        Json::object({
          "track_id": Json(7),
          "segment_id": Json(segment),
          "shape": Json::object({ "kind": Json("disk"), "radius_m": Json(0.1) }),
        }),
      ])
    },
  }).stringify()
}

///|
fn guarded_run_test_frame(
  time : Int64,
  empty~ : Bool = false,
  segment~ : String = "1",
  shift~ : Double = 0.0,
) -> String {
  Json::object({
    "measurement": Json(guarded_test_measurement(time, 100.0)),
    "health": Json(health_test_frame(time, shift~)),
    "assignments": Json(guarded_run_test_assignments(time, empty~, segment~)),
  }).stringify()
}

///|
test "guarded footprint replay preserves original health and pixel measurement across recovery" {
  let replay = @codec.FootprintRunGuardedReplay::open(guarded_run_test_source())
  let original = @codec.GuardedReplay::open(guarded_test_source())
  for
    (time, empty, segment, shift) in [
      (0L, true, "1", 0.0),
      (100000L, false, "1", 0.0),
      (200000L, false, "1", 0.0),
      (300000L, true, "1", 50.0),
      (400000L, true, "1", 0.0),
      (500000L, false, "2", 0.0),
      (600000L, false, "2", 0.0),
    ] {
    guard @json.parse(
        replay.process_line(
          guarded_run_test_frame(time, empty~, segment~, shift~),
        ),
      )
      is {
        "decision": decision,
        "health": health,
        "analysis": { "measurement": measurement, .. },
        "suppressed_track_ids": suppressed,
        ..
      } &&
      @json.parse(
        original.process_line(guarded_test_frame(time, 100.0, shift~)),
      )
      is {
        "decision": expected_decision,
        "health": expected_health,
        "analysis": { "measurement": expected_measurement, .. },
        "suppressed_track_ids": expected_suppressed,
        ..
      } else {
      fail("missing guarded result")
    }
    assert_eq(decision, expected_decision)
    assert_eq(health, expected_health)
    assert_eq(measurement, expected_measurement)
    assert_eq(suppressed, expected_suppressed)
    ignore(
      @codec.FootprintRunGuardedReplay::open(
        "{\"resume\":" + replay.checkpoint_json() + "}",
      ),
    )
  }
}

///|
test "blocked raw footprints are rejected without consuming health or motion and exact empty retry works" {
  let replay = @codec.FootprintRunGuardedReplay::open(guarded_run_test_source())
  let before = replay.checkpoint_json()
  try replay.process_line(guarded_run_test_frame(0L)) catch {
    _ => ()
  } noraise {
    _ => fail("suppressed shape silently ignored")
  }
  assert_eq(replay.checkpoint_json(), before)
  assert_true(
    @json.parse(replay.process_line(guarded_run_test_frame(0L, empty=true)))
    is {
      "decision": String("blocked"),
      "analysis": { "measurement": { "tracks": [], .. }, .. },
      ..
    },
  )
}

///|
test "first healthy wrong candidate segment preserves pending health and next segment for corrected retry" {
  let replay = @codec.FootprintRunGuardedReplay::open(guarded_run_test_source())
  ignore(replay.process_line(guarded_run_test_frame(0L, empty=true)))
  let before = replay.checkpoint_json()
  try replay.process_line(guarded_run_test_frame(100000L, segment="2")) catch {
    _ => ()
  } noraise {
    _ => fail("incorrect candidate accepted")
  }
  assert_eq(replay.checkpoint_json(), before)
  assert_true(
    @json.parse(replay.process_line(guarded_run_test_frame(100000L)))
    is {
      "decision": String("allowed"),
      "analysis": {
        "measurement": { "tracks": [{ "segment_id": String("1"), .. }], .. },
        ..
      },
      ..
    },
  )
}

///|
test "single paired preview is read only and reports actual empty blocked candidate" {
  let replay = @codec.FootprintRunGuardedReplay::open(guarded_run_test_source())
  let before = replay.checkpoint_json()
  let input = guarded_test_frame(0L, 100.0)
  let preview = replay.preview_line(input)
  assert_eq(preview, replay.preview_line(input))
  assert_eq(replay.checkpoint_json(), before)
  assert_true(
    @json.parse(preview)
    is {
      "decision": String("blocked"),
      "suppressed_track_ids": [Number(7, ..)],
      "measurement": { "tracks": [], .. },
      ..
    },
  )
  ignore(replay.process_line(guarded_run_test_frame(0L, empty=true)))
  assert_true(
    @json.parse(replay.preview_line(guarded_test_frame(100000L, 100.0)))
    is {
      "decision": String("allowed"),
      "measurement": { "tracks": [{ "segment_id": String("1"), .. }], .. },
      ..
    },
  )
}

///|
test "batch identity discovery includes reborn segments and never returns durable state or shape evidence" {
  let pairs = [
    guarded_test_frame(0L, 100.0),
    guarded_test_frame(100000L, 100.0),
    guarded_test_frame(200000L, 100.0),
    guarded_test_frame(300000L, 100.0, shift=50.0),
    guarded_test_frame(400000L, 100.0),
    guarded_test_frame(500000L, 100.0),
  ]
  let request = Json::object({
    "source": Json(guarded_run_test_source()),
    "frames": Json(pairs.join("\n")),
  }).stringify()
  let output = @codec.footprint_run_guarded_preview_json(request)
  assert_eq(output, @codec.footprint_run_guarded_preview_json(request))
  guard @json.parse(output) is Object(fields) &&
    fields.get("frames") is Some(Array(frames)) else {
    fail("missing discovery")
  }
  assert_eq(fields.length(), 1)
  assert_eq(frames.length(), 6)
  assert_true(
    frames[3]
    is {
      "decision": String("blocked"),
      "measurement": { "closed_segment_ids": [String("1")], "tracks": [], .. },
      ..
    },
  )
  assert_true(
    frames[5]
    is {
      "decision": String("allowed"),
      "measurement": { "tracks": [{ "segment_id": String("2"), .. }], .. },
      ..
    },
  )
  assert_true(!output.contains("\"checkpoint\""))
  assert_true(!output.contains("\"runs\""))
}

///|
test "projection replacement updates complete configurations and cold health at a strict barrier" {
  let replay = @codec.FootprintRunGuardedReplay::open(guarded_run_test_source())
  for
    (time, empty) in [
      (0L, true),
      (100000L, false),
      (200000L, false),
      (300000L, false),
      (400000L, false),
      (500000L, false),
    ] {
    ignore(replay.process_line(guarded_run_test_frame(time, empty~)))
  }
  let before = replay.checkpoint_json()
  try replay.process_line(projection_test_control(500000L)) catch {
    _ => ()
  } noraise {
    _ => fail("same watermark replacement")
  }
  assert_eq(replay.checkpoint_json(), before)
  assert_true(
    @json.parse(replay.process_line(projection_test_control(550000L)))
    is {
      "kind": String("footprint_run_guarded_projection_replaced"),
      "health": { "status": String("insufficient"), .. },
      "analysis": {
        "measurement": { "closed_segment_ids": [String("1")], .. },
        "runs": { "active": [], "closed": [_, ..], .. },
        ..
      },
      ..
    },
  )
  let restored = @codec.FootprintRunGuardedReplay::open(
    "{\"resume\":" + replay.checkpoint_json() + "}",
  )
  guard @json.parse(projection_test_frame(600000L, 50.0)) is Object(pair) else {
    fail("missing pair")
  }
  pair["assignments"] = Json(guarded_run_test_assignments(600000L, empty=true))
  assert_eq(
    restored.process_line(Json::object(pair).stringify()),
    replay.process_line(Json::object(pair).stringify()),
  )
  assert_eq(restored.checkpoint_json(), replay.checkpoint_json())
}

///|
test "strict paired original numerals unknown and duplicate keys fail without advancement" {
  let replay = @codec.FootprintRunGuardedReplay::open(guarded_run_test_source())
  let before = replay.checkpoint_json()
  let frame = guarded_run_test_frame(0L, empty=true)
  for
    bad in [
      frame.replace(
        old="\\\"track_id\\\":7",
        new="\\\"track_id\\\":7.0000000000000001",
      ),
      frame.replace(
        old="\"measurement\":",
        new="\"measurement\":\"{}\",\"measurement\":",
      ),
      frame.replace(old="\"assignments\":", new="\"extra\":0,\"assignments\":"),
      frame.replace(
        old="\\\"timestamp_us\\\":\\\"0\\\"",
        new="\\\"timestamp_us\\\":\\\"1\\\"",
      ),
    ] {
    try replay.process_line(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid original accepted: " + bad)
    }
    assert_eq(replay.checkpoint_json(), before)
  }
}

///|
test "guarded pure empty and frame count limits include complete joint checkpoint" {
  let source = guarded_run_test_source()
  assert_true(
    @json.parse(
      @codec.footprint_run_guarded_json(
        Json::object({ "source": Json(source), "frames": Json("") }).stringify(),
      ),
    )
    is {
      "frames": [],
      "checkpoint": { "format": String("moonground.footprint-run-guarded"), .. },
      ..
    },
  )
  let excessive = Array::make(5001, "{}").join("\n")
  for preview in [false, true] {
    let request = Json::object({
      "source": Json(source),
      "frames": Json(excessive),
    }).stringify()
    try {
      if preview {
        @codec.footprint_run_guarded_preview_json(request)
      } else {
        @codec.footprint_run_guarded_json(request)
      }
    } catch {
      _ => ()
    } noraise {
      _ => fail("frame limit ignored")
    }
  }
}
