///|
fn guarded_window_test_source(
  guarded~ : String = guarded_transit_test_source(),
  origin~ : Int64 = 0L,
) -> String raise {
  Json::object({
    "guarded": Json(guarded),
    "windows": Json(window_analysis_test_options(origin~)),
  }).stringify()
}

///|
fn guarded_window_empty_frame(time : Int64) -> String {
  Json::object({
    "measurement": Json(
      Json::object({
        "timestamp_us": Json(time.to_string()),
        "observations": Json::array([]),
      }).stringify(),
    ),
    "health": Json(health_test_frame(time)),
  }).stringify()
}

///|
fn guarded_window_invalid_pair(saved : Json) -> Unit raise {
  guard saved is { "guarded": guarded, "windows": windows, .. } else {
    fail("components missing")
  }
  ignore(
    @codec.EvidenceGuardedTransitReplay::open(
      "{\"resume\":" + guarded.stringify() + "}",
    ),
  )
  ignore(
    @codec.EvidenceTransitWindowReplay::open(
      "{\"resume\":" + windows.stringify() + "}",
    ),
  )
  try
    @codec.EvidenceGuardedTransitWindowReplay::open(
      "{\"resume\":" + saved.stringify() + "}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("jointly impossible components accepted")
  }
}

///|
test "guarded windows match original guarded outputs and downstream windows including blocked frames" {
  let source = guarded_transit_test_source()
  let old = @codec.EvidenceGuardedTransitReplay::open(source)
  let initial = @json.parse(old.checkpoint_json())
  guard initial is { "analysis": { "transit": transit, .. }, .. } else {
    fail("transit missing")
  }
  let windows = @codec.EvidenceTransitWindowReplay::open(
    Json::object({
      "transit": Json("{\"resume\":" + transit.stringify() + "}"),
      "window_us": Json("500000"),
      "duration_limits_us": Json([
        "0", "100000", "200000", "9223372036854775807",
      ]),
    }).stringify(),
  )
  let joint = @codec.EvidenceGuardedTransitWindowReplay::open(
    guarded_window_test_source(),
  )
  for
    raw in [
      guarded_test_frame(0L, 100.0),
      guarded_test_frame(100000L, 100.0),
      guarded_test_frame(200000L, 140.0),
      guarded_test_frame(300000L, 180.0),
      guarded_test_frame(400000L, 180.0, shift=50.0),
      guarded_test_frame(600000L, 100.0),
    ] {
    let guarded = @json.parse(old.process_line(raw))
    guard guarded is { "analysis": { "transit": transited, .. }, .. } else {
      fail("transit missing")
    }
    let counted = @json.parse(windows.process_line(transited.stringify()))
    assert_eq(
      @json.parse(joint.process_line(raw)),
      Json::object({
        "schema_version": Json("0.1.0"),
        "kind": Json("evidence_guarded_transit_window_frame"),
        "guarded": guarded,
        "windows": counted,
      }),
    )
  }
  guard @json.parse(joint.checkpoint_json())
    is { "guarded": guarded, "windows": counted, .. } else {
    fail("saved components missing")
  }
  assert_eq(guarded, @json.parse(old.checkpoint_json()))
  assert_eq(counted, @json.parse(windows.checkpoint_json()))
}

///|
test "guarded window complete and original component resumes preserve every prefix" {
  let source = guarded_window_test_source()
  let frames = [
    guarded_test_frame(0L, 100.0),
    guarded_test_frame(100000L, 100.0),
    guarded_test_frame(200000L, 140.0),
    guarded_test_frame(300000L, 180.0),
    guarded_test_frame(500000L, 180.0, shift=50.0),
  ]
  let full = @codec.EvidenceGuardedTransitWindowReplay::open(source)
  let output = frames.map(frame => full.process_line(frame))
  for cut in 0..<=frames.length() {
    let prefix = @codec.EvidenceGuardedTransitWindowReplay::open(source)
    for index in 0..<cut {
      ignore(prefix.process_line(frames[index]))
    }
    let saved = prefix.checkpoint_json()
    guard @json.parse(saved) is { "guarded": guarded, "windows": windows, .. } else {
      fail("components missing")
    }
    for
      header in [
        "{\"resume\":" + saved + "}",
        Json::object({
          "guarded": Json("{\"resume\":" + guarded.stringify() + "}"),
          "windows": Json("{\"resume\":" + windows.stringify() + "}"),
        }).stringify(),
      ] {
      let resumed = @codec.EvidenceGuardedTransitWindowReplay::open(header)
      for index in cut..<frames.length() {
        assert_eq(resumed.process_line(frames[index]), output[index])
      }
      assert_eq(resumed.checkpoint_json(), full.checkpoint_json())
    }
  }
}

