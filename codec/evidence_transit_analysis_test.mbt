///|
fn transit_analysis_test_measurement() -> String {
  (
    #|{"session_id":"joint-transit","mode":"ground","diagnostics":true,"motion":{"gate":1000000000000,"initial_velocity_std":20}}
  )
}

///|
fn transit_analysis_test_transit(exit_x~ : Double = 2.0) -> String {
  let gate = (id : String, x : Double) => {
    Json::object({
      "gate_id": Json(id),
      "start_m": Json([x, -10.0]),
      "end_m": Json([x, 10.0]),
    })
  }
  let counting = Json::object({
    "session_id": Json("joint-transit"),
    "gates": Json([gate("exit", exit_x), gate("entry", 0.0)]),
  }).stringify()
  Json::object({
    "counting": Json(
      Json::object({ "counting": Json(counting), "sigma_multiplier": Json(2.0) }).stringify(),
    ),
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
}

///|
fn transit_analysis_test_source(exit_x~ : Double = 2.0) -> String {
  Json::object({
    "measurement": Json(transit_analysis_test_measurement()),
    "transit": Json(transit_analysis_test_transit(exit_x~)),
  }).stringify()
}

///|
fn transit_analysis_test_frame(time : Int64, x : Double) -> String {
  Json::object({
    "timestamp_us": Json(time.to_string()),
    "observations": Json([
      Json::object({
        "track_id": Json(1),
        "point": Json([x, 0.0]),
        "covariance": Json([0.01, 0.0, 1.0]),
      }),
    ]),
  }).stringify()
}

///|
test "joint transit output and complete state match the original component chain at exact large clocks" {
  let joined = @codec.EvidenceTransitAnalysisReplay::open(
    transit_analysis_test_source(),
  )
  let motion = @codec.ReplaySession::open(transit_analysis_test_measurement())
  let transit = @codec.EvidenceTransitReplay::open(
    transit_analysis_test_transit(),
  )
  let base = 9007199254740993L
  for index, x in [-1.0, 1.0, 3.0] {
    let raw = transit_analysis_test_frame(base + index.to_int64() * 100000L, x)
    let measured = motion.process_line(raw)
    let counted = transit.process_line(measured)
    assert_eq(
      @json.parse(joined.process_line(raw)),
      Json::object({
        "schema_version": Json("0.1.0"),
        "kind": Json("evidence_transit_analysis_frame"),
        "measurement": @json.parse(measured),
        "transit": @json.parse(counted),
      }),
    )
    if index == 1 {
      assert_true(
        @json.parse(counted) is { "pending_count": Number(1, ..), .. },
      )
    }
    if index == 2 {
      assert_true(@json.parse(counted) is { "passages": [_], .. })
    }
  }
  assert_true(
    @json.parse(joined.checkpoint_json())
    is {
      "format": String("moonground.evidence-transit-analysis"),
      "checkpoint_version": String("1"),
      ..
    },
  )
  guard @json.parse(joined.checkpoint_json())
    is { "measurement": measured, "transit": counted, .. } else {
    fail("complete state missing")
  }
  assert_eq(measured, @json.parse(motion.checkpoint_json()))
  assert_eq(counted, @json.parse(transit.checkpoint_json()))
}

///|
test "joint transit resumes both complete checkpoints and two original components at every cut" {
  let frames = [
    transit_analysis_test_frame(0L, -1.0),
    transit_analysis_test_frame(100000L, 1.0),
    transit_analysis_test_frame(200000L, 3.0),
  ]
  for cut in 0..<=frames.length() {
    let original = @codec.EvidenceTransitAnalysisReplay::open(
      transit_analysis_test_source(),
    )
    for i in 0..<cut {
      ignore(original.process_line(frames[i]))
    }
    let saved = original.checkpoint_json()
    let full = @codec.EvidenceTransitAnalysisReplay::open(
      "{\"resume\":" + saved + "}",
    )
    guard @json.parse(saved)
      is { "measurement": measured, "transit": counted, .. } else {
      fail("complete state missing")
    }
    let split = @codec.EvidenceTransitAnalysisReplay::open(
      Json::object({
        "measurement": Json("{\"resume\":" + measured.stringify() + "}"),
        "transit": Json("{\"resume\":" + counted.stringify() + "}"),
      }).stringify(),
    )
    assert_eq(full.checkpoint_json(), saved)
    assert_eq(split.checkpoint_json(), saved)
    for i in cut..<frames.length() {
      let expected = original.process_line(frames[i])
      assert_eq(full.process_line(frames[i]), expected)
      assert_eq(split.process_line(frames[i]), expected)
    }
    assert_eq(full.checkpoint_json(), original.checkpoint_json())
    assert_eq(split.checkpoint_json(), original.checkpoint_json())
  }
}

///|
test "late transit exhaustion preserves motion covariance path and allocated segment for same-time retry" {
  let initial = @codec.EvidenceTransitAnalysisReplay::open(
    transit_analysis_test_source(),
  )
  ignore(initial.process_line(transit_analysis_test_frame(0L, -1.0)))
  let value = @json.parse(initial.checkpoint_json())
  guard value
    is {
      "transit": {
        "counting": { "state": { "counts": Array(counts), .. }, .. },
        ..
      },
      ..
    } else {
    fail("gate totals missing")
  }
  let mut found = false
  for count in counts {
    if count is Object(fields) && fields.get("gate_id") is Some(String("entry")) {
      fields["positive_to_negative"] = Json("9223372036854775807")
      found = true
    }
  }
  assert_true(found)
  let saved = value.stringify()
  let replay = @codec.EvidenceTransitAnalysisReplay::open(
    "{\"resume\":" + saved + "}",
  )
  let raw =
    #|{"timestamp_us":"100000","observations":[{"track_id":1,"point":[1,0],"covariance":[0.01,0,1]},{"track_id":2,"point":[-2,0],"covariance":[0.01,0,1]}]}
  try replay.process_line(raw) catch {
    _ => ()
  } noraise {
    _ => fail("exhausted gate accepted")
  }
  assert_eq(replay.checkpoint_json(), saved)
  assert_true(
    @json.parse(
      replay.process_line(
        raw.replace(old="\"point\":[1,0]", new="\"point\":[-0.5,0]"),
      ),
    )
    is {
      "measurement": {
        "timestamp_us": String("100000"),
        "tracks": [
          _,
          { "track_id": Number(2, ..), "segment_id": String("2"), .. },
        ],
        ..
      },
      "transit": { "pending_count": Number(0, ..), .. },
      ..
    },
  )
}

///|
test "individually valid components cannot restore a pending entry before its motion segment" {
  let original = @codec.EvidenceTransitAnalysisReplay::open(
    transit_analysis_test_source(),
  )
  ignore(original.process_line(transit_analysis_test_frame(0L, -1.0)))
  ignore(original.process_line(transit_analysis_test_frame(100000L, 1.0)))
  let value = @json.parse(original.checkpoint_json())
  guard value is { "measurement": measured, "transit": counted, .. } &&
    measured is { "motion": { "tracks": [Object(track)], .. }, .. } else {
    fail("pending state missing")
  }
  track["first_timestamp_us"] = Json("1")
  ignore(
    @codec.ReplaySession::open("{\"resume\":" + measured.stringify() + "}"),
  )
  ignore(
    @codec.EvidenceTransitReplay::open(
      "{\"resume\":" + counted.stringify() + "}",
    ),
  )
  try
    @codec.EvidenceTransitAnalysisReplay::open(
      "{\"resume\":" + value.stringify() + "}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("entry before segment accepted")
  }
}

///|
test "joint transit rejects conflicting historical covariance witnesses across different gates" {
  let original = @codec.EvidenceTransitAnalysisReplay::open(
    transit_analysis_test_source(exit_x=1.0),
  )
  ignore(original.process_line(transit_analysis_test_frame(0L, -1.0)))
  ignore(original.process_line(transit_analysis_test_frame(100000L, 1.0)))
  let value = @json.parse(original.checkpoint_json())
  guard value is { "transit": counted, .. } &&
    counted is { "pending": [Object(pending)], .. } else {
    fail("pending state missing")
  }
  pending["from_covariance"] = Json([0.02, 0.0, 1.0])
  ignore(
    @codec.EvidenceTransitReplay::open(
      "{\"resume\":" + counted.stringify() + "}",
    ),
  )
  try
    @codec.EvidenceTransitAnalysisReplay::open(
      "{\"resume\":" + value.stringify() + "}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("contradictory same-time evidence accepted")
  }
}

///|
test "raw transit analysis integer duplicate unknown and covariance errors preserve complete state" {
  let replay = @codec.EvidenceTransitAnalysisReplay::open(
    transit_analysis_test_source(),
  )
  ignore(replay.process_line(transit_analysis_test_frame(0L, -1.0)))
  let saved = replay.checkpoint_json()
  let good = transit_analysis_test_frame(100000L, 1.0)
  for
    raw in [
      "{}",
      good.replace(
        old="\"track_id\":1",
        new="\"track_id\":1.000000000000000001",
      ),
      good.replace(old="\"track_id\":1", new="\"track_id\":1,\"track_id\":1"),
      good.replace(old="\"track_id\":1", new="\"track_id\":1,\"extra\":0"),
      good.replace(
        old="\"covariance\":[0.01,0,1]",
        new="\"covariance\":[0.01,2,1]",
      ),
    ] {
    try replay.process_line(raw) catch {
      _ => ()
    } noraise {
      _ => fail("invalid observation accepted")
    }
    assert_eq(replay.checkpoint_json(), saved)
  }
  ignore(replay.process_line(good))
}

///|
test "pure transit analysis accepts CRLF EOF and empty input but exposes no failed batch prefix" {
  let request = (text : String) => {
    Json::object({
      "source": Json(transit_analysis_test_source()),
      "observations": Json(text),
    }).stringify()
  }
  let frames = [
    transit_analysis_test_frame(0L, -1.0),
    transit_analysis_test_frame(100000L, 1.0),
    transit_analysis_test_frame(200000L, 3.0),
  ]
  let expected = @codec.evidence_transit_analysis_json(
    request(frames.join("\n")),
  )
  assert_eq(
    @codec.evidence_transit_analysis_json(request(frames.join("\r\n") + "\r\n")),
    expected,
  )
  assert_true(
    @json.parse(expected)
    is {
      "frames": [_, _, _],
      "checkpoint": {
        "format": String("moonground.evidence-transit-analysis"),
        ..
      },
      ..
    },
  )
  assert_true(
    @json.parse(@codec.evidence_transit_analysis_json(request("")))
    is { "frames": [], .. },
  )
  for text in [frames.join("\n") + "\n{}", frames.join("\n") + "\n\n"] {
    try @codec.evidence_transit_analysis_json(request(text)) catch {
      _ => ()
    } noraise {
      _ => fail("failed batch exposed prefix")
    }
  }
}
