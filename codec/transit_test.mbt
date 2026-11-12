///|
fn transit_test_source() -> String {
  let counting =
    #|{"session_id":"transit-test","gates":[{"gate_id":"exit","start_m":[0.5,-2],"end_m":[0.5,2],"deadband_m":0},{"gate_id":"entry","start_m":[-0.5,-2],"end_m":[-0.5,2],"deadband_m":0}],"max_tracks":2}
  Json::object({
    "counting": Json(counting),
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
fn transit_test_measurements() -> Array[String] raise @types.GroundError {
  let configuration =
    #|{"session_id":"transit-test","mode":"ground","diagnostics":true,"motion":{"gate":100000000,"initial_velocity_std":20}}
  let session = @codec.ReplaySession::new(configuration)
  let frames : Array[String] = []
  let base = 9223372036854475807L
  for index, x in [-1.0, 2.0, -1.0, 2.0] {
    frames.push(
      session.process_line(
        Json::object({
          "timestamp_us": Json((base + index.to_int64() * 100000L).to_string()),
          "observations": Json([
            Json::object({ "track_id": Json(7), "point": Json([x, 0.0]) }),
          ]),
        }).stringify(),
      ),
    )
  }
  frames
}

///|
test "transit uses one filtered chord rather than configured gate order at Int64 maximum" {
  let replay = @codec.TransitReplay::open(transit_test_source())
  let frames = transit_test_measurements()
  ignore(replay.process_line(frames[0]))
  let passage = @json.parse(replay.process_line(frames[1]))
  assert_true(
    passage
    is {
      "kind": String("transit_events"),
      "counting": {
        "crossings": [
          { "gate_id": String("exit"), .. },
          { "gate_id": String("entry"), .. },
        ],
        ..
      },
      "passages": [
        {
          "section_id": String("aisle"),
          "entry": { "from_timestamp_us": String("9223372036854475807"), .. },
          "elapsed_lower_us": String("0"),
          "elapsed_upper_us": String("100000"),
          ..
        },
      ],
      "counts": [{ "completed": String("1"), .. }],
      "pending_count": Number(0, ..),
      ..
    },
  )
  ignore(replay.process_line(frames[2]))
  assert_true(
    @json.parse(replay.process_line(frames[3]))
    is { "counting": { "timestamp_us": String("9223372036854775807"), .. }, .. },
  )
}

///|
test "transit checkpoints resume every actual measurement cut including an unstarted stream" {
  let frames = transit_test_measurements()
  for cut in 0..<=frames.length() {
    let original = @codec.TransitReplay::open(transit_test_source())
    for index in 0..<cut {
      ignore(original.process_line(frames[index]))
    }
    let checkpoint = original.checkpoint_json()
    let restored = @codec.TransitReplay::open("{\"resume\":" + checkpoint + "}")
    for index in cut..<frames.length() {
      assert_eq(
        original.process_line(frames[index]),
        restored.process_line(frames[index]),
      )
    }
    assert_eq(original.checkpoint_json(), restored.checkpoint_json())
    let untouched = @codec.TransitReplay::open(
      "{\"resume\":" + checkpoint + "}",
    )
    assert_eq(untouched.checkpoint_json(), checkpoint)
  }
}

///|
test "transit raw invalid payloads leave the gate and passage watermark reusable" {
  let replay = @codec.TransitReplay::open(transit_test_source())
  let frames = transit_test_measurements()
  ignore(replay.process_line(frames[0]))
  let saved = replay.checkpoint_json()
  let invalid = frames[1].replace(
    old="\"track_id\":7",
    new="\"track_id\":7.0000000000000000001",
  )
  assert_true(invalid != frames[1])
  for
    source in [
      frames[0],
      "{}",
      invalid,
      frames[1].replace(
        old="\"track_id\":7",
        new="\"track_id\":7,\"track_id\":7",
      ),
      frames[1].replace(
        old="\"track_id\":7",
        new="\"track_id\":7,\"ignored\":true",
      ),
    ] {
    try replay.process_line(source) catch {
      _ => ()
    } noraise {
      _ => fail("invalid transit input accepted")
    }
    assert_eq(replay.checkpoint_json(), saved)
  }
  assert_true(
    @json.parse(replay.process_line(frames[1])) is { "passages": [_], .. },
  )
}

///|
test "transit configuration preserves nested raw tokens and rejects invalid sections" {
  let source = transit_test_source()
  for
    source in [
      "{}",
      source.replace(old="positive_to_negative", new="reverse"),
      source.replace(
        old="\"section_id\":\"aisle\"",
        new="\"section_id\":\"aisle\",\"ignored\":0",
      ),
      source.replace(
        old="\"exit_gate_id\":\"exit\"",
        new="\"exit_gate_id\":\"entry\"",
      ),
      source.replace(
        old="\"entry_gate_id\":\"entry\"",
        new="\"entry_gate_id\":\"unknown\"",
      ),
      source.replace(
        old="\\\"max_tracks\\\":2",
        new="\\\"max_tracks\\\":2.0000000000000000001",
      ),
    ] {
    try @codec.TransitReplay::open(source) catch {
      _ => ()
    } noraise {
      _ => fail("invalid transit configuration accepted")
    }
  }
}

///|
test "transit pure batch handles CRLF empty and terminal LF without exposing failed prefixes" {
  let frames = transit_test_measurements()
  let request = (text : String) => {
    Json::object({
      "source": Json(transit_test_source()),
      "measurements": Json(text),
    }).stringify()
  }
  let no_lf = @codec.transit_json(request(frames.join("\n")))
  assert_eq(@codec.transit_json(request(frames.join("\r\n") + "\r\n")), no_lf)
  assert_true(
    @json.parse(no_lf)
    is {
      "frames": [_, _, _, _],
      "checkpoint": {
        "format": String("moonground.transit"),
        "checkpoint_version": String("1"),
        ..
      },
      ..
    },
  )
  assert_true(
    @json.parse(@codec.transit_json(request(""))) is { "frames": [], .. },
  )
  for text in [frames.join("\n") + "\n{}\n", frames.join("\n") + "\n\n"] {
    try @codec.transit_json(request(text)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid later transit frame accepted")
    }
  }
}

///|
test "transit restore rejects extra state version overrides and inconsistent completed totals" {
  let replay = @codec.TransitReplay::open(transit_test_source())
  let frames = transit_test_measurements()
  ignore(replay.process_line(frames[0]))
  ignore(replay.process_line(frames[1]))
  let saved = replay.checkpoint_json()
  for
    source in [
      "{\"resume\":" + saved + ",\"max_duration_us\":\"1\"}",
      "{\"resume\":" +
      saved.replace(
        old="\"format\":\"moonground.transit\"",
        new="\"format\":\"unknown\"",
      ) +
      "}",
      "{\"resume\":" +
      saved.replace(old="\"completed\":\"1\"", new="\"completed\":\"2\"") +
      "}",
    ] {
    try @codec.TransitReplay::open(source) catch {
      _ => ()
    } noraise {
      _ => fail("invalid transit checkpoint accepted")
    }
  }
}

///|
test "transit restores a pending real entry and an empty frame cancels it without bridging" {
  let measurement_source =
    #|{"session_id":"transit-test","mode":"ground","motion":{"gate":100000000,"initial_velocity_std":20}}
  let session = @codec.ReplaySession::new(measurement_source)
  let frames : Array[String] = []
  for index, x in [-1.0, 0.0, 1.0] {
    frames.push(
      session.process_line(
        Json::object({
          "timestamp_us": Json((index * 100000).to_string()),
          "observations": Json([
            Json::object({
              "track_id": Json(7),
              "point": Json([x, 0.0]),
              "covariance": Json([0.00000001, 0.0, 0.00000001]),
            }),
          ]),
        }).stringify(),
      ),
    )
  }
  let replay = @codec.TransitReplay::open(transit_test_source())
  ignore(replay.process_line(frames[0]))
  assert_true(
    @json.parse(replay.process_line(frames[1]))
    is { "pending_count": Number(1, ..), "passages": [], .. },
  )
  let saved = replay.checkpoint_json()
  let restored = @codec.TransitReplay::open("{\"resume\":" + saved + "}")
  assert_eq(replay.process_line(frames[2]), restored.process_line(frames[2]))
  let interrupted = @codec.TransitReplay::open("{\"resume\":" + saved + "}")
  let empty =
    #|{"schema_version":"0.2.0","uncertainty_scope":"conditional_on_fixed_calibration_camera_and_anchor","session_id":"transit-test","timestamp_us":"150000","tracks":[],"closed_segment_ids":[]}
  assert_true(
    @json.parse(interrupted.process_line(empty))
    is {
      "cancellations": [{ "reason": String("discontinuity"), .. }],
      "pending_count": Number(0, ..),
      ..
    },
  )
  assert_true(
    @json.parse(interrupted.process_line(frames[2])) is { "passages": [], .. },
  )
}