///|
test "guarded window late origin failure discards health progress and the measurement candidate" {
  let replay = @codec.EvidenceGuardedTransitWindowReplay::open(
    guarded_window_test_source(origin=100000L),
  )
  let before = replay.checkpoint_json()
  try replay.process_line(guarded_test_frame(99999L, 100.0)) catch {
    _ => ()
  } noraise {
    _ => fail("early origin accepted")
  }
  assert_eq(replay.checkpoint_json(), before)
  assert_true(
    @json.parse(replay.process_line(guarded_test_frame(100000L, 100.0)))
    is {
      "guarded": {
        "decision": String("blocked"),
        "health": { "streak_observations": Number(1, ..), .. },
        ..
      },
      "windows": { "current_window": { "input_frames": String("1"), .. }, .. },
      ..
    },
  )
}

///|
test "first healthy numeric failure leaves window and confirmation reusable at the same time" {
  let replay = @codec.EvidenceGuardedTransitWindowReplay::open(
    guarded_window_test_source(guarded=guarded_transit_test_source(k=1.0e308)),
  )
  ignore(replay.process_line(guarded_test_frame(0L, 100.0)))
  let saved = replay.checkpoint_json()
  let huge = Json::object({
    "measurement": Json(
      (
        #|{"timestamp_us":"100000","observations":[{"track_id":7,"point":[100,200],"covariance":[100000000,0,100000000]}]}
      ),
    ),
    "health": Json(health_test_frame(100000L)),
  }).stringify()
  try replay.process_line(huge) catch {
    _ => ()
  } noraise {
    _ => fail("numeric failure accepted")
  }
  assert_eq(replay.checkpoint_json(), saved)
  assert_true(
    @json.parse(replay.process_line(guarded_test_frame(100000L, 100.0)))
    is {
      "guarded": {
        "decision": String("allowed"),
        "analysis": {
          "measurement": { "tracks": [{ "segment_id": String("1"), .. }], .. },
          ..
        },
        ..
      },
      "windows": { "current_window": { "input_frames": String("2"), .. }, .. },
      ..
    },
  )
}

///|
test "guarded window restore rejects missing blocked health samples although both old components restore" {
  guard @json.parse(guarded_transit_test_source()) is Object(source) &&
    source.get("health") is Some(String(raw)) &&
    @json.parse(raw) is Object(config) &&
    config.get("health") is Some(Object(policy)) else {
    fail("health policy missing")
  }
  policy["min_observations"] = Json(4)
  source["health"] = Json(Json::object(config).stringify())
  let replay = @codec.EvidenceGuardedTransitWindowReplay::open(
    guarded_window_test_source(guarded=Json::object(source).stringify()),
  )
  for time in 0L..<3L {
    ignore(replay.process_line(guarded_window_empty_frame(time)))
  }
  let saved = @json.parse(replay.checkpoint_json())
  guard saved is { "windows": { "current_window": Object(current), .. }, .. } else {
    fail("window missing")
  }
  current["input_frames"] = Json("2")
  guarded_window_invalid_pair(saved)
}

///|
test "guarded window restore counts continuous health gaps after evidence counter saturates" {
  guard @json.parse(guarded_transit_test_source()) is Object(source) &&
    source.get("health") is Some(String(raw)) &&
    @json.parse(raw) is Object(config) &&
    config.get("health") is Some(Object(policy)) else {
    fail("health policy missing")
  }
  policy["min_observations"] = Json(1)
  policy["max_gap_us"] = Json("4")
  source["health"] = Json(Json::object(config).stringify())
  let replay = @codec.EvidenceGuardedTransitWindowReplay::open(
    guarded_window_test_source(guarded=Json::object(source).stringify()),
  )
  for time in [0L, 2L, 4L, 6L, 8L, 10L] {
    ignore(replay.process_line(guarded_window_empty_frame(time)))
  }
  let saved = @json.parse(replay.checkpoint_json())
  guard saved is { "windows": { "current_window": Object(current), .. }, .. } else {
    fail("window missing")
  }
  current["input_frames"] = Json("2")
  guarded_window_invalid_pair(saved)
}

