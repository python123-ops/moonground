///|
fn guarded_transit_test_source(k~ : Double = 2.0) -> String raise {
  guard @json.parse(guarded_test_source()) is Object(source) &&
    source.get("analysis") is Some(String(raw)) &&
    @json.parse(raw) is { "measurement": measurement, .. } else {
    fail("measurement fixture missing")
  }
  let counting =
    #|{"session_id":"guarded-test","gates":[{"gate_id":"exit","start_m":[1.6,0],"end_m":[1.6,4],"deadband_m":0.01},{"gate_id":"entry","start_m":[1.15,0],"end_m":[1.15,4],"deadband_m":0.01}],"max_tracks":2}
  let evidence = Json::object({
    "counting": Json(counting),
    "sigma_multiplier": Json(k),
  }).stringify()
  let transit = Json::object({
    "counting": Json(evidence),
    "sections": Json([
      Json::object({
        "section_id": Json("aisle"),
        "entry_gate_id": Json("entry"),
        "entry_direction": Json("positive_to_negative"),
        "exit_gate_id": Json("exit"),
        "exit_direction": Json("positive_to_negative"),
      }),
    ]),
  }).stringify()
  source["analysis"] = Json(
    Json::object({ "measurement": measurement, "transit": Json(transit) }).stringify(),
  )
  Json::object(source).stringify()
}

///|
test "guarded evidence transit matches the original health motion and independent passage chain" {
  let source = guarded_transit_test_source()
  guard @json.parse(source)
    is { "analysis": String(raw), "health": health_source, .. } &&
    @json.parse(raw)
    is { "measurement": measurement, "transit": String(transit_source), .. } &&
    @json.parse(transit_source) is { "counting": counting, .. } else {
    fail("fixture missing")
  }
  let old = @codec.EvidenceGuardedReplay::open(
    Json::object({
      "analysis": Json(
        Json::object({ "measurement": measurement, "counting": counting }).stringify(),
      ),
      "health": health_source,
    }).stringify(),
  )
  let downstream = @codec.EvidenceTransitReplay::open(transit_source)
  let joined = @codec.EvidenceGuardedTransitReplay::open(source)
  for
    index, frame in [
      guarded_test_frame(0L, 100.0),
      guarded_test_frame(100000L, 100.0),
      guarded_test_frame(200000L, 140.0),
      guarded_test_frame(300000L, 180.0),
      guarded_test_frame(400000L, 180.0, shift=50.0),
    ] {
    let expected = @json.parse(old.process_line(frame))
    guard expected
      is {
        "analysis": { "measurement": measured, "counting": counted, .. },
        "health": health,
        "decision": decision,
        "suppressed_track_ids": suppressed,
        ..
      } else {
      fail("component frame missing")
    }
    let transited = @json.parse(downstream.process_line(measured.stringify()))
    guard transited is { "counting": evidence, .. } else {
      fail("evidence frame missing")
    }
    assert_eq(evidence, counted)
    assert_eq(
      @json.parse(joined.process_line(frame)),
      Json::object({
        "schema_version": Json("0.1.0"),
        "kind": Json("evidence_guarded_transit_frame"),
        "decision": decision,
        "health": health,
        "suppressed_track_ids": suppressed,
        "analysis": Json::object({
          "schema_version": Json("0.1.0"),
          "kind": Json("evidence_transit_analysis_frame"),
          "measurement": measured,
          "transit": transited,
        }),
      }),
    )
    if index == 2 {
      assert_true(transited is { "pending_count": Number(1, ..), .. })
    }
    if index == 3 {
      assert_true(
        transited
        is { "passages": [_], "counts": [{ "completed": String("1"), .. }], .. },
      )
    }
  }
}

