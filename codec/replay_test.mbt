///|
test "wire nulls, flat diagnostics and exact large timestamps" {
  let session = @codec.ReplaySession::new(
    "{\"session_id\":\"oracle\",\"mode\":\"ground\",\"diagnostics\":true}",
  )
  let first = @json.parse(
    session.process_line(
      "{\"timestamp_us\":\"9007199254740993\",\"observations\":[{\"track_id\":1,\"point\":[0,0]}]}",
    ),
  )
  assert_true(
    first
    is {
      "timestamp_us": String("9007199254740993"),
      "tracks": [
        {
          "speed_mps": Null,
          "velocity_mps": Null,
          "filter_state": [_, _, _, _],
          "filter_covariance": [_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _],
          ..
        },
      ],
      ..
    },
  )
  ignore(
    session.process_line(
      "{\"timestamp_us\":\"9007199254940993\",\"observations\":[{\"track_id\":1,\"point\":[0.2,0]}]}",
    ),
  )
  let ready = @json.parse(
    session.process_line(
      "{\"timestamp_us\":\"9007199255140993\",\"observations\":[{\"track_id\":1,\"point\":[0.4,0]}]}",
    ),
  )
  assert_true(
    ready
    is {
      "tracks": [
        {
          "status": String("ready"),
          "speed_mps": Number(_, ..),
          "velocity_mps": [_, _],
          ..
        },
      ],
      ..
    },
  )
}

///|
test "invalid codec frame does not consume time" {
  let session = @codec.ReplaySession::new(
    "{\"session_id\":\"strict\",\"mode\":\"ground\"}",
  )
  for
    source in [
      "{\"timestamp_us\":0,\"observations\":[]}", "{\"timestamp_us\":\"00\",\"observations\":[]}",
      "{\"timestamp_us\":\"0\",\"timestamp_us\":\"1\",\"observations\":[]}", "{\"timestamp_us\":\"0\",\"observations\":[{\"track_id\":1.5,\"point\":[0,0]}]}",
      "{\"timestamp_us\":\"0\",\"observations\":[],\"typo\":1}", "{\"timestamp_us\":\"0\",\"observations\":[{\"track_id\":1,\"point\":[0,0],\"covariance\":[1,2,1]}]}",
    ] {
    try session.process_line(source) catch {
      _ => ()
    } noraise {
      _ => fail("invalid wire frame accepted")
    }
  }
  let accepted = @json.parse(
    session.process_line("{\"timestamp_us\":\"0\",\"observations\":[]}"),
  )
  assert_true(accepted is { "timestamp_us": String("0"), "tracks": [], .. })
}

///|
test "projection wire returns unwrapped covariance" {
  let result = @json.parse(
    @codec.project_json(
      "{\"calibration\":{\"matrix\":[0.02,0,0,0,0.02,0,0,0,1],\"roi\":[[0,0],[100,0],[100,100],[0,100]]},\"points\":[{\"point\":[20,30],\"covariance\":[4,0,4]}]}",
    ),
  )
  assert_true(
    result
    is {
      "points": [
        {
          "position_m": [_, _],
          "covariance": [_, _, _],
          "jacobian": [_, _, _, _],
          ..
        },
      ],
      ..
    },
  )
}
