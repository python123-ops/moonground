///|
test "integer wire fields accept exact decimal and exponent equivalents" {
  for
    token in [
      "4",
      "4.0",
      "4e0",
      "40e-1",
      "0.04e2",
      "4000e-3",
      "4e+0000",
      "4.0000000000000000000000000000000",
      "0." + "0".repeat(1000) + "4e1001",
      "4" + "0".repeat(1000) + "e-1000",
    ] {
    let session = @codec.ReplaySession::new(
      "{\"session_id\":\"exact-integer\",\"mode\":\"ground\",\"motion\":{\"min_observations\":" +
      token +
      ",\"max_tracks\":" +
      token +
      "}}",
    )
    for time in 0..<4 {
      let result = @json.parse(
        session.process_line(
          "{\"timestamp_us\":\"" +
          time.to_string() +
          "\",\"observations\":[{\"track_id\":" +
          token +
          ",\"point\":[0,0]}]}",
        ),
      )
      assert_true(
        result is { "tracks": [{ "track_id": Number(4, ..), .. }], .. },
      )
    }
    let fields = checkpoint_object(session.checkpoint_json())
    guard fields.get("motion") is Some(Object(motion)) else {
      fail("missing motion")
    }
    guard motion.get("tracks") is Some(Array([Object(track)])) else {
      fail("missing track")
    }
    track["accepted_count"] = Json::number(4.0, repr=token)
    track["track_id"] = Json::number(4.0, repr=token)
    let restored = @codec.ReplaySession::from_checkpoint_json(
      Json::object(fields).stringify(),
    )
    assert_eq(restored.checkpoint_json(), session.checkpoint_json())
  }
}

///|
test "integer wire fields reject fractions hidden by Double rounding" {
  for
    token in [
      "4.0000000000000000001", "3.9999999999999999999", "2147483647.0000001", "2147483646.99999999999999999",
      "4e9999999999999999999999999999999999", "4e-9999999999999999999999999999999999",
    ] {
    for field in ["min_observations", "max_tracks"] {
      try
        @codec.ReplaySession::new(
          "{\"session_id\":\"fraction\",\"mode\":\"ground\",\"motion\":{\"" +
          field +
          "\":" +
          token +
          "}}",
        )
      catch {
        _ => ()
      } noraise {
        _ => fail("fractional configuration integer accepted")
      }
    }
    let session = @codec.ReplaySession::new(
      "{\"session_id\":\"fraction\",\"mode\":\"ground\"}",
    )
    try
      session.process_line(
        "{\"timestamp_us\":\"0\",\"observations\":[{\"track_id\":" +
        token +
        ",\"point\":[0,0]}]}",
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("fractional track identity accepted")
    }
    try
      session.process_line(
        "{\"timestamp_us\":\"0\",\"observations\":[],\"lost\":[" + token + "]}",
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("fractional lifecycle identity accepted")
    }
    for time in 0..<4 {
      ignore(session.process_line(checkpoint_frame(time.to_string(), 0.0)))
    }
    let fields = checkpoint_object(session.checkpoint_json())
    guard fields.get("motion") is Some(Object(motion)) else {
      fail("missing motion")
    }
    guard motion.get("tracks") is Some(Array([Object(track)])) else {
      fail("missing track")
    }
    track["accepted_count"] = Json::number(4.0, repr=token)
    try
      @codec.ReplaySession::from_checkpoint_json(
        Json::object(fields).stringify(),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("fractional accepted count accepted")
    }
  }
}

///|
test "exact integer token validation retains the positive Int32 endpoint" {
  for token in ["2147483647", "2147483647.0", "2147483647000e-3"] {
    let session = @codec.ReplaySession::new(
      "{\"session_id\":\"int32-endpoint\",\"mode\":\"ground\"}",
    )
    let output = @json.parse(
      session.process_line(
        "{\"timestamp_us\":\"0\",\"observations\":[{\"track_id\":" +
        token +
        ",\"point\":[0,0]}]}",
      ),
    )
    assert_true(
      output is { "tracks": [{ "track_id": Number(2147483647, ..), .. }], .. },
    )
  }
}
