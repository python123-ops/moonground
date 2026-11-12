///|
fn analysis_test_measurement_source() -> String {
  "{\"session_id\":\"gate-test\",\"mode\":\"ground\",\"diagnostics\":true,\"motion\":{\"gate\":1000000,\"initial_velocity_std\":20}}"
}

///|
fn analysis_test_source() -> String {
  Json::object({
    "measurement": Json(analysis_test_measurement_source()),
    "counting": Json(gate_test_configuration()),
  }).stringify()
}

///|
fn analysis_test_observations() -> Array[String] {
  [
    "{\"timestamp_us\":\"9007199254740993\",\"observations\":[{\"track_id\":1,\"point\":[-1,0]}]}",
    "{\"timestamp_us\":\"9007199254840993\",\"observations\":[{\"track_id\":1,\"point\":[1,0]}]}",
    "{\"timestamp_us\":\"9007199254940993\",\"observations\":[{\"track_id\":1,\"point\":[-1,0]}]}",
  ]
}

///|
test "joint replay matches separate measurement and gate paths with complete checkpoints" {
  let joined = @codec.AnalysisReplay::open(analysis_test_source())
  let measurement = @codec.ReplaySession::new(
    analysis_test_measurement_source(),
  )
  let counting = @codec.GateReplay::open(gate_test_configuration())
  for source in analysis_test_observations() {
    let measured = measurement.process_line(source)
    let counted = counting.process_line(measured)
    let expected = Json::object({
      "schema_version": Json("0.1.0"),
      "kind": Json("analysis_frame"),
      "measurement": @json.parse(measured),
      "counting": @json.parse(counted),
    })
    assert_eq(@json.parse(joined.process_line(source)), expected)
  }
  let checkpoint = @json.parse(joined.checkpoint_json())
  guard checkpoint is Object(fields) else { fail("joint checkpoint missing") }
  assert_eq(
    fields.get("measurement"),
    Some(@json.parse(measurement.checkpoint_json())),
  )
  assert_eq(
    fields.get("counting"),
    Some(@json.parse(counting.checkpoint_json())),
  )
}

///|
test "gate exhaustion rolls back measured state and segment allocation before same-time retry" {
  let initial = @codec.AnalysisReplay::open(analysis_test_source())
  let frames = analysis_test_observations()
  ignore(initial.process_line(frames[0]))
  let saved = @json.parse(initial.checkpoint_json())
  guard saved
    is { "counting": { "state": { "counts": [Object(count)], .. }, .. }, .. } else {
    fail("count missing")
  }
  count["positive_to_negative"] = Json("9223372036854775807")
  let replay = @codec.AnalysisReplay::open(
    "{\"resume\":" + saved.stringify() + "}",
  )
  let before = replay.checkpoint_json()
  let failing = "{\"timestamp_us\":\"9007199254840993\",\"observations\":[{\"track_id\":1,\"point\":[1,0]},{\"track_id\":2,\"point\":[-2,0]}]}"
  try replay.process_line(failing) catch {
    _ => ()
  } noraise {
    _ => fail("exhausted count accepted")
  }
  assert_eq(replay.checkpoint_json(), before)
  let retry = "{\"timestamp_us\":\"9007199254840993\",\"observations\":[{\"track_id\":1,\"point\":[-0.5,0]},{\"track_id\":2,\"point\":[-2,0]}]}"
  let result = @json.parse(replay.process_line(retry))
  assert_true(
    result
    is {
      "measurement": {
        "tracks": [
          _,
          { "track_id": Number(2, ..), "segment_id": String("2"), .. },
        ],
        ..
      },
      ..
    },
  )
}

///|
test "joint restore rejects unmatched watermarks missing tracks and forged current anchors" {
  let initial = @codec.AnalysisReplay::open(analysis_test_source())
  ignore(initial.process_line(analysis_test_observations()[0]))
  let saved = initial.checkpoint_json()
  for mutation in [0, 1, 2] {
    let value = @json.parse(saved)
    guard value is { "counting": { "state": Object(state), .. }, .. } else {
      fail("state missing")
    }
    match mutation {
      0 => state["last_timestamp_us"] = Json("9007199254740994")
      1 => {
        let empty : Array[Json] = []
        state["tracks"] = Json(empty)
      }
      _ => {
        guard state.get("tracks") is Some([{ "anchors": [Object(anchor)], .. }]) else {
          fail("anchor missing")
        }
        anchor["point_m"] = Json([-2.0, 0.0])
      }
    }
    try
      @codec.AnalysisReplay::open("{\"resume\":" + value.stringify() + "}")
    catch {
      _ => ()
    } noraise {
      _ => fail("inconsistent pair accepted")
    }
  }
  let old_measurement = @codec.ReplaySession::new(
    analysis_test_measurement_source(),
  )
  ignore(old_measurement.process_line(analysis_test_observations()[0]))
  let mismatched = Json::object({
    "measurement": Json(
      "{\"resume\":" + old_measurement.checkpoint_json() + "}",
    ),
    "counting": Json(gate_test_configuration()),
  }).stringify()
  try @codec.AnalysisReplay::open(mismatched) catch {
    _ => ()
  } noraise {
    _ => fail("warm measurement joined cold counter")
  }
}

///|
test "joint checkpoint resumes every continuation and leaves the source independent" {
  let frames = analysis_test_observations()
  let original = @codec.AnalysisReplay::open(analysis_test_source())
  ignore(original.process_line(frames[0]))
  let saved = original.checkpoint_json()
  let restored = @codec.AnalysisReplay::open("{\"resume\":" + saved + "}")
  for i in 1..<frames.length() {
    assert_eq(
      restored.process_line(frames[i]),
      original.process_line(frames[i]),
    )
  }
  assert_eq(restored.checkpoint_json(), original.checkpoint_json())
  assert_eq(
    @codec.AnalysisReplay::open("{\"resume\":" + saved + "}").checkpoint_json(),
    saved,
  )
}

///|
test "pure joint analysis keeps raw text and rejects a later bad frame atomically" {
  let bundle = (text : String) => {
    Json::object({
      "source": Json(analysis_test_source()),
      "observations": Json(text),
    }).stringify()
  }
  let frames = analysis_test_observations()
  let response = @json.parse(@codec.analysis_json(bundle(frames.join("\r\n"))))
  assert_true(
    response
    is {
      "frames": [_, _, _],
      "checkpoint": { "format": String("moonground.analysis"), .. },
      ..
    },
  )
  for text in [frames.join("\n") + "\n{}\n", frames.join("\n") + "\n\n"] {
    try @codec.analysis_json(bundle(text)) catch {
      _ => ()
    } noraise {
      _ => fail("partial invalid batch returned")
    }
  }
  assert_true(
    @json.parse(@codec.analysis_json(bundle(""))) is { "frames": [], .. },
  )
}
