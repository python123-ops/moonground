///|
fn run_protocol_source(options~ : String = "{}") -> String {
  Json::object({
    "position": Json(zone_test_source(k=0.0)),
    "options": Json(options),
  }).stringify()
}

///|
fn run_protocol_line(
  time : Int64,
  x~ : Double = 0.5,
  assignments~ : Bool = true,
) -> String raise {
  assigned_zone_test_line(
    zone_test_frame(time, x, 0.5),
    assigned_zone_test_document(
      if assignments {
        "[" + assigned_zone_test_disk() + "]"
      } else {
        "[]"
      },
      timestamp=time.to_string(),
    ),
  )
}

///|
test "footprint runs preserve original current evidence and confirm the conjunct once" {
  let source = run_protocol_source(
    options="{\"max_gap_us\":\"100\",\"confirmation_us\":\"10\",\"min_samples\":\"2\"}",
  )
  let replay = @codec.FootprintRunReplay::open(source)
  let line = run_protocol_line(0L)
  let original = @json.parse(
    @codec.AssignedZoneEvidenceReplay::open(zone_test_source(k=0.0)).process_line(
      line,
    ),
  )
  guard @json.parse(replay.process_line(line))
    is {
      "evidence": evidence,
      "active": [
        {
          "sample_count": String("1"),
          "sample_span_us": String("0"),
          "confirmed": False,
          ..
        },
      ],
      "confirmed": [],
      ..
    } else {
    fail("initial sample differs")
  }
  assert_eq(evidence, original)
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(9L)))
    is {
      "confirmed": [],
      "active": [{ "sample_count": String("2"), "confirmed": False, .. }],
      ..
    },
  )
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(10L)))
    is {
      "confirmed": [
        {
          "sample_count": String("3"),
          "sample_span_us": String("10"),
          "confirmed": True,
          ..
        },
      ],
      ..
    },
  )
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(11L)))
    is { "confirmed": [], "active": [{ "confirmed": True, .. }], .. },
  )
}

///|
test "footprint run absence of assignment closes without inventing an outside sample" {
  let replay = @codec.FootprintRunReplay::open(run_protocol_source())
  ignore(replay.process_line(run_protocol_line(0L)))
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(10L, assignments=false)))
    is {
      "active": [],
      "confirmed": [],
      "closed": [
        {
          "reason": String("unavailable_evidence"),
          "closed_at_timestamp_us": String("10"),
          "run": {
            "last_timestamp_us": String("0"),
            "sample_span_us": String("0"),
            ..
          },
          ..
        },
      ],
      "evidence": {
        "unavailable": [{ "reason": String("missing_footprint"), .. }],
        ..
      },
      ..
    },
  )
}

///|
test "complete footprint run checkpoint resumes an unfinished confirmation without replay" {
  let replay = @codec.FootprintRunReplay::open(
    run_protocol_source(options="{\"confirmation_us\":\"10\"}"),
  )
  ignore(replay.process_line(run_protocol_line(9007199254740993L)))
  let checkpoint = replay.checkpoint_json()
  let restored = @codec.FootprintRunReplay::open(
    "{\"resume\":" + checkpoint + "}",
  )
  let next = run_protocol_line(9007199254741003L)
  assert_eq(restored.process_line(next), replay.process_line(next))
  assert_eq(restored.checkpoint_json(), replay.checkpoint_json())
  assert_true(
    @json.parse(restored.checkpoint_json())
    is {
      "last_timestamp_us": String("9007199254741003"),
      "states": [
        { "run": { "sample_count": String("2"), "confirmed": True, .. }, .. },
      ],
      ..
    },
  )
}

///|
test "bad run frame and equal timestamp leave checkpoint intact for corrected retry" {
  let replay = @codec.FootprintRunReplay::open(run_protocol_source())
  ignore(replay.process_line(run_protocol_line(1L)))
  let original = replay.checkpoint_json()
  for
    line in [
      run_protocol_line(1L),
      assigned_zone_test_line(
        zone_test_frame(2L, 0.5, 0.5),
        assigned_zone_test_document("[]", timestamp="3"),
      ),
    ] {
    try replay.process_line(line) catch {
      _ => ()
    } noraise {
      _ => fail("invalid run input accepted")
    }
    assert_eq(replay.checkpoint_json(), original)
  }
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(2L)))
    is { "active": [{ "sample_count": String("2"), .. }], .. },
  )
}

///|
test "run source and options retain strict raw token and unknown field validation" {
  for
    options in [
      "{\"min_samples\":2}", "{\"min_samples\":\"0\"}", "{\"min_samples\":\"02\"}",
      "{\"max_gap_us\":\"0\"}", "{\"confirmation_us\":\"-1\"}", "{\"min_samples\":\"2\",\"min_samples\":\"3\"}",
      "{\"extra\":true}",
    ] {
    try @codec.FootprintRunReplay::open(run_protocol_source(options~)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid options accepted")
    }
  }
  try
    @codec.FootprintRunReplay::open(
      "{\"position\":\"{}\",\"options\":\"{}\",\"extra\":0}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("unknown source field accepted")
  }
}

///|
test "run checkpoint rejects altered last decision and raw fractional identities" {
  let replay = @codec.FootprintRunReplay::open(run_protocol_source())
  ignore(replay.process_line(run_protocol_line(0L)))
  for
    replacement in [
      replay
      .checkpoint_json()
      .replace(old="\"decision\":\"inside\"", new="\"decision\":\"outside\""),
      replay
      .checkpoint_json()
      .replace(old="\"track_id\":7", new="\"track_id\":7.000000000000000001"),
      replay
      .checkpoint_json()
      .replace(old="\"confirmed\":false", new="\"confirmed\":true"),
    ] {
    try
      @codec.FootprintRunReplay::open("{\"resume\":" + replacement + "}")
    catch {
      _ => ()
    } noraise {
      _ => fail("altered checkpoint accepted")
    }
  }
}

///|
test "pure footprint run batch includes complete final state and rejects reversed frames" {
  let source = run_protocol_source()
  let request = fn(frames) {
    Json::object({ "source": Json(source), "frames": Json(frames) }).stringify()
  }
  assert_true(
    @json.parse(@codec.footprint_runs_json(request("")))
    is {
      "frames": [],
      "checkpoint": { "last_timestamp_us": Null, "states": [], .. },
      ..
    },
  )
  assert_true(
    @json.parse(
      @codec.footprint_runs_json(
        request(run_protocol_line(1L) + "\r\n" + run_protocol_line(2L) + "\n"),
      ),
    )
    is {
      "frames": [_, _],
      "checkpoint": { "last_timestamp_us": String("2"), .. },
      ..
    },
  )
  try
    @codec.footprint_runs_json(
      request(run_protocol_line(2L) + "\n" + run_protocol_line(1L)),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("reverse batch accepted")
  }
}

///|
test "run exact gap terminates old sample span and seeds a new independent run" {
  let replay = @codec.FootprintRunReplay::open(
    run_protocol_source(
      options="{\"max_gap_us\":\"10\",\"confirmation_us\":\"0\",\"min_samples\":\"1\"}",
    ),
  )
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(0L)))
    is { "confirmed": [_], .. },
  )
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(10L)))
    is {
      "closed": [
        {
          "reason": String("gap_exceeded"),
          "run": {
            "first_timestamp_us": String("0"),
            "last_timestamp_us": String("0"),
            ..
          },
          ..
        },
      ],
      "confirmed": [
        { "first_timestamp_us": String("10"), "sample_count": String("1"), .. },
      ],
      ..
    },
  )
}
