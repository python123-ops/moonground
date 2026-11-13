///|
fn window_analysis_test_options(
  width~ : Int64 = 500000L,
  origin~ : Int64 = 0L,
) -> String {
  Json::object({
    "window_us": Json(width.to_string()),
    "origin_us": Json(origin.to_string()),
    "duration_limits_us": Json(["0", "100000", "200000", "9223372036854775807"]),
  }).stringify()
}

///|
fn window_analysis_test_source(
  width~ : Int64 = 500000L,
  origin~ : Int64 = 0L,
) -> String {
  Json::object({
    "analysis": Json(transit_analysis_test_source()),
    "windows": Json(window_analysis_test_options(width~, origin~)),
  }).stringify()
}

///|
fn window_analysis_test_parts(saved : Json) -> (Json, Json) raise {
  guard saved is { "analysis": analysis, "windows": windows, .. } else {
    fail("joint components missing")
  }
  ignore(
    @codec.EvidenceTransitAnalysisReplay::open(
      Json::object({ "resume": analysis }).stringify(),
    ),
  )
  ignore(
    @codec.EvidenceTransitWindowReplay::open(
      Json::object({ "resume": windows }).stringify(),
    ),
  )
  (analysis, windows)
}

///|
fn window_analysis_test_invalid_saved(saved : Json) -> Unit raise {
  ignore(window_analysis_test_parts(saved))
  try
    @codec.EvidenceTransitWindowAnalysisReplay::open(
      Json::object({ "resume": saved }).stringify(),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("incompatible individually valid components accepted")
  }
}

///|
test "joint raw window output and full states equal the original analysis and standalone window chain" {
  let upstream = @codec.EvidenceTransitAnalysisReplay::open(
    transit_analysis_test_source(),
  )
  let windows = @codec.EvidenceTransitWindowReplay::open(
    window_test_source(width=500000L),
  )
  let joint = @codec.EvidenceTransitWindowAnalysisReplay::open(
    window_analysis_test_source(),
  )
  for index, x in [-1.0, 1.0, 3.0, -1.0, 1.0, 3.0] {
    let raw = transit_analysis_test_frame(index.to_int64() * 100000L, x)
    let analyzed = @json.parse(upstream.process_line(raw))
    guard analyzed is { "transit": transit, .. } else {
      fail("transit missing")
    }
    assert_eq(
      @json.parse(joint.process_line(raw)),
      Json::object({
        "schema_version": Json("0.1.0"),
        "kind": Json("evidence_transit_window_analysis_frame"),
        "analysis": analyzed,
        "windows": @json.parse(windows.process_line(transit.stringify())),
      }),
    )
    assert_true(
      @json.parse(joint.checkpoint_json())
      is {
        "format": String("moonground.evidence-transit-window-analysis"),
        "checkpoint_version": String("1"),
        ..
      },
    )
  }
  let (analysis, counted) = window_analysis_test_parts(
    @json.parse(joint.checkpoint_json()),
  )
  assert_eq(analysis, @json.parse(upstream.checkpoint_json()))
  assert_eq(counted, @json.parse(windows.checkpoint_json()))
}

///|
test "joint windows restore full and split components at every original-clock cut" {
  let raw = [-1.0, 1.0, 3.0, -1.0, 1.0, 3.0].mapi((i, x) => {
    transit_analysis_test_frame(9007199254740993L + i.to_int64() * 100000L, x)
  })
  let full = @codec.EvidenceTransitWindowAnalysisReplay::open(
    window_analysis_test_source(width=130001L),
  )
  let expected = raw.map(frame => full.process_line(frame))
  for cut in 0..<=raw.length() {
    let prefix = @codec.EvidenceTransitWindowAnalysisReplay::open(
      window_analysis_test_source(width=130001L),
    )
    for i in 0..<cut {
      ignore(prefix.process_line(raw[i]))
    }
    let saved = @json.parse(prefix.checkpoint_json())
    let (analysis, windows) = window_analysis_test_parts(saved)
    for
      header in [
        Json::object({ "resume": saved }).stringify(),
        Json::object({
          "analysis": Json(Json::object({ "resume": analysis }).stringify()),
          "windows": Json(Json::object({ "resume": windows }).stringify()),
        }).stringify(),
      ] {
      let restored = @codec.EvidenceTransitWindowAnalysisReplay::open(header)
      for i in cut..<raw.length() {
        assert_eq(restored.process_line(raw[i]), expected[i])
      }
      assert_eq(restored.checkpoint_json(), full.checkpoint_json())
    }
  }
}

