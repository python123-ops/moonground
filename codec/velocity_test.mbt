///|
fn velocity_test_source(
  threshold~ : Double = 1.0,
  multiplier~ : Double = 2.0,
) -> String {
  Json::object({
    "session_id": Json("evidence-test"),
    "probes": Json([
      Json::object({
        "probe_id": Json("east"),
        "direction": Json([1.0, 0.0]),
        "threshold_mps": Json(threshold),
        "sigma_multiplier": Json(multiplier),
      }),
    ]),
  }).stringify()
}

///|
fn velocity_test_frame(
  time : Int64,
  vx~ : Double = 2.0,
  status~ : String = "ready",
) -> String raise {
  let value = @json.parse(evidence_test_frame(time, 0.0))
  guard value is { "tracks": [Object(track)], .. } else {
    fail("track fixture missing")
  }
  track["status"] = Json(status)
  track["accepted_count"] = Json(3)
  track["velocity_mps"] = Json([vx, 0.0])
  track["velocity_covariance"] = Json([0.04, 0.0, 0.09])
  track["velocity_std_mps"] = Json(0.3)
  track["speed_mps"] = if status == "ready" {
    Json(vx.abs())
  } else {
    Json::null()
  }
  value.stringify()
}

///|
test "velocity evidence uses the directed covariance block and closed threshold equality" {
  let raw = velocity_test_frame(9007199254740993L)
  for
    (threshold, decision) in [
      (1.0, "above"),
      (1.6, "indeterminate"),
      (2.4, "at_or_below"),
    ] {
    let result = @json.parse(
      @codec.VelocityEvidenceReplay::open(velocity_test_source(threshold~)).process_line(
        raw,
      ),
    )
    assert_true(
      result
      is {
        "timestamp_us": String("9007199254740993"),
        "evidence": [
          {
            "component_mps": Number(2, ..),
            "axis_std_mps": Number(0.2, ..),
            "lower_mps": Number(1.6, ..),
            "upper_mps": Number(2.4, ..),
            ..
          },
        ],
        "unavailable": [],
        ..
      },
    )
    guard result is { "evidence": [{ "decision": String(actual), .. }], .. } else {
      fail("decision missing")
    }
    assert_eq(actual, decision)
  }
  assert_true(
    @json.parse(
      @codec.VelocityEvidenceReplay::open(
        velocity_test_source(threshold=2.0, multiplier=0.0),
      ).process_line(raw),
    )
    is {
      "evidence": [
        {
          "lower_mps": Number(2, ..),
          "upper_mps": Number(2, ..),
          "decision": String("at_or_below"),
          ..
        },
      ],
      ..
    },
  )
}

///|
test "velocity frames are independent repeated reordered evaluations and have no checkpoint" {
  let replay = @codec.VelocityEvidenceReplay::open(velocity_test_source())
  let later = velocity_test_frame(20L)
  let first = replay.process_line(later)
  ignore(replay.process_line(velocity_test_frame(10L, vx=-2.0)))
  assert_eq(replay.process_line(later), first)
  assert_true(
    @json.parse(
      @codec.velocity_evidence_json(
        Json::object({
          "source": Json(velocity_test_source()),
          "measurements": Json(""),
        }).stringify(),
      ),
    )
    is { "frames": [], .. },
  )
}

