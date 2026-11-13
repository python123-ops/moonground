///|
fn evidence_guarded_test_source(k~ : Double = 2.0) -> String raise {
  guard @json.parse(guarded_test_source()) is Object(source) &&
    source.get("analysis") is Some(String(raw)) &&
    @json.parse(raw) is Object(analysis) &&
    analysis.get("counting") is Some(String(counting)) else {
    fail("guarded fixture missing")
  }
  analysis["counting"] = Json(
    Json::object({ "counting": Json(counting), "sigma_multiplier": Json(k) }).stringify(),
  )
  source["analysis"] = Json(Json::object(analysis).stringify())
  Json::object(source).stringify()
}

///|
test "evidence guarded replay retains health decisions and original measured motion with independent covariance counts" {
  let source = evidence_guarded_test_source()
  let replay = @codec.EvidenceGuardedReplay::open(source)
  let legacy = @codec.GuardedReplay::open(guarded_test_source())
  for
    frame in [
      guarded_test_frame(0L, 100.0),
      guarded_test_frame(100000L, 100.0),
      guarded_test_frame(200000L, 140.0),
      guarded_test_frame(300000L, 100.0, shift=50.0),
      guarded_test_frame(400000L, 100.0),
      guarded_test_frame(500000L, 100.0),
    ] {
    let actual = @json.parse(replay.process_line(frame))
    let expected = @json.parse(legacy.process_line(frame))
    guard actual
      is {
        "decision": decision,
        "health": health,
        "analysis": { "measurement": measurement, .. },
        "suppressed_track_ids": suppressed,
        ..
      } &&
      expected
      is {
        "decision": old_decision,
        "health": old_health,
        "analysis": { "measurement": old_measurement, .. },
        "suppressed_track_ids": old_suppressed,
        ..
      } else {
      fail("guarded frame missing")
    }
    assert_eq(decision, old_decision)
    assert_eq(health, old_health)
    assert_eq(measurement, old_measurement)
    assert_eq(suppressed, old_suppressed)
  }
  let saved = replay.checkpoint_json()
  let restored = @codec.EvidenceGuardedReplay::open(
    "{\"resume\":" + saved + "}",
  )
  let next = guarded_test_frame(600000L, 140.0)
  assert_eq(restored.process_line(next), replay.process_line(next))
  assert_eq(restored.checkpoint_json(), replay.checkpoint_json())
}

///|
test "normal radius failure at health confirmation rolls back the streak and newly allocated segment" {
  let replay = @codec.EvidenceGuardedReplay::open(
    evidence_guarded_test_source(k=1.0e308),
  )
  ignore(replay.process_line(guarded_test_frame(0L, 100.0)))
  let saved = replay.checkpoint_json()
  let measurement =
    #|{"timestamp_us":"100000","observations":[{"track_id":7,"point":[100,200],"covariance":[100000000,0,100000000]}]}
  let large = Json::object({
    "measurement": Json(measurement),
    "health": Json(health_test_frame(100000L)),
  }).stringify()
  try replay.process_line(large) catch {
    _ => ()
  } noraise {
    _ => fail("unrepresentable normal radius accepted")
  }
  assert_eq(replay.checkpoint_json(), saved)
  assert_true(
    @json.parse(replay.process_line(guarded_test_frame(100000L, 100.0)))
    is {
      "decision": String("allowed"),
      "analysis": {
        "measurement": { "tracks": [{ "segment_id": String("1"), .. }], .. },
        "counting": { "evidence": [{ "side": String("unconfirmed"), .. }], .. },
        ..
      },
      ..
    },
  )
}

///|
test "blocked evidence input rejects malformed raw identities before health can advance" {
  let replay = @codec.EvidenceGuardedReplay::open(
    evidence_guarded_test_source(),
  )
  ignore(replay.process_line(guarded_test_frame(0L, 100.0)))
  let saved = replay.checkpoint_json()
  let good = guarded_test_measurement(100000L, 100.0)
  for
    measurement in [
      good.replace(old="\"track_id\":7", new="\"track_id\":7.00000000000000001"),
      good.replace(old="\"track_id\":7", new="\"track_id\":7,\"track_id\":7"),
      good.replace(
        old="\"point\":[100,200]",
        new="\"point\":[100,200],\"covariance\":[1,2,1]",
      ),
    ] {
    let frame = Json::object({
      "measurement": Json(measurement),
      "health": Json(health_test_frame(100000L, shift=50.0)),
    }).stringify()
    try replay.process_line(frame) catch {
      _ => ()
    } noraise {
      _ => fail("blocked frame hid malformed raw input")
    }
    assert_eq(replay.checkpoint_json(), saved)
  }
}