///|
test "guarded window projection barriers count cancellations once and commit both configurations only on success" {
  let early = @codec.EvidenceGuardedTransitWindowReplay::open(
    guarded_window_test_source(origin=300000L),
  )
  let initial = early.checkpoint_json()
  try early.process_line(projection_test_control(250000L)) catch {
    _ => ()
  } noraise {
    _ => fail("early barrier accepted")
  }
  assert_eq(early.checkpoint_json(), initial)
  ignore(early.process_line(projection_test_control(300000L)))
  let replay = @codec.EvidenceGuardedTransitWindowReplay::open(
    guarded_window_test_source(),
  )
  for
    raw in [
      guarded_test_frame(0L, 100.0),
      guarded_test_frame(100000L, 100.0),
      guarded_test_frame(200000L, 140.0),
    ] {
    ignore(replay.process_line(raw))
  }
  assert_true(
    @json.parse(replay.process_line(projection_test_control(250000L)))
    is {
      "guarded": {
        "kind": String("evidence_guarded_transit_projection_replaced"),
        "decision": String("blocked"),
        "health": { "status": String("insufficient"), .. },
        "analysis": {
          "transit": {
            "pending_count": Number(0, ..),
            "cancellations": [{ "reason": String("discontinuity"), .. }],
            ..
          },
          ..
        },
        ..
      },
      "windows": { "current_window": { "input_frames": String("4"), .. }, .. },
      ..
    },
  )
  let saved = replay.checkpoint_json()
  assert_true(
    @json.parse(saved)
    is {
      "guarded": {
        "health": {
          "configuration": {
            "calibration": { "ground_noise_floor_m": Number(0.005, ..), .. },
            ..
          },
          ..
        },
        "analysis": {
          "measurement": {
            "configuration": {
              "calibration": { "ground_noise_floor_m": Number(0.005, ..), .. },
              ..
            },
            ..
          },
          ..
        },
        ..
      },
      ..
    },
  )
  let restored = @codec.EvidenceGuardedTransitWindowReplay::open(
    "{\"resume\":" + saved + "}",
  )
  for
    raw in [
      projection_test_frame(300000L, 50.0),
      projection_test_frame(400000L, 70.0),
      projection_test_frame(500000L, 100.0),
    ] {
    assert_eq(restored.process_line(raw), replay.process_line(raw))
  }
  assert_eq(restored.checkpoint_json(), replay.checkpoint_json())
}

///|
test "guarded window pure replay preserves raw tokens CRLF EOF and failed batch atomicity" {
  let request = (observations : String) => {
    Json::object({
      "source": Json(guarded_window_test_source()),
      "observations": Json(observations),
    }).stringify()
  }
  let frames = [
    guarded_test_frame(0L, 100.0),
    guarded_test_frame(100000L, 100.0),
  ]
  assert_eq(
    @codec.evidence_guarded_transit_window_json(request(frames.join("\n"))),
    @codec.evidence_guarded_transit_window_json(
      request(frames.join("\r\n") + "\r\n"),
    ),
  )
  assert_true(
    @json.parse(@codec.evidence_guarded_transit_window_json(request("")))
    is { "frames": [], .. },
  )
  guard @json.parse(frames[0]) is Object(fields) &&
    fields.get("measurement") is Some(String(measured)) else {
    fail("raw measurement missing")
  }
  fields["measurement"] = Json(
    measured.replace(
      old="\"track_id\":7",
      new="\"track_id\":7.0000000000000001",
    ),
  )
  for
    invalid in [
      frames.join("\n") + "\n{}",
      frames.join("\n") + "\n\n",
      Json::object(fields).stringify(),
    ] {
    try @codec.evidence_guarded_transit_window_json(request(invalid)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid raw batch accepted")
    }
  }
}