///|
test "velocity admission preserves warmup quality rejection and projection failure identities" {
  let replay = @codec.VelocityEvidenceReplay::open(velocity_test_source())
  assert_true(
    @json.parse(replay.process_line(evidence_test_frame(0L, 0.0)))
    is {
      "evidence": [],
      "unavailable": [
        { "track_id": Number(7, ..), "reason": String("initializing"), .. },
      ],
      ..
    },
  )
  assert_true(
    @json.parse(
      replay.process_line(velocity_test_frame(10L, status="uncertain")),
    )
    is {
      "evidence": [],
      "unavailable": [{ "reason": String("uncertain"), .. }],
      ..
    },
  )
  let value = @json.parse(evidence_test_frame(20L, 0.0))
  guard value is { "tracks": Array(tracks), .. } else { fail("tracks missing") }
  tracks.push(
    Json::object({
      "track_id": Json(8),
      "segment_id": Json::null(),
      "status": Json("rejected_projection"),
      "reason": Json("outside_roi"),
      "position_m": Json::null(),
      "position_covariance": Json::null(),
      "velocity_mps": Json::null(),
      "velocity_covariance": Json::null(),
      "position_std_m": Json::null(),
      "velocity_std_mps": Json::null(),
      "speed_mps": Json::null(),
    }),
  )
  assert_true(
    @json.parse(replay.process_line(value.stringify()))
    is {
      "evidence": [],
      "unavailable": [
        _,
        {
          "track_id": Number(8, ..),
          "segment_id": Null,
          "reason": String("rejected_projection"),
          ..
        },
      ],
      ..
    },
  )
}

///|
test "velocity protocol rejects stale Ready values raw fractional identities and duplicate configuration" {
  let replay = @codec.VelocityEvidenceReplay::open(velocity_test_source())
  let raw = velocity_test_frame(10L)
  let saved = @json.parse(raw)
  guard saved is { "tracks": [Object(track)], .. } else {
    fail("track missing")
  }
  track["last_accepted_timestamp_us"] = Json("9")
  for
    bad in [
      saved.stringify(),
      raw.replace(old="\"track_id\":7", new="\"track_id\":7.0000000000000001"),
      raw.replace(old="\"timestamp_us\":\"10\"", new="\"timestamp_us\":\"01\""),
    ] {
    try replay.process_line(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid current frame accepted")
    }
  }
  assert_true(@json.parse(replay.process_line(raw)) is { "evidence": [_], .. })
  for
    bad in [
      velocity_test_source().replace(old="{", new="{\"session_id\":\"bad\","),
      "{\"resume\":{}}",
      "{\"session_id\":\"x\",\"probes\":[]}",
    ] {
    try @codec.VelocityEvidenceReplay::open(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid configuration accepted")
    }
  }
}

///|
test "velocity numeric rejection preserves reusable independent evaluation and failed batch returns no prefix" {
  let replay = @codec.VelocityEvidenceReplay::open(
    velocity_test_source(multiplier=1.0e308),
  )
  let normal = @codec.VelocityEvidenceReplay::open(velocity_test_source())
  let raw = velocity_test_frame(10L)
  let huge = @json.parse(raw)
  guard huge is { "tracks": [Object(track)], .. } else { fail("track missing") }
  track["velocity_covariance"] = Json([4.0, 0.0, 9.0])
  track["velocity_std_mps"] = Json(3.0)
  try replay.process_line(huge.stringify()) catch {
    _ => ()
  } noraise {
    _ => fail("overflowing band accepted")
  }
  assert_true(@json.parse(normal.process_line(raw)) is { "evidence": [_], .. })
  let request = Json::object({
    "source": Json(velocity_test_source()),
    "measurements": Json(raw + "\n{}"),
  }).stringify()
  try @codec.velocity_evidence_json(request) catch {
    _ => ()
  } noraise {
    _ => fail("invalid batch exposed a prefix")
  }
}

///|
test "velocity pure request preserves CRLF final EOF and original measurement bytes" {
  let frames = [
    evidence_test_frame(0L, 0.0),
    velocity_test_frame(10L),
    velocity_test_frame(5L, vx=-2.0),
  ]
  let request = (text : String) => {
    Json::object({
      "source": Json(velocity_test_source()),
      "measurements": Json(text),
    }).stringify()
  }
  let expected = @codec.velocity_evidence_json(request(frames.join("\n")))
  assert_eq(
    expected,
    @codec.velocity_evidence_json(request(frames.join("\r\n") + "\r\n")),
  )
  assert_true(@json.parse(expected) is { "frames": [_, _, _], .. })
}