///|
test "first healthy evidence transit failure preserves the landmark streak and new motion segment" {
  let replay = @codec.EvidenceGuardedTransitReplay::open(
    guarded_transit_test_source(k=1.0e308),
  )
  ignore(replay.process_line(guarded_test_frame(0L, 100.0)))
  let saved = replay.checkpoint_json()
  let measurement =
    #|{"timestamp_us":"100000","observations":[{"track_id":7,"point":[100,200],"covariance":[100000000,0,100000000]}]}
  let raw = Json::object({
    "measurement": Json(measurement),
    "health": Json(health_test_frame(100000L)),
  }).stringify()
  try replay.process_line(raw) catch {
    _ => ()
  } noraise {
    _ => fail("unrepresentable radius accepted")
  }
  assert_eq(replay.checkpoint_json(), saved)
  assert_true(
    @json.parse(replay.process_line(guarded_test_frame(100000L, 100.0)))
    is {
      "decision": String("allowed"),
      "health": { "streak_observations": Number(2, ..), .. },
      "analysis": {
        "measurement": { "tracks": [{ "segment_id": String("1"), .. }], .. },
        "transit": {
          "counting": {
            "evidence": [
              { "side": String("unconfirmed"), .. },
              { "side": String("unconfirmed"), .. },
            ],
            ..
          },
          ..
        },
        ..
      },
      ..
    },
  )
}

///|
test "late exit exhaustion preserves a pending entry and every health motion and segment watermark" {
  let initial = @codec.EvidenceGuardedTransitReplay::open(
    guarded_transit_test_source(),
  )
  for
    frame in [
      guarded_test_frame(0L, 100.0),
      guarded_test_frame(100000L, 100.0),
      guarded_test_frame(200000L, 140.0),
    ] {
    ignore(initial.process_line(frame))
  }
  let value = @json.parse(initial.checkpoint_json())
  guard value
    is {
      "analysis": {
        "transit": {
          "counting": { "state": { "counts": Array(counts), .. }, .. },
          ..
        },
        ..
      },
      ..
    } else {
    fail("gate totals missing")
  }
  let mut found = false
  for count in counts {
    if count is Object(fields) && fields.get("gate_id") is Some(String("exit")) {
      fields["positive_to_negative"] = Json("9223372036854775807")
      found = true
    }
  }
  assert_true(found)
  let saved = value.stringify()
  let replay = @codec.EvidenceGuardedTransitReplay::open(
    "{\"resume\":" + saved + "}",
  )
  let raw =
    #|{"timestamp_us":"300000","observations":[{"track_id":7,"point":[180,200]},{"track_id":8,"point":[100,200]}]}
  let paired = (text : String) => {
    Json::object({
      "measurement": Json(text),
      "health": Json(health_test_frame(300000L)),
    }).stringify()
  }
  try replay.process_line(paired(raw)) catch {
    _ => ()
  } noraise {
    _ => fail("exhausted exit accepted")
  }
  assert_eq(replay.checkpoint_json(), saved)
  assert_true(
    @json.parse(
      replay.process_line(paired(raw.replace(old="[180,200]", new="[145,200]"))),
    )
    is {
      "analysis": {
        "measurement": {
          "tracks": [
            _,
            { "track_id": Number(8, ..), "segment_id": String("2"), .. },
          ],
          ..
        },
        "transit": { "pending_count": Number(1, ..), .. },
        ..
      },
      ..
    },
  )
}

