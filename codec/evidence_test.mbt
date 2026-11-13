///|
fn evidence_test_counting() -> String {
  (
    #|{"session_id":"evidence-test","gates":[{"gate_id":"aisle","start_m":[0,-2],"end_m":[0,2],"deadband_m":0.05}],"max_tracks":2}
  )
}

///|
fn evidence_test_source(k~ : Double = 2.0) -> String {
  Json::object({
    "counting": Json(evidence_test_counting()),
    "sigma_multiplier": Json(k),
  }).stringify()
}

///|
fn evidence_test_frame(
  time : Int64,
  x : Double,
  normal_variance~ : Double = 0.01,
) -> String {
  Json::object({
    "schema_version": Json("0.2.0"),
    "uncertainty_scope": Json(
      "conditional_on_fixed_calibration_camera_and_anchor",
    ),
    "session_id": Json("evidence-test"),
    "timestamp_us": Json(time.to_string()),
    "closed_segment_ids": Json::array([]),
    "tracks": Json([
      Json::object({
        "track_id": Json(7),
        "segment_id": Json("1"),
        "status": Json("initializing"),
        "position_m": Json([x, 0.0]),
        "position_covariance": Json([
          normal_variance,
          0.0,
          if normal_variance == 0.01 {
            100.0
          } else {
            0.01
          },
        ]),
        "position_std_m": Json(10.0),
        "velocity_mps": Json::null(),
        "velocity_covariance": Json::null(),
        "velocity_std_mps": Json::null(),
        "speed_mps": Json::null(),
        "observed_path_length_m": Json(0.0),
        "net_displacement_m": Json(0.0),
        "accepted_count": Json(1),
        "last_accepted_timestamp_us": Json(time.to_string()),
      }),
    ]),
  }).stringify()
}

///|
test "evidence delays a normal-uncertain crossing but retains the original covariance anchor" {
  let replay = @codec.EvidenceGateReplay::open(evidence_test_source())
  let first = evidence_test_frame(9007199254740993L, -1.0)
  assert_true(
    @json.parse(replay.process_line(first))
    is {
      "kind": String("gate_evidence_frame"),
      "evidence": [
        { "normal_std_m": Number(0.1, ..), "side": String("positive"), .. },
      ],
      ..
    },
  )
  let uncertain = evidence_test_frame(
    9007199254840993L,
    1.0,
    normal_variance=100.0,
  )
  assert_true(
    @json.parse(replay.process_line(uncertain))
    is {
      "counting": {
        "crossings": [],
        "counts": [{ "positive_to_negative": String("0"), .. }],
        ..
      },
      "evidence": [
        { "normal_std_m": Number(10, ..), "side": String("unconfirmed"), .. },
      ],
      ..
    },
  )
  let saved = replay.checkpoint_json()
  assert_true(
    @json.parse(saved)
    is {
      "format": String("moonground.gate-evidence"),
      "state": {
        "tracks": [
          {
            "anchors": [
              {
                "timestamp_us": String("9007199254740993"),
                "covariance": [Number(0.01, ..), Number(0, ..), Number(100, ..)],
                ..
              },
            ],
            ..
          },
        ],
        ..
      },
      ..
    },
  )
  let restored = @codec.EvidenceGateReplay::open("{\"resume\":" + saved + "}")
  let last = evidence_test_frame(9007199254940993L, 1.0)
  let output = replay.process_line(last)
  assert_eq(restored.process_line(last), output)
  assert_true(
    @json.parse(output)
    is {
      "counting": {
        "crossings": [
          {
            "from_timestamp_us": String("9007199254740993"),
            "to_timestamp_us": String("9007199254940993"),
            ..
          },
        ],
        ..
      },
      ..
    },
  )
}

///|
test "zero multiplier counts the same filtered mean chords as the legacy counter" {
  let replay = @codec.EvidenceGateReplay::open(evidence_test_source(k=0.0))
  let legacy = @codec.GateReplay::open(evidence_test_counting())
  for
    source in [
      evidence_test_frame(0L, -1.0),
      evidence_test_frame(100000L, 1.0, normal_variance=100.0),
      evidence_test_frame(200000L, -1.0),
    ] {
    guard @json.parse(replay.process_line(source))
      is { "counting": counting, "evidence": [_], .. } else {
      fail("evidence or counting output missing")
    }
    assert_eq(counting.stringify(), legacy.process_line(source))
  }
}

