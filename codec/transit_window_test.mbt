///|
fn window_test_source(width~ : Int64 = 200000L, origin~ : Int64 = 0L) -> String {
  Json::object({
    "transit": Json(transit_analysis_test_transit()),
    "window_us": Json(width.to_string()),
    "origin_us": Json(origin.to_string()),
    "duration_limits_us": Json(["0", "100000", "200000", "9223372036854775807"]),
  }).stringify()
}

///|
fn window_test_frames(base~ : Int64 = 0L) -> Array[String] raise {
  let upstream = @codec.EvidenceTransitAnalysisReplay::open(
    transit_analysis_test_source(),
  )
  [-1.0, 1.0, 3.0].mapi((index, x) => {
    guard @json.parse(
        upstream.process_line(
          transit_analysis_test_frame(base + index.to_int64() * 100000L, x),
        ),
      )
      is { "transit": frame, .. } else {
      fail("transit fixture missing")
    }
    frame.stringify()
  })
}

///|
test "window protocol classifies closed elapsed bounds in the exit confirmation bucket" {
  let replay = @codec.EvidenceTransitWindowReplay::open(window_test_source()) catch {
    error => fail("open: " + error.message())
  }
  let frames = window_test_frames()
  ignore(
    replay.process_line(frames[0]) catch {
      error => fail("first: " + error.message())
    },
  )
  ignore(
    replay.process_line(frames[1]) catch {
      error => fail("second: " + error.message())
    },
  )
  let frame = @json.parse(
    replay.process_line(frames[2]) catch {
      error => fail("third: " + error.message())
    },
  )
  assert_true(
    frame
    is {
      "kind": String("evidence_transit_window_frame"),
      "classification_scope": String("observed_chord_elapsed_bounds"),
      "closed_window": {
        "start_us": String("0"),
        "end_exclusive_us": String("200000"),
        "input_frames": String("2"),
        ..
      },
      "current_window": {
        "start_us": String("200000"),
        "input_frames": String("1"),
        "sections": [
          {
            "completed": String("1"),
            "duration_limits": [
              {
                "limit_us": String("0"),
                "within": String("0"),
                "exceeded": String("0"),
                "indeterminate": String("1"),
                ..
              },
              {
                "limit_us": String("100000"),
                "within": String("0"),
                "indeterminate": String("1"),
                ..
              },
              { "limit_us": String("200000"), "within": String("1"), .. },
              {
                "limit_us": String("9223372036854775807"),
                "within": String("1"),
                ..
              },
            ],
            ..
          },
        ],
        ..
      },
      "unobserved_windows": String("0"),
      ..
    },
  )
}

///|
test "window counter restores every cut without refilling old completed totals" {
  let frames = window_test_frames(base=9007199254740993L)
  let full = @codec.EvidenceTransitWindowReplay::open(
    window_test_source(width=130001L),
  )
  let expected = frames.map(frame => full.process_line(frame))
  for cut in 0..<=frames.length() {
    let prefix = @codec.EvidenceTransitWindowReplay::open(
      window_test_source(width=130001L),
    )
    for index in 0..<cut {
      ignore(prefix.process_line(frames[index]))
    }
    let restored = @codec.EvidenceTransitWindowReplay::open(
      "{\"resume\":" + prefix.checkpoint_json() + "}",
    )
    for index in cut..<frames.length() {
      assert_eq(restored.process_line(frames[index]), expected[index])
    }
    assert_eq(restored.checkpoint_json(), full.checkpoint_json())
  }
}

