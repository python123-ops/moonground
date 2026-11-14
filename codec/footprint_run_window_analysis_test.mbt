///|
fn run_window_analysis_test_source(
  analysis~ : String = run_analysis_test_source(),
  window~ : String = "{\"window_us\":\"20\"}",
) -> String {
  Json::object({ "analysis": Json(analysis), "window": Json(window) }).stringify()
}

///|
test "raw window analysis preserves old complete motion and downstream window frames and checkpoints" {
  let joined = @codec.FootprintRunWindowAnalysisReplay::open(
    run_window_analysis_test_source(),
  )
  let old = @codec.FootprintRunAnalysisReplay::open(run_analysis_test_source())
  let windows = @codec.FootprintRunWindowReplay::open(
    run_window_test_source(
      runs=run_protocol_source(options="{\"confirmation_us\":\"10\"}"),
      window="{\"window_us\":\"20\"}",
    ),
  )
  for time in [0L, 10L, 20L, 30L, 60L] {
    let line = run_analysis_test_pair(time)
    guard @json.parse(line) is { "assignments": String(assignments), .. } else {
      fail("missing assignments")
    }
    guard @json.parse(old.process_line(line))
      is { "measurement": expected, "runs": old_runs, .. } else {
      fail("missing old frame")
    }
    let expected_windows = @json.parse(
      windows.process_line(
        assigned_zone_test_line(expected.stringify(), assignments),
      ),
    )
    guard @json.parse(joined.process_line(line))
      is {
        "kind": String("footprint_run_window_analysis_frame"),
        "measurement": actual,
        "windows": actual_windows,
        ..
      } else {
      fail("missing joint window frame")
    }
    assert_eq(actual, expected)
    assert_eq(actual_windows, expected_windows)
    guard actual_windows is { "runs": nested_runs, .. } else {
      fail("missing original runs")
    }
    assert_eq(nested_runs, old_runs)
    guard @json.parse(joined.checkpoint_json())
      is { "measurement": saved_measurement, "windows": saved_windows, .. } else {
      fail("missing complete state")
    }
    guard @json.parse(old.checkpoint_json())
      is { "measurement": old_measurement, .. } else {
      fail("missing old measurement")
    }
    assert_eq(saved_measurement, old_measurement)
    assert_eq(saved_windows, @json.parse(windows.checkpoint_json()))
    ignore(
      @codec.FootprintRunWindowAnalysisReplay::open(
        "{\"resume\":" + joined.checkpoint_json() + "}",
      ),
    )
  }
}

///|
test "started original source establishes baseline and complete resume retains current window" {
  let old = @codec.FootprintRunAnalysisReplay::open(run_analysis_test_source())
  for time in [0L, 10L, 20L] {
    ignore(old.process_line(run_analysis_test_pair(time)))
  }
  let replay = @codec.FootprintRunWindowAnalysisReplay::open(
    run_window_analysis_test_source(
      analysis="{\"resume\":" + old.checkpoint_json() + "}",
    ),
  )
  assert_true(
    @json.parse(replay.checkpoint_json())
    is {
      "windows": {
        "baseline_timestamp_us": String("20"),
        "current_window": Null,
        ..
      },
      ..
    },
  )
  let actual = @json.parse(replay.process_line(run_analysis_test_pair(30L)))
  assert_true(
    actual
    is {
      "windows": {
        "statistics": {
          "closed_window": Null,
          "current_window": {
            "input_frames": String("1"),
            "zones": [
              {
                "opening_confirmed": String("1"),
                "confirmed_inside": String("0"),
                ..
              },
            ],
            ..
          },
          ..
        },
        ..
      },
      ..
    },
  )
  let saved = replay.checkpoint_json()
  let resumed = @codec.FootprintRunWindowAnalysisReplay::open(
    "{\"resume\":" + saved + "}",
  )
  assert_eq(resumed.checkpoint_json(), saved)
  assert_eq(
    resumed.process_line(run_analysis_test_pair(40L)),
    replay.process_line(run_analysis_test_pair(40L)),
  )
}

///|
test "window preview exposes genuine candidate without advancing any committed state" {
  let replay = @codec.FootprintRunWindowAnalysisReplay::open(
    run_window_analysis_test_source(),
  )
  let before = replay.checkpoint_json()
  let raw = run_analysis_test_observation(9007199254740993L)
  let actual = replay.preview_line(raw)
  let old = @codec.FootprintRunAnalysisReplay::open(run_analysis_test_source())
  assert_eq(actual, old.preview_line(raw))
  assert_eq(replay.preview_line(raw), actual)
  assert_eq(replay.checkpoint_json(), before)
  assert_eq(
    @codec.footprint_run_window_preview_json(
      Json::object({
        "source": Json(run_window_analysis_test_source()),
        "frame": Json(raw),
      }).stringify(),
    ),
    actual,
  )
}

