///|
fn gate_test_configuration() -> String {
  "{\"session_id\":\"gate-test\",\"gates\":[{\"gate_id\":\"entry\",\"start_m\":[0,-10],\"end_m\":[0,10],\"deadband_m\":0.05}]}"
}

///|
fn gate_test_measurements() -> Array[String] raise @types.GroundError {
  let session = @codec.ReplaySession::new(
    "{\"session_id\":\"gate-test\",\"mode\":\"ground\",\"diagnostics\":true,\"motion\":{\"gate\":1000000,\"initial_velocity_std\":20}}",
  )
  [
    session.process_line(
      "{\"timestamp_us\":\"9007199254740993\",\"observations\":[{\"track_id\":1,\"point\":[-1,0]}]}",
    ),
    session.process_line(
      "{\"timestamp_us\":\"9007199254840993\",\"observations\":[{\"track_id\":1,\"point\":[1,0]}]}",
    ),
    session.process_line(
      "{\"timestamp_us\":\"9007199254940993\",\"observations\":[{\"track_id\":1,\"point\":[-1,0]}]}",
    ),
  ]
}

///|
test "gate replay consumes actual diagnostic measurements with exact Int64 brackets" {
  let replay = @codec.GateReplay::open(gate_test_configuration())
  let frames = gate_test_measurements()
  ignore(replay.process_line(frames[0]))
  let counted = @json.parse(replay.process_line(frames[1]))
  assert_true(
    counted
    is {
      "schema_version": String("0.1.0"),
      "kind": String("gate_events"),
      "crossings": [
        {
          "direction": String("positive_to_negative"),
          "from_timestamp_us": String("9007199254740993"),
          "to_timestamp_us": String("9007199254840993"),
          ..
        },
      ],
      "counts": [
        {
          "gate_id": String("entry"),
          "negative_to_positive": String("0"),
          "positive_to_negative": String("1"),
          ..
        },
      ],
      ..
    },
  )
}

///|
test "gate checkpoint resumes exact counts and stable anchors independently" {
  let frames = gate_test_measurements()
  let replay = @codec.GateReplay::open(gate_test_configuration())
  ignore(replay.process_line(frames[0]))
  let saved = replay.checkpoint_json()
  let restored = @codec.GateReplay::open("{\"resume\":" + saved + "}")
  for i in 1..<frames.length() {
    assert_eq(restored.process_line(frames[i]), replay.process_line(frames[i]))
  }
  assert_eq(restored.checkpoint_json(), replay.checkpoint_json())
  let untouched = @codec.GateReplay::open("{\"resume\":" + saved + "}")
  assert_eq(untouched.checkpoint_json(), saved)
}

///|
test "invalid gate measurement leaves the same frame and checkpoint reusable" {
  let frames = gate_test_measurements()
  let replay = @codec.GateReplay::open(gate_test_configuration())
  ignore(replay.process_line(frames[0]))
  let before = replay.checkpoint_json()
  let malformed = @json.parse(frames[1])
  guard malformed is Object(fields) else { fail("frame object missing") }
  fields["ignored"] = Json(true)
  for source in [frames[0], malformed.stringify(), "{}"] {
    try replay.process_line(source) catch {
      _ => ()
    } noraise {
      _ => fail("bad gate measurement was accepted")
    }
    assert_eq(replay.checkpoint_json(), before)
  }
  assert_true(
    @json.parse(replay.process_line(frames[1])) is { "crossings": [_], .. },
  )
}

///|
test "gate configuration rejects unknown duplicate degenerate and oversized declarations" {
  for
    source in [
      "{\"session_id\":\"x\",\"gates\":[]}", "{\"session_id\":\"x\",\"gates\":[{\"gate_id\":\"a\",\"start_m\":[0,0],\"end_m\":[0,0]}]}",
      "{\"session_id\":\"x\",\"gates\":[{\"gate_id\":\"a\",\"start_m\":[0,0],\"end_m\":[0,1]}],\"max_tracks\":1.0000000000000000001}",
      "{\"session_id\":\"x\",\"session_id\":\"y\",\"gates\":[]}", "{\"session_id\":\"x\",\"gates\":[],\"rotation\":90}",
    ] {
    try @codec.GateReplay::open(source) catch {
      _ => ()
    } noraise {
      _ => fail("invalid gate configuration accepted")
    }
  }
}

///|
test "pure gate bundle preserves raw text and fails without partial output" {
  let measurements = gate_test_measurements()
  let bundle = (measurements : String) => {
    Json::object({
      "source": Json(gate_test_configuration()),
      "measurements": Json(measurements),
    }).stringify()
  }
  let result = @json.parse(@codec.gates_json(bundle(measurements.join("\r\n"))))
  assert_true(
    result
    is {
      "frames": [_, _, _],
      "checkpoint": { "format": String("moonground.gates"), .. },
      ..
    },
  )
  for
    text in [
      measurements.join("\n") + "\n{}\n",
      measurements.join("\n") + "\n\n",
    ] {
    try @codec.gates_json(bundle(text)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid later frame accepted")
    }
  }
  assert_true(
    @json.parse(@codec.gates_json(bundle(""))) is { "frames": [], .. },
  )
}
