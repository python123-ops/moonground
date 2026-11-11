///|
test "identity camera composes projection and readiness limits over wire" {
  let result = @json.parse(
    @codec.project_json(
      "{\"camera\":{\"fx\":100,\"fy\":80,\"cx\":50,\"cy\":50},\"calibration\":{\"matrix\":[0.02,0,0,0,0.02,0,0,0,1],\"roi\":[[0,0],[100,0],[100,100],[0,100]]},\"points\":[{\"point\":[20,30],\"covariance\":[4,0,4]}]}",
    ),
  )
  assert_true(
    result
    is { "points": [{ "position_m": [Number(x, ..), Number(y, ..)], .. }], .. } &&
    (x - 0.4).abs() < 1.0e-12 &&
    (y - 0.6).abs() < 1.0e-12,
  )
  let session = @codec.ReplaySession::new(
    "{\"session_id\":\"quality\",\"mode\":\"ground\",\"motion\":{\"min_observations\":2,\"min_span_us\":\"0\",\"max_velocity_std_mps\":0.000001}}",
  )
  ignore(
    session.process_line(
      "{\"timestamp_us\":\"0\",\"observations\":[{\"track_id\":1,\"point\":[0,0]}]}",
    ),
  )
  let result = @json.parse(
    session.process_line(
      "{\"timestamp_us\":\"100000\",\"observations\":[{\"track_id\":1,\"point\":[0,0]}]}",
    ),
  )
  assert_true(
    result
    is {
      "schema_version": String("0.2.0"),
      "tracks": [
        {
          "status": String("uncertain"),
          "speed_mps": Null,
          "velocity_mps": [_, _],
          "position_std_m": Number(_, ..),
          "velocity_std_mps": Number(_, ..),
          ..
        },
      ],
      ..
    },
  )
}

///|
test "camera and uncertainty configuration reject typos null and wrong mode" {
  for
    input in [
      "{\"session_id\":\"x\",\"mode\":\"ground\",\"camera\":{\"fx\":100,\"fy\":100,\"cx\":0,\"cy\":0}}",
      "{\"session_id\":\"x\",\"mode\":\"ground\",\"motion\":{\"max_position_std_m\":null}}",
      "{\"session_id\":\"x\",\"mode\":\"ground\",\"motion\":{\"max_velocity_std_mps\":0}}",
      "{\"session_id\":\"x\",\"camera\":{\"fx\":100,\"fy\":100,\"cx\":0,\"cy\":0,\"fisheye\":true}}",
    ] {
    try @codec.ReplaySession::new(input) catch {
      _ => ()
    } noraise {
      _ => fail("invalid configuration accepted")
    }
  }
}