///|
test "started upstream checkpoint seeds only the watermark and counts while a pending entry completes later" {
  let upstream = @codec.EvidenceTransitAnalysisReplay::open(
    transit_analysis_test_source(),
  )
  for index, x in [-1.0, 1.0] {
    ignore(
      upstream.process_line(
        transit_analysis_test_frame(index.to_int64() * 100000L, x),
      ),
    )
  }
  guard @json.parse(upstream.checkpoint_json()) is { "transit": saved, .. } else {
    fail("upstream checkpoint missing")
  }
  let header = @json.parse(window_test_source())
  guard header is Object(fields) else { fail("window header missing") }
  fields["transit"] = Json(Json::object({ "resume": saved }).stringify())
  let replay = @codec.EvidenceTransitWindowReplay::open(header.stringify())
  assert_true(
    @json.parse(replay.checkpoint_json())
    is {
      "baseline_timestamp_us": String("100000"),
      "last_timestamp_us": String("100000"),
      "current_window": Null,
      ..
    },
  )
  guard @json.parse(
      upstream.process_line(transit_analysis_test_frame(200000L, 3.0)),
    )
    is { "transit": frame, .. } else {
    fail("completion missing")
  }
  assert_true(
    @json.parse(replay.process_line(frame.stringify()))
    is {
      "closed_window": Null,
      "unobserved_windows": String("0"),
      "current_window": {
        "input_frames": String("1"),
        "sections": [{ "completed": String("1"), .. }],
        ..
      },
      ..
    },
  )
}

///|
test "late malformed completion preserves rollover and accepts corrected same time" {
  let frames = window_test_frames()
  let replay = @codec.EvidenceTransitWindowReplay::open(window_test_source())
  ignore(replay.process_line(frames[0]))
  ignore(replay.process_line(frames[1]))
  let saved = replay.checkpoint_json()
  let malformed = @json.parse(frames[2])
  guard malformed is Object(fields) else { fail("completion missing") }
  fields["passages"] = Json::array([])
  try replay.process_line(malformed.stringify()) catch {
    _ => ()
  } noraise {
    _ => fail("omitted completion accepted")
  }
  assert_eq(replay.checkpoint_json(), saved)
  ignore(replay.process_line(frames[2]))
  let accepted = replay.checkpoint_json()
  try replay.process_line(frames[2]) catch {
    _ => ()
  } noraise {
    _ => fail("duplicate timestamp accepted")
  }
  assert_eq(replay.checkpoint_json(), accepted)
}

///|
test "window protocol rejects altered estimates raw decimals duplicate keys and mismatched evidence policy atomically" {
  let frames = window_test_frames()
  let replay = @codec.EvidenceTransitWindowReplay::open(window_test_source())
  ignore(replay.process_line(frames[0]))
  ignore(replay.process_line(frames[1]))
  let saved = replay.checkpoint_json()
  let bad_estimate = @json.parse(frames[2])
  guard bad_estimate is { "passages": [Object(passage)], .. } else {
    fail("passage missing")
  }
  passage["estimated_elapsed_us"] = Json(1.0)
  let wrong_policy = @json.parse(frames[2])
  guard wrong_policy is { "counting": Object(evidence), .. } else {
    fail("evidence missing")
  }
  evidence["sigma_multiplier"] = Json(3.0)
  for
    raw in [
      bad_estimate.stringify(),
      wrong_policy.stringify(),
      frames[2].replace(
        old="\"pending_count\":0",
        new="\"pending_count\":0.0000000000000000001",
      ),
      frames[2].replace(
        old="\"pending_count\":0",
        new="\"pending_count\":1e-999",
      ),
      "{\"kind\":\"evidence_transit_frame\",\"kind\":\"evidence_transit_frame\"}",
      "{\"extra\":true}",
    ] {
    try replay.process_line(raw) catch {
      _ => ()
    } noraise {
      _ => fail("malformed source accepted")
    }
    assert_eq(replay.checkpoint_json(), saved)
  }
  ignore(
    replay.process_line(
      frames[2].replace(
        old="\"pending_count\":0",
        new="\"pending_count\":0.0e3",
      ),
    ),
  )
}

