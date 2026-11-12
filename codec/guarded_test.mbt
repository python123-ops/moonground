///|
fn guarded_test_source() -> String {
  let measurement =
    #|{"session_id":"guarded-test","mode":"pixel","diagnostics":true,"calibration":{"matrix":[0.01,0,0,0,0.01,0,0,0,1],"roi":[[0,0],[640,0],[640,480],[0,480]]},"motion":{"max_tracks":2,"gate":100000000}}
  let counting =
    #|{"session_id":"guarded-test","gates":[{"gate_id":"door","start_m":[1.15,0],"end_m":[1.15,4],"deadband_m":0.01}],"max_tracks":2}
  Json::object({
    "analysis": Json(
      Json::object({
        "measurement": Json(measurement),
        "counting": Json(counting),
      }).stringify(),
    ),
    "health": Json(health_test_source()),
  }).stringify()
}

///|
fn guarded_test_measurement(time : Int64, x : Double) -> String {
  Json::object({
    "timestamp_us": Json(time.to_string()),
    "observations": Json([
      Json::object({ "track_id": Json(7), "point": Json([x, 200.0]) }),
    ]),
  }).stringify()
}

///|
fn guarded_test_frame(
  time : Int64,
  x : Double,
  shift~ : Double = 0.0,
) -> String {
  Json::object({
    "measurement": Json(guarded_test_measurement(time, x)),
    "health": Json(health_test_frame(time, shift~)),
  }).stringify()
}

///|
test "guarded replay interrupts warmed motion on pending evidence and resumes a new segment" {
  let replay = @codec.GuardedReplay::open(guarded_test_source())
  assert_true(
    @json.parse(replay.process_line(guarded_test_frame(0L, 100.0)))
    is {
      "decision": String("blocked"),
      "suppressed_track_ids": [Number(7, ..)],
      "analysis": { "measurement": { "tracks": [], .. }, .. },
      ..
    },
  )
  ignore(replay.process_line(guarded_test_frame(100000L, 100.0)))
  let crossing = @json.parse(
    replay.process_line(guarded_test_frame(200000L, 140.0)),
  )
  assert_true(
    crossing
    is {
      "decision": String("allowed"),
      "analysis": {
        "counting": {
          "counts": [{ "positive_to_negative": String("1"), .. }],
          ..
        },
        ..
      },
      ..
    },
  )
  assert_true(
    @json.parse(
      replay.process_line(guarded_test_frame(300000L, 100.0, shift=50.0)),
    )
    is {
      "decision": String("blocked"),
      "health": { "status": String("pending"), .. },
      "analysis": {
        "measurement": { "tracks": [], "closed_segment_ids": [String("1")], .. },
        "counting": { "crossings": [], .. },
        ..
      },
      ..
    },
  )
  ignore(replay.process_line(guarded_test_frame(400000L, 140.0, shift=50.0)))
  ignore(replay.process_line(guarded_test_frame(500000L, 100.0)))
  assert_true(
    @json.parse(replay.process_line(guarded_test_frame(600000L, 100.0)))
    is {
      "decision": String("allowed"),
      "suppressed_track_ids": [],
      "analysis": {
        "measurement": {
          "tracks": [
            {
              "segment_id": String("2"),
              "accepted_count": Number(1, ..),
              "speed_mps": Null,
              ..
            },
          ],
          ..
        },
        "counting": {
          "crossings": [],
          "counts": [{ "positive_to_negative": String("1"), .. }],
          ..
        },
        ..
      },
      ..
    },
  )
}

///|
test "guarded blocked frames still reject original identity covariance and timestamp errors atomically" {
  let replay = @codec.GuardedReplay::open(guarded_test_source())
  ignore(replay.process_line(guarded_test_frame(0L, 100.0)))
  let saved = replay.checkpoint_json()
  for
    measurement in [
      "{\"timestamp_us\":\"100000\",\"observations\":[{\"track_id\":7,\"point\":[100,200]},{\"track_id\":7,\"point\":[200,200]}]}",
      "{\"timestamp_us\":\"100000\",\"observations\":[{\"track_id\":7,\"point\":[100,200]}],\"removed\":[7]}",
      "{\"timestamp_us\":\"100000\",\"observations\":[{\"track_id\":7,\"point\":[100,200],\"covariance\":[1,2,1]}]}",
      guarded_test_measurement(100001L, 100.0),
    ] {
    let source = Json::object({
      "measurement": Json(measurement),
      "health": Json(health_test_frame(100000L, shift=50.0)),
    }).stringify()
    try replay.process_line(source) catch {
      _ => ()
    } noraise {
      _ => fail("blocked frame hid malformed object input")
    }
    assert_eq(replay.checkpoint_json(), saved)
  }
  assert_true(
    @json.parse(replay.process_line(guarded_test_frame(100000L, 100.0)))
    is { "decision": String("allowed"), .. },
  )
}