///|
test "window origin rejection discards a successful upstream first observation and segment allocation" {
  let joint = @codec.EvidenceTransitWindowAnalysisReplay::open(
    window_analysis_test_source(origin=100000L),
  )
  let before = joint.checkpoint_json()
  try joint.process_line(transit_analysis_test_frame(99999L, -1.0)) catch {
    _ => ()
  } noraise {
    _ => fail("pre-origin frame accepted")
  }
  assert_eq(joint.checkpoint_json(), before)
  assert_true(
    @json.parse(joint.process_line(transit_analysis_test_frame(100000L, -1.0)))
    is {
      "analysis": {
        "measurement": { "tracks": [{ "segment_id": String("1"), .. }], .. },
        ..
      },
      "windows": {
        "current_window": {
          "first_timestamp_us": String("100000"),
          "input_frames": String("1"),
          ..
        },
        ..
      },
      ..
    },
  )
}

///|
test "upstream crossing exhaustion preserves window input count pending motion and new identity on same-time correction" {
  let original = @codec.EvidenceTransitWindowAnalysisReplay::open(
    window_analysis_test_source(),
  )
  for i, x in [-1.0, 1.0] {
    ignore(
      original.process_line(
        transit_analysis_test_frame(i.to_int64() * 100000L, x),
      ),
    )
  }
  let saved = @json.parse(original.checkpoint_json())
  guard saved
    is {
      "analysis": {
        "transit": {
          "counting": { "state": { "counts": Array(counts), .. }, .. },
          ..
        },
        ..
      },
      ..
    } else {
    fail("gate totals missing")
  }
  for value in counts {
    guard value is Object(count) else { fail("gate count missing") }
    if count.get("gate_id") == Some(Json("exit")) {
      count["positive_to_negative"] = Json("9223372036854775807")
    }
  }
  let joint = @codec.EvidenceTransitWindowAnalysisReplay::open(
    Json::object({ "resume": saved }).stringify(),
  )
  let before = joint.checkpoint_json()
  let raw = @json.parse(transit_analysis_test_frame(200000L, 3.0))
  guard raw is { "observations": Array(objects), .. } else {
    fail("objects missing")
  }
  objects.push(
    Json::object({
      "track_id": Json(2),
      "point": Json([-1.0, 0.0]),
      "covariance": Json([0.01, 0.0, 1.0]),
    }),
  )
  try joint.process_line(raw.stringify()) catch {
    _ => ()
  } noraise {
    _ => fail("saturated exit accepted")
  }
  assert_eq(joint.checkpoint_json(), before)
  ignore(objects.remove(0))
  let retried = @json.parse(joint.process_line(raw.stringify()))
  assert_true(
    retried
    is {
      "analysis": {
        "measurement": {
          "tracks": [
            { "track_id": Number(2, ..), "segment_id": String("2"), .. },
          ],
          ..
        },
        ..
      },
      "windows": { "current_window": { "input_frames": String("3"), .. }, .. },
      ..
    },
  )
}

///|
test "joint restore rejects omitted known input times but permits older pending witnesses at a real baseline" {
  let joint = @codec.EvidenceTransitWindowAnalysisReplay::open(
    window_analysis_test_source(),
  )
  ignore(joint.process_line(transit_analysis_test_frame(0L, -1.0)))
  ignore(joint.process_line(transit_analysis_test_frame(100000L, 1.0)))
  let saved = @json.parse(joint.checkpoint_json())
  guard saved is { "windows": Object(windows), .. } &&
    windows.get("current_window") is Some(Object(current)) else {
    fail("window missing")
  }
  current["first_timestamp_us"] = Json("100000")
  current["input_frames"] = Json("1")
  window_analysis_test_invalid_saved(saved)
  windows["baseline_timestamp_us"] = Json("0")
  let restored = @codec.EvidenceTransitWindowAnalysisReplay::open(
    Json::object({ "resume": saved }).stringify(),
  )
  assert_true(
    @json.parse(
      restored.process_line(transit_analysis_test_frame(200000L, 3.0)),
    )
    is {
      "windows": {
        "current_window": {
          "input_frames": String("2"),
          "sections": [{ "completed": String("1"), .. }],
          ..
        },
        ..
      },
      ..
    },
  )
}

