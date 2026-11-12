///|
fn reframe_source_config() -> String {
  "{\"session_id\":\"reframe-test\",\"mode\":\"pixel\",\"diagnostics\":true,\"calibration\":{\"matrix\":[0.02,0,0,0,0.02,0,0,0,1],\"roi\":[[0,0],[100,0],[100,100],[0,100]]}}"
}

///|
fn reframe_test_header(source : String, transform : String) -> String {
  "{\"source\":" + source + ",\"transform\":" + transform + "}"
}

///|
fn reframe_test_frame(time : String, x~ : String = "20") -> String {
  "{\"timestamp_us\":\"" +
  time +
  "\",\"observations\":[{\"track_id\":7,\"point\":[" +
  x +
  ",30]}]}"
}

///|
test "reframing makes the original default pixel uncertainty explicit" {
  let converter = @codec.ReplayReframer::new(
    reframe_test_header(
      reframe_source_config(),
      "{\"scale_x\":0.5,\"scale_y\":2,\"offset_x\":-20,\"offset_y\":10}",
    ),
  )
  let frame = @json.parse(converter.process_line(reframe_test_frame("0")))
  assert_true(
    frame
    is {
      "timestamp_us": String("0"),
      "observations": [
        {
          "track_id": Number(7, ..),
          "point": [Number(-10, ..), Number(70, ..)],
          "covariance": [Number(1, ..), Number(0, ..), Number(16, ..)],
          ..
        },
      ],
      "lost": [],
      "removed": [],
      ..
    },
  )
  let replay = @codec.ReplaySession::open(converter.header_line())
  let measured = @json.parse(replay.process_line(frame.stringify()))
  assert_true(
    measured is { "tracks": [{ "accepted_count": Number(1, ..), .. }], .. },
  )
}

///|
test "reframing a checkpoint preserves every metric state value and the frame watermark" {
  let source = @codec.ReplaySession::new(reframe_source_config())
  ignore(source.process_line(reframe_test_frame("0")))
  ignore(source.process_line(reframe_test_frame("200000", x="25")))
  ignore(source.process_line(reframe_test_frame("400000", x="30")))
  let saved = source.checkpoint_json()
  let converter = @codec.ReplayReframer::new(
    reframe_test_header(
      "{\"resume\":" + saved + "}",
      "{\"scale_x\":0.5,\"scale_y\":2}",
    ),
  )
  guard @json.parse(saved) is Object(original) else {
    fail("missing checkpoint")
  }
  guard @json.parse(converter.header_line())
    is { "resume": Object(resumed), .. } else {
    fail("resume header was lost")
  }
  assert_eq(original.get("motion"), resumed.get("motion"))
  let replay = @codec.ReplaySession::open(converter.header_line())
  try converter.process_line(reframe_test_frame("400000", x="30")) catch {
    _ => ()
  } noraise {
    _ => fail("source frame time was not preserved")
  }
  let converted = converter.process_line(reframe_test_frame("600000", x="35"))
  assert_true(
    @json.parse(replay.process_line(converted))
    is {
      "tracks": [
        { "accepted_count": Number(4, ..), "segment_id": String("1"), .. },
      ],
      ..
    },
  )
}

///|
test "failed numeric conversion and invalid identities leave the original frame reusable" {
  let converter = @codec.ReplayReframer::new(
    reframe_test_header(reframe_source_config(), "{\"scale_x\":4}"),
  )
  for
    frame in [
      reframe_test_frame("0", x="1e308"),
      "{\"timestamp_us\":\"0\",\"observations\":[{\"track_id\":1.0000000000000000001,\"point\":[20,30]}]}",
      "{\"timestamp_us\":\"0\",\"observations\":[{\"track_id\":7,\"point\":[20,30]}],\"lost\":[7]}",
    ] {
    try converter.process_line(frame) catch {
      _ => ()
    } noraise {
      _ => fail("invalid frame was converted")
    }
  }
  assert_true(
    @json.parse(converter.process_line(reframe_test_frame("0")))
    is { "timestamp_us": String("0"), .. },
  )
}

///|
test "reframing rejects nonpixel sessions malformed transforms and unknown fields" {
  let source = reframe_source_config()
  for
    transform in [
      "null", "[]", "{\"scale_x\":0}", "{\"scale_y\":-1}", "{\"offset_x\":1e999}",
      "{\"scale_x\":1,\"scale_x\":2}", "{\"rotation\":90}",
    ] {
    try
      @codec.ReplayReframer::new(reframe_test_header(source, transform))
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid transformation accepted")
    }
  }
  try
    @codec.ReplayReframer::new(
      reframe_test_header(
        "{\"session_id\":\"ground\",\"mode\":\"ground\"}", "{}",
      ),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("metres were transformed as pixels")
  }
  try
    @codec.ReplayReframer::new(
      "{\"source\":" + source + ",\"transform\":{},\"ignored\":true}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("unknown header field accepted")
  }
}

///|
test "bounded raw NDJSON conversion handles CRLF and rejects later errors atomically" {
  let source = reframe_source_config() +
    "\r\n" +
    reframe_test_frame("0") +
    "\r\n" +
    reframe_test_frame("200000")
  let response = @json.parse(
    @codec.reframe_json(
      Json::object({ "ndjson": Json(source), "transform": Json::empty_object() }).stringify(),
    ),
  )
  guard response
    is { "ndjson": String(converted), "frame_count": Number(2, ..), .. } else {
    fail("missing converted stream")
  }
  let lines = converted.split("\n").collect()
  let replay = @codec.ReplaySession::open(lines[0].to_owned())
  ignore(replay.process_line(lines[1].to_owned()))
  ignore(replay.process_line(lines[2].to_owned()))
  try
    @codec.reframe_json(
      Json::object({
        "ndjson": Json(source + "\n{}\n"),
        "transform": Json::empty_object(),
      }).stringify(),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("bad later frame accepted")
  }
  let empty_source = @json.parse(
    @codec.reframe_json(
      Json::object({
        "ndjson": Json(reframe_source_config() + "\n"),
        "transform": Json::empty_object(),
      }).stringify(),
    ),
  )
  assert_true(empty_source is { "frame_count": Number(0, ..), .. })
}