///|
test "late window origin and footprint errors retain measurement next segment and downstream state" {
  let replay = @codec.FootprintRunWindowAnalysisReplay::open(
    run_window_analysis_test_source(
      window="{\"window_us\":\"20\",\"origin_us\":\"10\"}",
    ),
  )
  let before = replay.checkpoint_json()
  try replay.process_line(run_analysis_test_pair(0L)) catch {
    _ => ()
  } noraise {
    _ => fail("before-origin raw accepted")
  }
  assert_eq(replay.checkpoint_json(), before)
  ignore(replay.process_line(run_analysis_test_pair(10L)))
  let before = replay.checkpoint_json()
  try
    replay.process_line(
      run_analysis_test_pair(
        20L,
        shape="{\"kind\":\"disk\",\"radius_m\":1e-30}",
      ),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("late lost support accepted")
  }
  assert_eq(replay.checkpoint_json(), before)
  ignore(replay.process_line(run_analysis_test_pair(20L)))
  ignore(
    @codec.FootprintRunWindowAnalysisReplay::open(
      "{\"resume\":" + replay.checkpoint_json() + "}",
    ),
  )
}

///|
test "joint window restore rejects a separately legal run point that differs from motion" {
  let replay = @codec.FootprintRunWindowAnalysisReplay::open(
    run_window_analysis_test_source(),
  )
  for time in [0L, 10L, 20L] {
    ignore(replay.process_line(run_analysis_test_pair(time)))
  }
  guard @json.parse(replay.checkpoint_json()) is Object(saved) &&
    saved.get("windows") is Some(Object(windows)) &&
    windows.get("runs") is Some(Object(runs)) &&
    runs.get("states") is Some(Array(states)) &&
    states[0] is Object(state) else {
    fail("missing run checkpoint")
  }
  state["last_position_m"] = Json([0.6, 0.5])
  ignore(
    @codec.FootprintRunWindowReplay::open(
      Json::object({ "resume": Json::object(windows) }).stringify(),
    ),
  )
  try
    @codec.FootprintRunWindowAnalysisReplay::open(
      Json::object({ "resume": Json::object(saved) }).stringify(),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("different accepted point restored")
  }
}

///|
test "strict original raw tokens and fresh window options leave joint owner unchanged" {
  for
    window in [
      "{\"window_us\":0}", "{\"window_us\":\"0\"}", "{\"window_us\":\"020\"}", "{\"window_us\":\"20\",\"extra\":0}",
      "{\"window_us\":\"20\",\"window_us\":\"40\"}",
    ] {
    try
      @codec.FootprintRunWindowAnalysisReplay::open(
        run_window_analysis_test_source(window~),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid window options accepted")
    }
  }
  let replay = @codec.FootprintRunWindowAnalysisReplay::open(
    run_window_analysis_test_source(),
  )
  let before = replay.checkpoint_json()
  let bad = "{\"timestamp_us\":\"0\",\"observations\":[{\"track_id\":7.0000000000000001,\"point\":[0.5,0.5]}]}"
  try
    replay.process_line(
      assigned_zone_test_line(
        bad,
        assigned_zone_test_document("[]", timestamp="0"),
      ),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("fractional original id accepted")
  }
  assert_eq(replay.checkpoint_json(), before)
  let measured = @codec.ReplaySession::open(run_analysis_test_measurement()).process_line(
    run_analysis_test_observation(0L),
  )
  try
    replay.process_line(
      assigned_zone_test_line(
        measured,
        assigned_zone_test_document("[]", timestamp="0"),
      ),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("precomputed measurement accepted as original")
  }
  assert_eq(replay.checkpoint_json(), before)
}

///|
test "pure raw window batch respects empty complete state CRLF and count limit" {
  let source = run_window_analysis_test_source()
  let request = fn(frames) {
    Json::object({ "source": Json(source), "frames": Json(frames) }).stringify()
  }
  assert_true(
    @json.parse(@codec.footprint_run_window_analysis_json(request("")))
    is {
      "frames": [],
      "checkpoint": {
        "format": String("moonground.footprint-run-window-analysis"),
        "windows": { "current_window": Null, .. },
        ..
      },
      ..
    },
  )
  assert_true(
    @json.parse(
      @codec.footprint_run_window_analysis_json(
        request(
          run_analysis_test_pair(0L) +
          "\r\n" +
          run_analysis_test_pair(10L) +
          "\n",
        ),
      ),
    )
    is {
      "frames": [_, _],
      "checkpoint": {
        "windows": { "current_window": { "input_frames": String("2"), .. }, .. },
        ..
      },
      ..
    },
  )
  try
    @codec.footprint_run_window_analysis_json(
      request(Array::make(5001, "{}").join("\n")),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("frame limit ignored")
  }
}