///|
test "joint restore checks accepted sample lower bounds beyond sparse endpoints" {
  let joint = @codec.EvidenceTransitWindowAnalysisReplay::open(
    window_analysis_test_source(),
  )
  for time in 0L..<5L {
    ignore(joint.process_line(transit_analysis_test_frame(time, -1.0)))
  }
  let saved = @json.parse(joint.checkpoint_json())
  guard saved is { "windows": { "current_window": Object(current), .. }, .. } else {
    fail("current window missing")
  }
  current["input_frames"] = Json("2")
  window_analysis_test_invalid_saved(saved)
}

///|
test "joint restore binds first-bucket completions and cancellation entry budgets" {
  let joint = @codec.EvidenceTransitWindowAnalysisReplay::open(
    window_analysis_test_source(),
  )
  ignore(joint.process_line(transit_analysis_test_frame(0L, -1.0)))
  ignore(joint.process_line(transit_analysis_test_frame(100000L, 1.0)))
  let pending = @json.parse(joint.checkpoint_json())
  guard pending
    is {
      "windows": {
        "current_window": {
          "sections": [{ "cancellations": [Object(reason), ..], .. }],
          ..
        },
        ..
      },
      ..
    } else {
    fail("cancellation slots missing")
  }
  reason["count"] = Json("1")
  window_analysis_test_invalid_saved(pending)
  ignore(joint.process_line(transit_analysis_test_frame(200000L, 3.0)))
  let completed = @json.parse(joint.checkpoint_json())
  guard completed
    is {
      "windows": { "current_window": { "sections": [Object(section)], .. }, .. },
      ..
    } &&
    section.get("duration_limits") is Some(Array(limits)) else {
    fail("duration counts missing")
  }
  section["completed"] = Json("0")
  for value in limits {
    guard value is Object(limit) else { fail("limit row missing") }
    for key in ["within", "exceeded", "indeterminate"] {
      limit[key] = Json("0")
    }
  }
  window_analysis_test_invalid_saved(completed)
}

///|
test "raw joint window fields and malformed object frames preserve complete state" {
  let joint = @codec.EvidenceTransitWindowAnalysisReplay::open(
    window_analysis_test_source(),
  )
  let before = joint.checkpoint_json()
  for
    raw in [
      transit_analysis_test_frame(0L, -1.0).replace(
        old="\"track_id\":1",
        new="\"track_id\":1.0000000000000000001",
      ),
      "{\"timestamp_us\":\"0\",\"observations\":[],\"observations\":[]}",
      "{\"timestamp_us\":\"0\",\"observations\":[],\"extra\":true}",
    ] {
    try joint.process_line(raw) catch {
      _ => ()
    } noraise {
      _ => fail("bad raw input accepted")
    }
    assert_eq(joint.checkpoint_json(), before)
  }
  for
    windows in [
      "{\"window_us\":200000,\"duration_limits_us\":[\"1\"]}", "{\"window_us\":\"1\",\"window_us\":\"2\",\"duration_limits_us\":[\"1\"]}",
      "{\"window_us\":\"1\",\"duration_limits_us\":[\"1\"],\"transit\":\"{}\"}",
    ] {
    try
      @codec.EvidenceTransitWindowAnalysisReplay::open(
        Json::object({
          "analysis": Json(transit_analysis_test_source()),
          "windows": Json(windows),
        }).stringify(),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("bad nested window options accepted")
    }
  }
}

///|
test "pure joint window replay accepts CRLF EOF and empty input without returning failed batch prefixes" {
  let request = (raw : String) => {
    Json::object({
      "source": Json(window_analysis_test_source()),
      "observations": Json(raw),
    }).stringify()
  }
  assert_true(
    @json.parse(@codec.evidence_transit_window_analysis_json(request("")))
    is {
      "frames": [],
      "checkpoint": { "windows": { "current_window": Null, .. }, .. },
      ..
    },
  )
  let lines = [-1.0, 1.0, 3.0].mapi((i, x) => {
    transit_analysis_test_frame(i.to_int64() * 100000L, x)
  })
  assert_eq(
    @json.parse(
      @codec.evidence_transit_window_analysis_json(request(lines.join("\n"))),
    ),
    @json.parse(
      @codec.evidence_transit_window_analysis_json(
        request(lines.join("\r\n") + "\r\n"),
      ),
    ),
  )
  for bad in [lines.join("\n") + "\n\n", lines.join("\n") + "\n{}"] {
    try @codec.evidence_transit_window_analysis_json(request(bad)) catch {
      _ => ()
    } noraise {
      _ => fail("failed batch exposed prefix")
    }
  }
}
