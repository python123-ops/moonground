///|
fn checkpoint_object(source : String) -> Map[String, Json] raise {
  match @json.parse(source) {
    Object(fields) => fields
    _ => fail("expected checkpoint object")
  }
}

///|
fn checkpoint_frame(time : String, x : Double) -> String {
  Json::object({
    "timestamp_us": Json(time),
    "observations": Json([
      Json::object({ "track_id": Json(1), "point": Json([x, 0.0]) }),
    ]),
  }).stringify()
}

///|
test "wire ground checkpoint keeps effective configuration and exact large-time continuation" {
  let session = @codec.ReplaySession::new(
    "{\"session_id\":\"wire-resume\",\"mode\":\"ground\",\"diagnostics\":true,\"motion\":{\"max_gap_us\":\"700000\",\"min_observations\":2,\"min_span_us\":\"0\",\"q\":0.37,\"initial_velocity_std\":2.3,\"gate\":7.5,\"max_tracks\":9,\"max_position_std_m\":0.8,\"max_velocity_std_mps\":0.000001}}",
  )
  ignore(session.process_line(checkpoint_frame("9007199254740993", 0.0)))
  ignore(session.process_line(checkpoint_frame("9007199254890993", 0.15)))
  let checkpoint = session.checkpoint_json()
  assert_true(
    @json.parse(checkpoint)
    is {
      "format": String("moonground.session"),
      "checkpoint_version": String("1"),
      "configuration": {
        "diagnostics": True,
        "motion": {
          "max_gap_us": String("700000"),
          "min_observations": Number(2, ..),
          "min_span_us": String("0"),
          "q": Number(0.37, ..),
          "initial_velocity_std": Number(2.3, ..),
          "gate": Number(7.5, ..),
          "max_tracks": Number(9, ..),
          "max_position_std_m": Number(0.8, ..),
          "max_velocity_std_mps": Number(0.000001, ..),
          ..
        },
        ..
      },
      "motion": {
        "last_timestamp_us": String("9007199254890993"),
        "next_segment_id": String("2"),
        "tracks": [
          { "segment_id": String("1"), "accepted_count": Number(2, ..), .. },
        ],
        ..
      },
      ..
    },
  )
  let restored = @codec.ReplaySession::from_checkpoint_json(checkpoint)
  let envelope = Json::object({ "resume": @json.parse(checkpoint) }).stringify()
  let opened = @codec.ReplaySession::open(envelope)
  for (time, x) in [("9007199255040993", 0.3), ("9007199255190993", 0.45)] {
    let frame = checkpoint_frame(time, x)
    let expected = session.process_line(frame)
    assert_eq(restored.process_line(frame), expected)
    assert_eq(opened.process_line(frame), expected)
  }
  assert_eq(restored.checkpoint_json(), session.checkpoint_json())
}

///|
test "wire pixel checkpoint keeps normalized calibration original floor and camera defaults" {
  let session = @codec.ReplaySession::open(
    "{\"session_id\":\"camera-resume\",\"diagnostics\":true,\"camera\":{\"fx\":100,\"fy\":80,\"cx\":50,\"cy\":50,\"k1\":0.03,\"p2\":-0.001},\"calibration\":{\"matrix\":[0.06,0,0,0,0.06,0,0,0,3],\"roi\":[[0,0],[100,0],[100,100],[0,100]],\"max_meters_per_pixel\":0.08,\"ground_noise_floor_m\":0.017}}",
  )
  ignore(session.process_line(checkpoint_frame("0", 40.0)))
  let checkpoint = session.checkpoint_json()
  assert_true(
    @json.parse(checkpoint)
    is {
      "configuration": {
        "mode": String("pixel"),
        "calibration": {
          "matrix": [
            Number(0.02, ..),
            Number(0, ..),
            Number(0, ..),
            Number(0, ..),
            Number(0.02, ..),
            Number(0, ..),
            Number(0, ..),
            Number(0, ..),
            Number(1, ..),
          ],
          "max_meters_per_pixel": Number(0.08, ..),
          "ground_noise_floor_m": Number(0.017, ..),
          ..
        },
        "camera": {
          "fx": Number(100, ..),
          "fy": Number(80, ..),
          "cx": Number(50, ..),
          "cy": Number(50, ..),
          "k1": Number(0.03, ..),
          "k2": Number(0, ..),
          "p1": Number(0, ..),
          "p2": Number(-0.001, ..),
          "k3": Number(0, ..),
          "max_normalized_radius": Number(1, ..),
          ..
        },
        ..
      },
      ..
    },
  )
  let restored = @codec.ReplaySession::from_checkpoint_json(checkpoint)
  for (time, x) in [("150000", 41.0), ("300000", 42.0)] {
    let frame = checkpoint_frame(time, x)
    assert_eq(restored.process_line(frame), session.process_line(frame))
  }
  assert_eq(restored.checkpoint_json(), session.checkpoint_json())
}

