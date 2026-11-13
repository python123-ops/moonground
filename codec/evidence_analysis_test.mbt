///|
fn evidence_analysis_test_measurement() -> String {
  (
    #|{"session_id":"evidence-joint","mode":"ground","diagnostics":true,"motion":{"gate":1000000000000,"initial_velocity_std":20}}
  )
}

///|
fn evidence_analysis_test_counting(k~ : Double = 2.0) -> String {
  let raw =
    #|{"session_id":"evidence-joint","gates":[{"gate_id":"aisle","start_m":[0,-2],"end_m":[0,2]}]}
  Json::object({ "counting": Json(raw), "sigma_multiplier": Json(k) }).stringify()
}

///|
fn evidence_analysis_test_source(k~ : Double = 2.0) -> String {
  Json::object({
    "measurement": Json(evidence_analysis_test_measurement()),
    "counting": Json(evidence_analysis_test_counting(k~)),
  }).stringify()
}

///|
fn evidence_analysis_test_frame(time : Int64, x : Double) -> String {
  Json::object({
    "timestamp_us": Json(time.to_string()),
    "observations": Json([
      Json::object({
        "track_id": Json(1),
        "point": Json([x, 0.0]),
        "covariance": Json([0.01, 0.0, 100.0]),
      }),
    ]),
  }).stringify()
}

///|
test "evidence analysis matches original measurement and downstream evidence without losing either checkpoint" {
  let joined = @codec.EvidenceAnalysisReplay::open(
    evidence_analysis_test_source(),
  )
  let measurement = @codec.ReplaySession::open(
    evidence_analysis_test_measurement(),
  )
  let counting = @codec.EvidenceGateReplay::open(
    evidence_analysis_test_counting(),
  )
  for (time, x) in [(9007199254740993L, -1.0), (9007199254840993L, 1.0)] {
    let source = evidence_analysis_test_frame(time, x)
    let measured = measurement.process_line(source)
    let counted = counting.process_line(measured)
    assert_eq(
      @json.parse(joined.process_line(source)),
      Json::object({
        "schema_version": Json("0.1.0"),
        "kind": Json("evidence_analysis_frame"),
        "measurement": @json.parse(measured),
        "counting": @json.parse(counted),
      }),
    )
  }
  let saved = joined.checkpoint_json()
  guard @json.parse(saved)
    is { "measurement": measured, "counting": counted, .. } else {
    fail("complete joint checkpoint missing")
  }
  assert_eq(measured, @json.parse(measurement.checkpoint_json()))
  assert_eq(counted, @json.parse(counting.checkpoint_json()))
  let restored = @codec.EvidenceAnalysisReplay::open(
    "{\"resume\":" + saved + "}",
  )
  let next = evidence_analysis_test_frame(9007199254940993L, -1.0)
  assert_eq(restored.process_line(next), joined.process_line(next))
  assert_eq(restored.checkpoint_json(), joined.checkpoint_json())
}

///|
test "joint evidence count exhaustion preserves measurement state time and segment allocation for retry" {
  let initial = @codec.EvidenceAnalysisReplay::open(
    evidence_analysis_test_source(),
  )
  ignore(initial.process_line(evidence_analysis_test_frame(0L, -1.0)))
  let saved = initial
    .checkpoint_json()
    .replace(
      old="\"positive_to_negative\":\"0\"",
      new="\"positive_to_negative\":\"9223372036854775807\"",
    )
  let replay = @codec.EvidenceAnalysisReplay::open("{\"resume\":" + saved + "}")
  let failed =
    #|{"timestamp_us":"100000","observations":[{"track_id":1,"point":[1,0],"covariance":[0.01,0,100]},{"track_id":2,"point":[-2,0]}]}
  try replay.process_line(failed) catch {
    _ => ()
  } noraise {
    _ => fail("exhausted evidence count accepted")
  }
  assert_eq(replay.checkpoint_json(), saved)
  let retry = failed.replace(old="\"point\":[1,0]", new="\"point\":[-0.5,0]")
  assert_true(
    @json.parse(replay.process_line(retry))
    is {
      "measurement": {
        "timestamp_us": String("100000"),
        "tracks": [
          _,
          { "track_id": Number(2, ..), "segment_id": String("2"), .. },
        ],
        ..
      },
      "counting": { "counting": { "crossings": [], .. }, .. },
      ..
    },
  )
}