///|
test "projection replacement cancels a real pending entry and restores cold bound transit recovery" {
  let replay = @codec.EvidenceGuardedTransitReplay::open(
    guarded_transit_test_source(),
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
      "kind": String("evidence_guarded_transit_projection_replaced"),
      "decision": String("blocked"),
      "health": { "status": String("insufficient"), .. },
      "analysis": {
        "measurement": { "tracks": [], "closed_segment_ids": [String("1")], .. },
        "transit": {
          "pending_count": Number(0, ..),
          "cancellations": [{ "reason": String("discontinuity"), .. }],
          "counts": [{ "completed": String("0"), .. }],
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
        "transit": {
          "counting": {
            "configuration": { "sigma_multiplier": Number(2, ..), .. },
            ..
          },
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
  let restored = @codec.EvidenceGuardedTransitReplay::open(
    "{\"resume\":" + saved + "}",
  )
  for
    frame in [
      projection_test_frame(300000L, 50.0),
      projection_test_frame(400000L, 70.0),
      projection_test_frame(500000L, 100.0),
    ] {
    let expected = replay.process_line(frame)
    assert_eq(restored.process_line(frame), expected)
    assert_true(
      @json.parse(expected)
      is { "analysis": { "transit": { "passages": [], .. }, .. }, .. },
    )
  }
  assert_eq(restored.checkpoint_json(), replay.checkpoint_json())
}

///|
test "guarded transit restores both whole and component checkpoints at every health and projection cut" {
  let frames = [
    guarded_test_frame(0L, 100.0),
    guarded_test_frame(100000L, 100.0),
    guarded_test_frame(200000L, 140.0),
    projection_test_control(250000L),
    projection_test_frame(300000L, 50.0),
    projection_test_frame(400000L, 70.0),
    projection_test_frame(500000L, 100.0),
  ]
  for cut in 0..<=frames.length() {
    let original = @codec.EvidenceGuardedTransitReplay::open(
      guarded_transit_test_source(),
    )
    for i in 0..<cut {
      ignore(original.process_line(frames[i]))
    }
    let saved = original.checkpoint_json()
    let whole = @codec.EvidenceGuardedTransitReplay::open(
      "{\"resume\":" + saved + "}",
    )
    guard @json.parse(saved) is { "analysis": analysis, "health": health, .. } else {
      fail("complete state missing")
    }
    let split = @codec.EvidenceGuardedTransitReplay::open(
      Json::object({
        "analysis": Json("{\"resume\":" + analysis.stringify() + "}"),
        "health": Json("{\"resume\":" + health.stringify() + "}"),
      }).stringify(),
    )
    assert_eq(whole.checkpoint_json(), saved)
    assert_eq(split.checkpoint_json(), saved)
    for i in cut..<frames.length() {
      let expected = original.process_line(frames[i])
      assert_eq(whole.process_line(frames[i]), expected)
      assert_eq(split.process_line(frames[i]), expected)
    }
    assert_eq(whole.checkpoint_json(), original.checkpoint_json())
    assert_eq(split.checkpoint_json(), original.checkpoint_json())
  }
}

///|
test "guarded transit raw invalid data cannot advance health even while blocked" {
  let replay = @codec.EvidenceGuardedTransitReplay::open(
    guarded_transit_test_source(),
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
    let raw = Json::object({
      "measurement": Json(measurement),
      "health": Json(health_test_frame(100000L, shift=50.0)),
    }).stringify()
    try replay.process_line(raw) catch {
      _ => ()
    } noraise {
      _ => fail("invalid blocked observation accepted")
    }
    assert_eq(replay.checkpoint_json(), saved)
  }
  let mismatched = Json::object({
    "measurement": Json(good),
    "health": Json(health_test_frame(100001L)),
  }).stringify()
  try replay.process_line(mismatched) catch {
    _ => ()
  } noraise {
    _ => fail("mismatched frame times accepted")
  }
  assert_eq(replay.checkpoint_json(), saved)
}

///|
test "complete guarded transit rejects mismatched health and legacy checkpoint policies" {
  let replay = @codec.EvidenceGuardedTransitReplay::open(
    guarded_transit_test_source(),
  )
  ignore(replay.process_line(guarded_test_frame(0L, 100.0)))
  ignore(replay.process_line(guarded_test_frame(100000L, 100.0)))
  let saved = replay.checkpoint_json()
  let value = @json.parse(saved)
  guard value is { "health": health, .. } &&
    health is { "state": Object(state), .. } else {
    fail("health state missing")
  }
  state["last_timestamp_us"] = Json("100001")
  ignore(@codec.HealthReplay::open("{\"resume\":" + health.stringify() + "}"))
  try
    @codec.EvidenceGuardedTransitReplay::open(
      "{\"resume\":" + value.stringify() + "}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("health watermark mismatch accepted")
  }
  let old = @codec.EvidenceGuardedReplay::open(evidence_guarded_test_source()).checkpoint_json()
  try
    @codec.EvidenceGuardedTransitReplay::open("{\"resume\":" + old + "}")
  catch {
    _ => ()
  } noraise {
    _ => fail("legacy counter checkpoint lost its policy")
  }
  try @codec.EvidenceGuardedReplay::open("{\"resume\":" + saved + "}") catch {
    _ => ()
  } noraise {
    _ => fail("old owner accepted transit checkpoint")
  }
}

///|
test "pure guarded transit preserves CRLF EOF empty replay and failed-batch atomicity" {
  let request = (observations : String) => {
    Json::object({
      "source": Json(guarded_transit_test_source()),
      "observations": Json(observations),
    }).stringify()
  }
  let frames = [
    guarded_test_frame(0L, 100.0),
    guarded_test_frame(100000L, 100.0),
    guarded_test_frame(200000L, 140.0),
  ]
  let expected = @codec.evidence_guarded_transit_json(
    request(frames.join("\n")),
  )
  assert_eq(
    @codec.evidence_guarded_transit_json(request(frames.join("\r\n") + "\r\n")),
    expected,
  )
  assert_true(
    @json.parse(expected)
    is {
      "frames": [_, _, _],
      "checkpoint": {
        "format": String("moonground.evidence-guarded-transit"),
        ..
      },
      ..
    },
  )
  assert_true(
    @json.parse(@codec.evidence_guarded_transit_json(request("")))
    is { "frames": [], .. },
  )
  for text in [frames.join("\n") + "\n{}", frames.join("\n") + "\n\n"] {
    try @codec.evidence_guarded_transit_json(request(text)) catch {
      _ => ()
    } noraise {
      _ => fail("bad batch exposed a prefix")
    }
  }
}

///|
test "instant health re-confirmation gap restores a reachable continuing transit but rejects an impossible known time" {
  let value = @json.parse(guarded_transit_test_source())
  guard value is Object(source) &&
    source.get("health") is Some(String(raw)) &&
    @json.parse(raw) is Object(config) &&
    config.get("health") is Some(Object(policy)) else {
    fail("health policy missing")
  }
  policy["min_observations"] = Json(1)
  policy["confirmation_us"] = Json("0")
  policy["max_gap_us"] = Json("100000")
  source["health"] = Json(Json::object(config).stringify())
  let replay = @codec.EvidenceGuardedTransitReplay::open(
    Json::object(source).stringify(),
  )
  ignore(replay.process_line(guarded_test_frame(0L, 100.0)))
  assert_true(
    @json.parse(replay.process_line(guarded_test_frame(100000L, 140.0)))
    is {
      "decision": String("allowed"),
      "analysis": { "transit": { "pending_count": Number(1, ..), .. }, .. },
      ..
    },
  )
  let saved = replay.checkpoint_json()
  assert_eq(
    @codec.EvidenceGuardedTransitReplay::open("{\"resume\":" + saved + "}").checkpoint_json(),
    saved,
  )
  let impossible = @json.parse(saved)
  guard impossible is { "analysis": analysis, .. } &&
    analysis
    is {
      "measurement": { "motion": { "tracks": [Object(track)], .. }, .. },
      "transit": { "pending": [{ "entry": Object(entry), .. }], .. },
      ..
    } else {
    fail("pending state missing")
  }
  track["first_timestamp_us"] = Json("99999")
  entry["from_timestamp_us"] = Json("99999")
  ignore(
    @codec.EvidenceTransitAnalysisReplay::open(
      "{\"resume\":" + analysis.stringify() + "}",
    ),
  )
  try
    @codec.EvidenceGuardedTransitReplay::open(
      "{\"resume\":" + impossible.stringify() + "}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("observation inside required health gap accepted")
  }
}