///|
test "checkpoint resume envelope rejects overrides and noncanonical state without consuming live time" {
  let session = @codec.ReplaySession::new(
    "{\"session_id\":\"strict-resume\",\"mode\":\"ground\"}",
  )
  ignore(session.process_line(checkpoint_frame("0", 0.0)))
  let checkpoint = session.checkpoint_json()
  for name in ["checkpoint_version", "format"] {
    let fields = checkpoint_object(checkpoint)
    fields[name] = Json("future")
    try
      @codec.ReplaySession::from_checkpoint_json(
        Json::object(fields).stringify(),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("unsupported checkpoint metadata accepted")
    }
  }
  let fields = checkpoint_object(checkpoint)
  guard fields.get("motion") is Some(Object(motion)) else {
    fail("missing motion")
  }
  for value in [Json(2), Json("02"), Json("+2"), Json("9223372036854775808")] {
    motion["next_segment_id"] = value
    try
      @codec.ReplaySession::from_checkpoint_json(
        Json::object(fields).stringify(),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid decimal state accepted")
    }
  }
  try
    @codec.ReplaySession::open(
      Json::object({
        "resume": @json.parse(checkpoint),
        "diagnostics": Json(false),
      }).stringify(),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("resume override accepted")
  }
  // The original remains independently usable after every failed restore.
  let result = @json.parse(
    session.process_line(checkpoint_frame("100000", 0.1)),
  )
  assert_true(
    result is { "tracks": [{ "accepted_count": Number(2, ..), .. }], .. },
  )
}

///|
test "checkpoint configurations cannot silently apply omitted defaults" {
  let session = @codec.ReplaySession::new(
    "{\"session_id\":\"complete\",\"mode\":\"ground\"}",
  )
  let fields = checkpoint_object(session.checkpoint_json())
  guard fields.get("configuration") is Some(Object(configuration)) else {
    fail("missing config")
  }
  guard configuration.get("motion") is Some(Object(motion)) else {
    fail("missing motion")
  }
  ignore(motion.remove("gate"))
  try
    @codec.ReplaySession::from_checkpoint_json(Json::object(fields).stringify())
  catch {
    _ => ()
  } noraise {
    _ => fail("incomplete effective configuration accepted")
  }
  try
    @codec.ReplaySession::from_checkpoint_json(
      "{\"format\":\"x\",\"format\":\"y\"}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("duplicate checkpoint key accepted")
  }
}

///|
test "checkpoint size boundary is separate from ordinary configuration limit" {
  let config = "{\"session_id\":\"limits\",\"mode\":\"ground\"}"
  let session = @codec.ReplaySession::new(config)
  let checkpoint = session.checkpoint_json()
  let padded = checkpoint + " ".repeat(8388608 - checkpoint.length())
  let restored = @codec.ReplaySession::from_checkpoint_json(padded)
  assert_eq(restored.checkpoint_json(), checkpoint)
  let envelope = "{\"resume\":" + padded + "}"
  let resumed = @codec.ReplaySession::open(envelope)
  assert_eq(resumed.checkpoint_json(), checkpoint)
  try @codec.ReplaySession::open("{\"resume\":" + padded + " }") catch {
    _ => ()
  } noraise {
    _ => fail("oversize resume envelope accepted")
  }
  try @codec.ReplaySession::from_checkpoint_json(padded + " ") catch {
    _ => ()
  } noraise {
    _ => fail("oversize checkpoint accepted")
  }
  let ordinary = config + " ".repeat(1048577 - config.length())
  try @codec.ReplaySession::open(ordinary) catch {
    _ => ()
  } noraise {
    _ => fail("ordinary configuration used checkpoint size limit")
  }
  let nested = "[".repeat(33) + "0" + "]".repeat(33)
  try @codec.ReplaySession::from_checkpoint_json(nested) catch {
    _ => ()
  } noraise {
    _ => fail("over-depth checkpoint accepted")
  }
}

///|
test "checkpoint active-track limit applies before export and during restore" {
  let session = @codec.ReplaySession::new(
    "{\"session_id\":\"capacity\",\"mode\":\"ground\",\"motion\":{\"max_tracks\":10001}}",
  )
  let observations = Array::makei(10001, i => {
    Json::object({ "track_id": Json(i + 1), "point": Json([0.0, 0.0]) })
  })
  ignore(
    session.process_line(
      Json::object({
        "timestamp_us": Json("0"),
        "observations": Json(observations),
      }).stringify(),
    ),
  )
  try session.checkpoint_json() catch {
    _ => ()
  } noraise {
    _ => fail("checkpoint exported more than 10000 active tracks")
  }
  // A failed export does not advance time or discard the active tracks.
  ignore(
    session.process_line(
      "{\"timestamp_us\":\"1\",\"observations\":[],\"removed\":[10001]}",
    ),
  )
  let checkpoint = session.checkpoint_json()
  let fields = checkpoint_object(checkpoint)
  guard fields.get("motion") is Some(Object(motion)) else {
    fail("missing motion")
  }
  guard motion.get("tracks") is Some(Array(tracks)) else {
    fail("missing tracks")
  }
  tracks.push(tracks[0])
  try
    @codec.ReplaySession::from_checkpoint_json(Json::object(fields).stringify())
  catch {
    _ => ()
  } noraise {
    _ => fail("checkpoint restored more than 10000 active tracks")
  }
}
