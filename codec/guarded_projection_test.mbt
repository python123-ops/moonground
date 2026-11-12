///|
fn projection_test_control(
  time : Int64,
  camera~ : Json = Json::null(),
) -> String {
  Json::object({
    "replace_projection": Json(
      Json::object({
        "timestamp_us": Json(time.to_string()),
        "calibration": Json::object({
          "matrix": Json([0.02, 0.0, 0.0, 0.0, 0.02, 0.0, 0.0, 0.0, 1.0]),
          "roi": Json([[0, 0], [320, 0], [320, 240], [0, 240]]),
          "ground_noise_floor_m": Json(0.005),
        }),
        "camera": camera,
      }).stringify(),
    ),
  }).stringify()
}

///|
fn projection_test_frame(time : Int64, x : Double) -> String {
  Json::object({
    "measurement": Json(
      Json::object({
        "timestamp_us": Json(time.to_string()),
        "observations": Json([
          Json::object({ "track_id": Json(7), "point": Json([x, 100.0]) }),
        ]),
      }).stringify(),
    ),
    "health": Json(
      Json::object({
        "timestamp_us": Json(time.to_string()),
        "observations": Json([
          Json::object({ "landmark_id": Json("a"), "point": Json([50, 50]) }),
          Json::object({ "landmark_id": Json("b"), "point": Json([100, 50]) }),
          Json::object({ "landmark_id": Json("c"), "point": Json([50, 100]) }),
        ]),
      }).stringify(),
    ),
  }).stringify()
}

///|
test "projection barrier updates both canonical configurations and resumes new warmed segments" {
  let replay = @codec.GuardedReplay::open(guarded_test_source())
  ignore(replay.process_line(guarded_test_frame(0L, 100.0)))
  ignore(replay.process_line(guarded_test_frame(100000L, 100.0)))
  ignore(replay.process_line(guarded_test_frame(200000L, 140.0)))
  assert_true(
    @json.parse(replay.process_line(projection_test_control(250000L)))
    is {
      "kind": String("guarded_projection_replaced"),
      "decision": String("blocked"),
      "suppressed_track_ids": [],
      "health": {
        "status": String("insufficient"),
        "streak_since_us": Null,
        ..
      },
      "analysis": {
        "measurement": { "tracks": [], "closed_segment_ids": [String("1")], .. },
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
  let restored = @codec.GuardedReplay::open("{\"resume\":" + saved + "}")
  let pending = projection_test_frame(300000L, 50.0)
  assert_eq(replay.process_line(pending), restored.process_line(pending))
  let allowed = projection_test_frame(400000L, 50.0)
  let result = replay.process_line(allowed)
  assert_eq(restored.process_line(allowed), result)
  assert_true(
    @json.parse(result)
    is {
      "decision": String("allowed"),
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
        ..
      },
      ..
    },
  )
  let crossing = projection_test_frame(500000L, 70.0)
  assert_eq(restored.process_line(crossing), replay.process_line(crossing))
  assert_eq(restored.checkpoint_json(), replay.checkpoint_json())
}

///|
test "invalid projection operations preserve both cached configurations and all committed state" {
  let replay = @codec.GuardedReplay::open(guarded_test_source())
  ignore(replay.process_line(guarded_test_frame(0L, 100.0)))
  ignore(replay.process_line(guarded_test_frame(100000L, 100.0)))
  let saved = replay.checkpoint_json()
  let valid = projection_test_control(200000L)
  for
    source in [
      projection_test_control(100000L),
      valid.replace(old="\\\"camera\\\":null", new="\\\"ignored\\\":null"),
      valid.replace(
        old="\\\"camera\\\":null",
        new="\\\"camera\\\":null,\\\"camera\\\":null",
      ),
      valid.replace(
        old="\\\"timestamp_us\\\":\\\"200000\\\"",
        new="\\\"timestamp_us\\\":200000",
      ),
      valid.replace(
        old="\\\"ground_noise_floor_m\\\":0.005",
        new="\\\"ground_noise_floor_m\\\":-1",
      ),
      valid.replace(
        old="{\"replace_projection\":",
        new="{\"health\":\"{}\",\"replace_projection\":",
      ),
      "{\"replace_projection\":{}}",
    ] {
    try replay.process_line(source) catch {
      _ => ()
    } noraise {
      _ => fail("invalid projection operation accepted")
    }
    assert_eq(replay.checkpoint_json(), saved)
  }
  assert_true(
    @json.parse(replay.process_line(valid))
    is { "kind": String("guarded_projection_replaced"), .. },
  )
}

///|
test "explicit camera removal deletes both cached Brown configurations before durable restore" {
  let replay = @codec.GuardedReplay::open(guarded_test_source())
  let camera = Json::object({
    "fx": Json(500),
    "fy": Json(500),
    "cx": Json(0),
    "cy": Json(0),
  })
  ignore(replay.process_line(projection_test_control(0L, camera~)))
  let before = replay.checkpoint_json()
  assert_true(
    @json.parse(before)
    is {
      "health": {
        "configuration": { "camera": { "fx": Number(500, ..), .. }, .. },
        ..
      },
      ..
    },
  )
  ignore(replay.process_line(projection_test_control(1L)))
  let saved = @json.parse(replay.checkpoint_json())
  guard saved
    is {
      "analysis": { "measurement": { "configuration": Object(a), .. }, .. },
      "health": { "configuration": Object(h), .. },
      ..
    } else {
    fail("new complete projection state missing")
  }
  assert_false(a.contains("camera"))
  assert_false(h.contains("camera"))
  let restored = @codec.GuardedReplay::open(
    "{\"resume\":" + saved.stringify() + "}",
  )
  assert_eq(restored.checkpoint_json(), replay.checkpoint_json())
  assert_eq(
    @codec.GuardedReplay::open("{\"resume\":" + before + "}").checkpoint_json(),
    before,
  )
}

///|
test "pure guarded batch includes a projection barrier and never exposes a failed later prefix" {
  let frames = [
    guarded_test_frame(0L, 100.0),
    guarded_test_frame(100000L, 100.0),
    projection_test_control(200000L),
  ]
  let request = (observations : String) => {
    Json::object({
      "source": Json(guarded_test_source()),
      "observations": Json(observations),
    }).stringify()
  }
  let result = @codec.guarded_json(request(frames.join("\r\n") + "\r\n"))
  assert_true(
    @json.parse(result)
    is {
      "frames": [_, _, { "kind": String("guarded_projection_replaced"), .. }],
      ..
    },
  )
  assert_eq(result, @codec.guarded_json(request(frames.join("\n"))))
  try @codec.guarded_json(request(frames.join("\n") + "\n{}")) catch {
    _ => ()
  } noraise {
    _ => fail("failed later projection batch accepted")
  }
}
