///|
fn health_test_source() -> String {
  (
    #|{"monitor_id":"fixed-aisle","calibration":{"matrix":[0.01,0,0,0,0.01,0,0,0,1],"roi":[[0,0],[640,0],[640,480],[0,480]]},"landmarks":[{"landmark_id":"a","ground_m":[1,1]},{"landmark_id":"b","ground_m":[2,1]},{"landmark_id":"c","ground_m":[1,2]}],"health":{"min_landmarks":2,"min_observations":2,"confirmation_us":"100000"}}
  )
}

///|
fn health_test_frame(time : Int64, shift~ : Double = 0.0) -> String {
  Json::object({
    "timestamp_us": Json(time.to_string()),
    "observations": Json([
      Json::object({
        "landmark_id": Json("a"),
        "point": Json([100.0 + shift, 100.0]),
      }),
      Json::object({
        "landmark_id": Json("b"),
        "point": Json([200.0 + shift, 100.0]),
      }),
      Json::object({
        "landmark_id": Json("c"),
        "point": Json([100.0 + shift, 200.0]),
      }),
    ]),
  }).stringify()
}

///|
test "health replay confirms metric landmark evidence and withdraws it on missing observations" {
  let replay = @codec.HealthReplay::open(health_test_source())
  assert_true(
    @json.parse(replay.process_line(health_test_frame(0L)))
    is { "status": String("pending"), .. },
  )
  assert_true(
    @json.parse(replay.process_line(health_test_frame(100000L)))
    is {
      "kind": String("calibration_health"),
      "monitor_id": String("fixed-aisle"),
      "status": String("healthy"),
      "evidence": String("within_tolerance"),
      "usable_count": Number(3, ..),
      "streak_since_us": String("0"),
      ..
    },
  )
  ignore(replay.process_line(health_test_frame(200000L, shift=50.0)))
  assert_true(
    @json.parse(replay.process_line(health_test_frame(300000L, shift=50.0)))
    is {
      "status": String("drift"),
      "evidence": String("beyond_tolerance"),
      "rms_error_m": Number(0.5, ..),
      "max_error_m": Number(0.5, ..),
      ..
    },
  )
  assert_true(
    @json.parse(
      replay.process_line("{\"timestamp_us\":\"400000\",\"observations\":[]}"),
    )
    is {
      "status": String("insufficient"),
      "rms_error_m": Null,
      "max_error_m": Null,
      "streak_since_us": Null,
      "streak_observations": Number(0, ..),
      ..
    },
  )
}

///|
test "health checkpoint retains exact watermark and resumes pending confirmation independently" {
  let replay = @codec.HealthReplay::open(health_test_source())
  let first = 9007199254740993L
  ignore(replay.process_line(health_test_frame(first)))
  let saved = replay.checkpoint_json()
  let restored = @codec.HealthReplay::open("{\"resume\":" + saved + "}")
  assert_eq(
    restored.process_line(health_test_frame(first + 100000L)),
    replay.process_line(health_test_frame(first + 100000L)),
  )
  assert_eq(restored.checkpoint_json(), replay.checkpoint_json())
  assert_eq(
    @codec.HealthReplay::open("{\"resume\":" + saved + "}").checkpoint_json(),
    saved,
  )
}

///|
test "health fatal observation failures keep the whole frame reusable while projection failures commit" {
  let replay = @codec.HealthReplay::open(health_test_source())
  ignore(replay.process_line(health_test_frame(0L)))
  let saved = replay.checkpoint_json()
  for
    source in [
      "{\"timestamp_us\":\"100000\",\"observations\":[{\"landmark_id\":\"a\",\"point\":[100,100]},{\"landmark_id\":\"unknown\",\"point\":[100,100]}]}",
      "{\"timestamp_us\":\"100000\",\"observations\":[{\"landmark_id\":\"a\",\"point\":[100,100]},{\"landmark_id\":\"a\",\"point\":[100,100]}]}",
      "{\"timestamp_us\":\"100000\",\"observations\":[{\"landmark_id\":\"a\",\"point\":[100,100],\"covariance\":[1,2,1]}]}",
      "{\"timestamp_us\":\"100000\",\"timestamp_us\":\"100001\",\"observations\":[]}",
    ] {
    try replay.process_line(source) catch {
      _ => ()
    } noraise {
      _ => fail("invalid health frame accepted")
    }
    assert_eq(replay.checkpoint_json(), saved)
  }
  let projected = @json.parse(
    replay.process_line(
      "{\"timestamp_us\":\"100000\",\"observations\":[{\"landmark_id\":\"a\",\"point\":[10000,100]}]}",
    ),
  )
  assert_true(
    projected
    is {
      "status": String("insufficient"),
      "timestamp_us": String("100000"),
      "usable_count": Number(0, ..),
      ..
    },
  )
  assert_true(replay.checkpoint_json() != saved)
}

///|
test "health configuration and restored streak preserve strict integer and state contracts" {
  let source = health_test_source()
  for
    bad in [
      source.replace(
        old="\"min_observations\":2",
        new="\"min_observations\":2.0000000000000001",
      ),
      source.replace(old="\"min_landmarks\":2", new="\"min_landmarks\":4"),
      source.replace(
        old="\"confirmation_us\":\"100000\"",
        new="\"confirmation_us\":100000",
      ),
    ] {
    try @codec.HealthReplay::open(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid health configuration accepted")
    }
  }
  let replay = @codec.HealthReplay::open(source)
  ignore(replay.process_line(health_test_frame(0L)))
  let saved = replay.checkpoint_json()
  for
    bad in [
      saved.replace(old="\"since_us\":\"0\"", new="\"since_us\":\"1\""),
      saved.replace(
        old="\"observations\":1",
        new="\"observations\":1.0000000000000001",
      ),
      saved.replace(
        old="\"evidence\":\"within_tolerance\"",
        new="\"evidence\":\"insufficient\"",
      ),
      saved.replace(
        old="\"checkpoint_version\":\"1\"",
        new="\"checkpoint_version\":\"2\"",
      ),
    ] {
    try @codec.HealthReplay::open("{\"resume\":" + bad + "}") catch {
      _ => ()
    } noraise {
      _ => fail("invalid health checkpoint accepted")
    }
  }
}

///|
test "health pure batches preserve raw CRLF documents and fail without partial responses" {
  let lines = [health_test_frame(0L), health_test_frame(100000L)]
  let response = @json.parse(
    @codec.health_json(
      Json::object({
        "source": Json(health_test_source()),
        "observations": Json(lines.join("\r\n") + "\r\n"),
      }).stringify(),
    ),
  )
  assert_true(
    response
    is {
      "frames": [_, { "status": String("healthy"), .. }],
      "checkpoint": { "format": String("moonground.health"), .. },
      ..
    },
  )
  for
    observations in [
      lines[0] + "\n{}",
      lines[0] + "\n\n",
      lines[0] + "\n" + lines[0],
    ] {
    try
      @codec.health_json(
        Json::object({
          "source": Json(health_test_source()),
          "observations": Json(observations),
        }).stringify(),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid health batch accepted")
    }
  }
}