///|
test "evidence projection replacement exports both new configurations and restores cold confirmation" {
  let replay = @codec.EvidenceGuardedReplay::open(
    evidence_guarded_test_source(),
  )
  for
    frame in [
      guarded_test_frame(0L, 100.0),
      guarded_test_frame(100000L, 100.0),
      guarded_test_frame(200000L, 140.0),
    ] {
    ignore(replay.process_line(frame))
  }
  assert_true(
    @json.parse(replay.process_line(projection_test_control(250000L)))
    is {
      "kind": String("evidence_guarded_projection_replaced"),
      "decision": String("blocked"),
      "health": { "status": String("insufficient"), .. },
      "analysis": {
        "measurement": { "tracks": [], "closed_segment_ids": [String("1")], .. },
        "counting": {
          "evidence": [],
          "counting": {
            "counts": [{ "positive_to_negative": String("1"), .. }],
            ..
          },
          ..
        },
        ..
      },
      ..
    },
  )
  let saved = replay.checkpoint_json()
  assert_true(
    @json.parse(saved)
    is {
      "analysis": {
        "measurement": {
          "configuration": {
            "calibration": { "ground_noise_floor_m": Number(0.005, ..), .. },
            ..
          },
          ..
        },
        "counting": {
          "configuration": { "sigma_multiplier": Number(2, ..), .. },
          "state": { "tracks": [], .. },
          ..
        },
        ..
      },
      "health": {
        "configuration": {
          "calibration": { "ground_noise_floor_m": Number(0.005, ..), .. },
          ..
        },
        ..
      },
      ..
    },
  )
  let restored = @codec.EvidenceGuardedReplay::open(
    "{\"resume\":" + saved + "}",
  )
  for
    frame in [
      projection_test_frame(300000L, 50.0),
      projection_test_frame(400000L, 70.0),
      projection_test_frame(500000L, 100.0),
    ] {
    assert_eq(restored.process_line(frame), replay.process_line(frame))
  }
  assert_eq(restored.checkpoint_json(), replay.checkpoint_json())
}

///|
test "complete evidence guarded restore refuses mismatched health and legacy counter formats" {
  let replay = @codec.EvidenceGuardedReplay::open(
    evidence_guarded_test_source(),
  )
  ignore(replay.process_line(guarded_test_frame(0L, 100.0)))
  ignore(replay.process_line(guarded_test_frame(100000L, 100.0)))
  let saved = replay.checkpoint_json()
  guard @json.parse(saved) is Object(fields) &&
    fields.get("health") is Some(health) &&
    health is { "state": Object(state), .. } else {
    fail("health checkpoint missing")
  }
  state["last_timestamp_us"] = Json("100001")
  // Both components remain individually restorable; only their binding fails.
  ignore(@codec.HealthReplay::open("{\"resume\":" + health.stringify() + "}"))
  try
    @codec.EvidenceGuardedReplay::open(
      "{\"resume\":" + Json::object(fields).stringify() + "}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("incompatible health checkpoint accepted")
  }
  let legacy = @codec.GuardedReplay::open(guarded_test_source()).checkpoint_json()
  try @codec.EvidenceGuardedReplay::open("{\"resume\":" + legacy + "}") catch {
    _ => ()
  } noraise {
    _ => fail("legacy guarded checkpoint lost its counter policy")
  }
  try @codec.GuardedReplay::open("{\"resume\":" + saved + "}") catch {
    _ => ()
  } noraise {
    _ => fail("legacy owner accepted covariance evidence state")
  }
}

///|
test "pure evidence guarded batches preserve CRLF EOF and return no prefix on later errors" {
  let request = (observations : String) => {
    Json::object({
      "source": Json(evidence_guarded_test_source()),
      "observations": Json(observations),
    }).stringify()
  }
  let frames = [
    guarded_test_frame(0L, 100.0),
    guarded_test_frame(100000L, 100.0),
  ]
  let result = @codec.evidence_guarded_json(request(frames.join("\n")))
  assert_eq(
    result,
    @codec.evidence_guarded_json(request(frames.join("\r\n") + "\r\n")),
  )
  assert_true(
    @json.parse(result)
    is {
      "frames": [_, _],
      "checkpoint": { "format": String("moonground.evidence-guarded"), .. },
      ..
    },
  )
  for text in [frames.join("\n") + "\n{}", frames.join("\n") + "\n\n"] {
    try @codec.evidence_guarded_json(request(text)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid later guarded evidence frame accepted")
    }
  }
}