///|
test "invalid raw covariance or identity leaves covariance anchors and exact time reusable" {
  let replay = @codec.EvidenceGateReplay::open(evidence_test_source())
  ignore(replay.process_line(evidence_test_frame(0L, -1.0)))
  let saved = replay.checkpoint_json()
  let valid = evidence_test_frame(100000L, 1.0)
  for
    source in [
      "{}",
      evidence_test_frame(0L, 1.0),
      valid.replace(
        old="\"track_id\":7",
        new="\"track_id\":7.0000000000000000001",
      ),
      valid.replace(old="\"track_id\":7", new="\"track_id\":7,\"track_id\":7"),
      valid.replace(
        old="\"position_covariance\":[0.01,0,100]",
        new="\"position_covariance\":[0.01,2,0.01]",
      ),
      valid.replace(old="\"track_id\":7", new="\"track_id\":7,\"unknown\":0"),
    ] {
    try replay.process_line(source) catch {
      _ => ()
    } noraise {
      _ => fail("bad gate evidence measurement accepted")
    }
    assert_eq(replay.checkpoint_json(), saved)
  }
  assert_true(
    @json.parse(replay.process_line(valid))
    is { "counting": { "crossings": [_], .. }, .. },
  )
}

///|
test "evidence checkpoint refuses missing or no-longer-stable covariance and legacy snapshots" {
  let replay = @codec.EvidenceGateReplay::open(evidence_test_source())
  ignore(replay.process_line(evidence_test_frame(0L, -1.0)))
  let saved = replay.checkpoint_json()
  let legacy = @codec.GateReplay::open(evidence_test_counting()).checkpoint_json()
  for
    source in [
      "{\"resume\":" + legacy + "}",
      "{\"resume\":" +
      saved.replace(old="\"max_gap_us\"", new="\"missing_gap\"") +
      "}",
      "{\"resume\":" +
      saved.replace(old="\"max_tracks\"", new="\"missing_capacity\"") +
      "}",
      "{\"resume\":" +
      saved.replace(old="\"deadband_m\"", new="\"missing_deadband\"") +
      "}",
      "{\"resume\":" +
      saved.replace(
        old="\"covariance\":[0.01,0,100]",
        new="\"covariance\":[100,0,0.01]",
      ) +
      "}",
      "{\"resume\":" +
      saved.replace(
        old="\"covariance\":[0.01,0,100]",
        new="\"ignored\":[0.01,0,100]",
      ) +
      "}",
      Json::object({
        "counting": Json("{\"resume\":" + legacy + "}"),
        "sigma_multiplier": Json(2),
      }).stringify(),
    ] {
    try @codec.EvidenceGateReplay::open(source) catch {
      _ => ()
    } noraise {
      _ => fail("invalid evidence checkpoint accepted")
    }
  }
  try @codec.GateReplay::open("{\"resume\":" + saved + "}") catch {
    _ => ()
  } noraise {
    _ => fail("legacy restore silently lost covariance evidence")
  }
}

///|
test "evidence counter overflow rolls back the same frame before an unconfirmed retry" {
  let replay = @codec.EvidenceGateReplay::open(evidence_test_source())
  ignore(replay.process_line(evidence_test_frame(0L, -1.0)))
  let saved = replay
    .checkpoint_json()
    .replace(
      old="\"positive_to_negative\":\"0\"",
      new="\"positive_to_negative\":\"9223372036854775807\"",
    )
  let restored = @codec.EvidenceGateReplay::open("{\"resume\":" + saved + "}")
  try restored.process_line(evidence_test_frame(100000L, 1.0)) catch {
    _ => ()
  } noraise {
    _ => fail("exhausted evidence counter accepted")
  }
  assert_eq(restored.checkpoint_json(), saved)
  assert_true(
    @json.parse(
      restored.process_line(
        evidence_test_frame(100000L, 1.0, normal_variance=100.0),
      ),
    )
    is {
      "counting": { "timestamp_us": String("100000"), "crossings": [], .. },
      ..
    },
  )
}

///|
test "pure evidence batch preserves CRLF EOF semantics and rejects later failures without a prefix" {
  let frames = [
    evidence_test_frame(0L, -1.0),
    evidence_test_frame(100000L, 1.0, normal_variance=100.0),
    evidence_test_frame(200000L, 1.0),
  ]
  let request = (measurements : String) => {
    Json::object({
      "source": Json(evidence_test_source()),
      "measurements": Json(measurements),
    }).stringify()
  }
  let expected = @codec.gate_evidence_json(request(frames.join("\n")))
  assert_eq(
    expected,
    @codec.gate_evidence_json(request(frames.join("\r\n") + "\r\n")),
  )
  assert_true(
    @json.parse(expected)
    is {
      "frames": [_, _, _],
      "checkpoint": { "format": String("moonground.gate-evidence"), .. },
      ..
    },
  )
  for text in [frames.join("\n") + "\n{}", frames.join("\n") + "\n\n"] {
    try @codec.gate_evidence_json(request(text)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid later evidence frame accepted")
    }
  }
}