///|
test "joint evidence restoration rejects missing current anchors and covariance mismatches" {
  let replay = @codec.EvidenceAnalysisReplay::open(
    evidence_analysis_test_source(),
  )
  ignore(replay.process_line(evidence_analysis_test_frame(0L, -1.0)))
  let saved = replay.checkpoint_json()
  for mutation in [0, 1, 2, 3] {
    let value = @json.parse(saved)
    guard value is { "counting": { "state": Object(state), .. }, .. } else {
      fail("evidence state missing")
    }
    match mutation {
      0 => state["tracks"] = Json::array([])
      1 => state["last_timestamp_us"] = Json("1")
      _ => {
        guard state.get("tracks") is Some([{ "anchors": anchors, .. }]) &&
          anchors is Array(items) else {
          fail("anchor missing")
        }
        if mutation == 2 {
          items[0] = Json::null()
        } else {
          guard items[0] is Object(anchor) else { fail("anchor missing") }
          anchor["covariance"] = Json([0.02, 0.0, 100.0])
        }
      }
    }
    try
      @codec.EvidenceAnalysisReplay::open(
        "{\"resume\":" + value.stringify() + "}",
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("inconsistent joint evidence checkpoint accepted")
    }
  }
  try @codec.AnalysisReplay::open("{\"resume\":" + saved + "}") catch {
    _ => ()
  } noraise {
    _ => fail("legacy analysis accepted an evidence checkpoint")
  }
}

///|
test "unconfirmed current evidence may retain a historical anchor outside the mean deadband" {
  let replay = @codec.EvidenceAnalysisReplay::open(
    evidence_analysis_test_source(),
  )
  ignore(replay.process_line(evidence_analysis_test_frame(0L, -1.0)))
  assert_true(
    @json.parse(
      replay.process_line(evidence_analysis_test_frame(100000L, 0.15)),
    )
    is {
      "counting": { "evidence": [{ "side": String("unconfirmed"), .. }], .. },
      ..
    },
  )
  let saved = replay.checkpoint_json()
  assert_true(
    @json.parse(saved)
    is {
      "counting": {
        "state": {
          "tracks": [{ "anchors": [{ "timestamp_us": String("0"), .. }], .. }],
          ..
        },
        ..
      },
      ..
    },
  )
  let restored = @codec.EvidenceAnalysisReplay::open(
    "{\"resume\":" + saved + "}",
  )
  let next = evidence_analysis_test_frame(200000L, 1.0)
  assert_eq(restored.process_line(next), replay.process_line(next))
  assert_eq(restored.checkpoint_json(), replay.checkpoint_json())
}

///|
test "raw evidence analysis input errors preserve the complete checkpoint" {
  let replay = @codec.EvidenceAnalysisReplay::open(
    evidence_analysis_test_source(),
  )
  ignore(replay.process_line(evidence_analysis_test_frame(0L, -1.0)))
  let saved = replay.checkpoint_json()
  let good = evidence_analysis_test_frame(100000L, 1.0)
  for
    source in [
      "{}",
      good.replace(
        old="\"track_id\":1",
        new="\"track_id\":1.00000000000000000001",
      ),
      good.replace(old="\"track_id\":1", new="\"track_id\":1,\"track_id\":1"),
      good.replace(
        old="\"covariance\":[0.01,0,100]",
        new="\"covariance\":[0.01,2,0.01]",
      ),
    ] {
    try replay.process_line(source) catch {
      _ => ()
    } noraise {
      _ => fail("invalid raw joint observation accepted")
    }
    assert_eq(replay.checkpoint_json(), saved)
  }
  ignore(replay.process_line(good))
}

///|
test "pure evidence analysis has identical CRLF EOF semantics and returns no prefix on later errors" {
  let request = (observations : String) => {
    Json::object({
      "source": Json(evidence_analysis_test_source()),
      "observations": Json(observations),
    }).stringify()
  }
  let frames = [
    evidence_analysis_test_frame(0L, -1.0),
    evidence_analysis_test_frame(100000L, 1.0),
  ]
  let expected = @codec.evidence_analysis_json(request(frames.join("\n")))
  assert_eq(
    expected,
    @codec.evidence_analysis_json(request(frames.join("\r\n") + "\r\n")),
  )
  assert_true(
    @json.parse(expected)
    is {
      "frames": [_, _],
      "checkpoint": { "format": String("moonground.evidence-analysis"), .. },
      ..
    },
  )
  for text in [frames.join("\n") + "\n{}", frames.join("\n") + "\n\n"] {
    try @codec.evidence_analysis_json(request(text)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid later joint observation accepted")
    }
  }
}