///|
test "guarded complete checkpoints resume every interruption cut and reject impossible pairings" {
  let frames = [
    guarded_test_frame(0L, 100.0),
    guarded_test_frame(100000L, 100.0),
    guarded_test_frame(200000L, 140.0),
    guarded_test_frame(300000L, 100.0, shift=50.0),
    guarded_test_frame(400000L, 140.0),
    guarded_test_frame(500000L, 100.0),
  ]
  for cut in 0..<(frames.length() + 1) {
    let replay = @codec.GuardedReplay::open(guarded_test_source())
    for frame in frames[:cut] {
      ignore(replay.process_line(frame))
    }
    let saved = replay.checkpoint_json()
    let restored = @codec.GuardedReplay::open("{\"resume\":" + saved + "}")
    for frame in frames[cut:] {
      assert_eq(restored.process_line(frame), replay.process_line(frame))
    }
    assert_eq(restored.checkpoint_json(), replay.checkpoint_json())
  }
  let replay = @codec.GuardedReplay::open(guarded_test_source())
  ignore(replay.process_line(frames[0]))
  ignore(replay.process_line(frames[1]))
  let checkpoint = @json.parse(replay.checkpoint_json())
  guard checkpoint
    is { "health": { "state": { "streak": Object(streak), .. }, .. }, .. } else {
    fail("health streak missing")
  }
  streak["evidence"] = Json("beyond_tolerance")
  try
    @codec.GuardedReplay::open("{\"resume\":" + checkpoint.stringify() + "}")
  catch {
    _ => ()
  } noraise {
    _ => fail("blocked checkpoint retained live motion")
  }
}

///|
test "guarded gate failure also rolls back current health before a blocked same-time retry" {
  let replay = @codec.GuardedReplay::open(guarded_test_source())
  ignore(replay.process_line(guarded_test_frame(0L, 100.0)))
  ignore(replay.process_line(guarded_test_frame(100000L, 100.0)))
  let checkpoint = @json.parse(replay.checkpoint_json())
  guard checkpoint
    is {
      "analysis": {
        "counting": { "state": { "counts": [Object(count)], .. }, .. },
        ..
      },
      ..
    } else {
    fail("gate count missing")
  }
  count["positive_to_negative"] = Json("9223372036854775807")
  let resumed = @codec.GuardedReplay::open(
    "{\"resume\":" + checkpoint.stringify() + "}",
  )
  let saved = resumed.checkpoint_json()
  try resumed.process_line(guarded_test_frame(200000L, 140.0)) catch {
    _ => ()
  } noraise {
    _ => fail("exhausted gate counter accepted crossing")
  }
  assert_eq(resumed.checkpoint_json(), saved)
  assert_true(
    @json.parse(
      resumed.process_line(guarded_test_frame(200000L, 140.0, shift=50.0)),
    )
    is {
      "decision": String("blocked"),
      "analysis": {
        "measurement": { "closed_segment_ids": [String("1")], .. },
        ..
      },
      ..
    },
  )
}

///|
test "guarded binding rejects altered mapping capacity and raw fractional tokens" {
  let source = @json.parse(guarded_test_source())
  guard source is Object(fields) else { fail("guarded header missing") }
  guard fields.get("health") is Some(String(health)) else {
    fail("health source missing")
  }
  for
    bad in [
      health.replace(
        old="[0.01,0,0,0,0.01,0,0,0,1]",
        new="[0.02,0,0,0,0.01,0,0,0,1]",
      ),
      health.replace(
        old="\"min_observations\":2",
        new="\"min_observations\":2.0000000000000001",
      ),
    ] {
    fields["health"] = Json(bad)
    try @codec.GuardedReplay::open(source.stringify()) catch {
      _ => ()
    } noraise {
      _ => fail("guarded source accepted incompatible mapping or token")
    }
  }
  fields["health"] = Json(health)
  guard fields.get("analysis") is Some(String(analysis_source)) else {
    fail("analysis source missing")
  }
  let analysis_value = @json.parse(analysis_source)
  guard analysis_value is Object(analysis_fields) else {
    fail("analysis header missing")
  }
  guard analysis_fields.get("counting") is Some(String(counting)) else {
    fail("counting source missing")
  }
  analysis_fields["counting"] = Json(
    counting.replace(old="\"max_tracks\":2", new="\"max_tracks\":1"),
  )
  fields["analysis"] = Json(analysis_value.stringify())
  try @codec.GuardedReplay::open(source.stringify()) catch {
    _ => ()
  } noraise {
    _ => fail("guarded gate capacity cannot clear every active measurement")
  }
}

///|
test "guarded pure batches keep original paired documents and reject partial outputs" {
  let observations = guarded_test_frame(0L, 100.0) +
    "\r\n" +
    guarded_test_frame(100000L, 100.0) +
    "\r\n"
  let result = @json.parse(
    @codec.guarded_json(
      Json::object({
        "source": Json(guarded_test_source()),
        "observations": Json(observations),
      }).stringify(),
    ),
  )
  assert_true(
    result
    is {
      "frames": [
        { "decision": String("blocked"), .. },
        { "decision": String("allowed"), .. },
      ],
      "checkpoint": { "format": String("moonground.guarded"), .. },
      ..
    },
  )
  for observations in [observations + "{}", observations + "\n"] {
    try
      @codec.guarded_json(
        Json::object({
          "source": Json(guarded_test_source()),
          "observations": Json(observations),
        }).stringify(),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid guarded batch exposed a partial result")
    }
  }
}