///|
test "window checkpoint rejects bad partitions ends baselines and integer representations" {
  let replay = @codec.EvidenceTransitWindowReplay::open(window_test_source())
  for frame in window_test_frames() {
    ignore(replay.process_line(frame))
  }
  let saved = replay.checkpoint_json()
  for
    raw in [
      saved.replace(
        old="\"indeterminate\":\"1\"",
        new="\"indeterminate\":\"2\"",
      ),
      saved.replace(
        old="\"end_exclusive_us\":\"400000\"",
        new="\"end_exclusive_us\":\"400001\"",
      ),
      saved.replace(
        old="\"baseline_timestamp_us\":null",
        new="\"baseline_timestamp_us\":\"200001\"",
      ),
      saved.replace(old="\"input_frames\":\"1\"", new="\"input_frames\":\"01\""),
    ] {
    assert_true(raw != saved)
    try
      @codec.EvidenceTransitWindowReplay::open("{\"resume\":" + raw + "}")
    catch {
      _ => ()
    } noraise {
      _ => fail("inconsistent window checkpoint accepted")
    }
  }
  try
    @codec.EvidenceTransitWindowReplay::open(
      window_test_source().replace(
        old="\"window_us\":\"200000\"",
        new="\"window_us\":200000",
      ),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("numeric Int64 accepted")
  }
}

///|
test "window source preserves exact terminal bucket and compresses enormous unobserved gaps" {
  let upstream = @codec.EvidenceTransitAnalysisReplay::open(
    transit_analysis_test_source(),
  )
  let empty = (time : Int64) => {
    guard @json.parse(
        upstream.process_line(
          Json::object({
            "timestamp_us": Json(time.to_string()),
            "observations": Json::array([]),
          }).stringify(),
        ),
      )
      is { "transit": frame, .. } else {
      fail("empty transit frame missing")
    }
    frame.stringify()
  }
  let first = empty(0L)
  let last = empty(9223372036854775807L)
  let narrow = @codec.EvidenceTransitWindowReplay::open(
    window_test_source(width=1L),
  )
  ignore(narrow.process_line(first))
  assert_true(
    @json.parse(narrow.process_line(last))
    is {
      "unobserved_windows": String("9223372036854775806"),
      "closed_window": { "start_us": String("0"), .. },
      "current_window": {
        "start_us": String("9223372036854775807"),
        "end_exclusive_us": Null,
        ..
      },
      ..
    },
  )
  let broad = @codec.EvidenceTransitWindowReplay::open(
    window_test_source(width=9223372036854775807L),
  )
  ignore(broad.process_line(first))
  assert_true(
    @json.parse(broad.process_line(last))
    is {
      "closed_window": { "end_exclusive_us": String("9223372036854775807"), .. },
      "current_window": {
        "start_us": String("9223372036854775807"),
        "end_exclusive_us": Null,
        ..
      },
      ..
    },
  )
  assert_eq(
    @codec.EvidenceTransitWindowReplay::open(
      "{\"resume\":" + broad.checkpoint_json() + "}",
    ).checkpoint_json(),
    broad.checkpoint_json(),
  )
}

///|
test "pure window replay accepts CRLF EOF and empty input and returns no failed batch prefix" {
  let request = (transits : String) => {
    Json::object({
      "source": Json(window_test_source()),
      "transits": Json(transits),
    }).stringify()
  }
  assert_true(
    @json.parse(@codec.transit_windows_json(request("")))
    is { "frames": [], "checkpoint": { "current_window": Null, .. }, .. },
  )
  let frames = window_test_frames()
  let lf = frames.join("\n")
  assert_eq(
    @json.parse(@codec.transit_windows_json(request(lf))),
    @json.parse(
      @codec.transit_windows_json(request(frames.join("\r\n") + "\r\n")),
    ),
  )
  for bad in [lf + "\n\n", lf + "\n{}"] {
    try @codec.transit_windows_json(request(bad)) catch {
      _ => ()
    } noraise {
      _ => fail("bad window batch exposed prefix")
    }
  }
}
