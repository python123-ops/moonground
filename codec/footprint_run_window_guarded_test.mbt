///|
fn guarded_run_window_test_source(
  guarded~ : String = guarded_run_test_source(),
  window~ : String = "{\"window_us\":\"200000\"}",
) -> String raise {
  Json::object({ "guarded": Json(guarded), "window": Json(window) }).stringify()
}

///|
test "health controlled raw windows preserve old guarded decisions and complete downstream results" {
  let original_source = guarded_run_test_source()
  let joined = @codec.FootprintRunWindowGuardedReplay::open(
    guarded_run_window_test_source(),
  )
  let old = @codec.FootprintRunGuardedReplay::open(original_source)
  guard @json.parse(original_source) is { "analysis": String(analysis), .. } &&
    @json.parse(analysis) is { "runs": String(runs), .. } else {
    fail("missing original run source")
  }
  let windows = @codec.FootprintRunWindowReplay::open(
    run_window_test_source(runs~, window="{\"window_us\":\"200000\"}"),
  )
  for
    (time, empty, segment, shift) in [
      (0L, true, "1", 0.0),
      (100000L, false, "1", 0.0),
      (200000L, false, "1", 0.0),
      (300000L, true, "1", 50.0),
      (400000L, true, "1", 0.0),
      (500000L, false, "2", 0.0),
      (600000L, false, "2", 0.0),
    ] {
    let input = guarded_run_test_frame(time, empty~, segment~, shift~)
    guard @json.parse(input) is { "assignments": String(assignments), .. } else {
      fail("missing assignments")
    }
    guard @json.parse(old.process_line(input))
      is {
        "decision": decision,
        "health": health,
        "suppressed_track_ids": suppressed,
        "analysis": { "measurement": measurement, "runs": old_runs, .. },
        ..
      } else {
      fail("missing old guarded frame")
    }
    let expected = @json.parse(
      windows.process_line(
        assigned_zone_test_line(measurement.stringify(), assignments),
      ),
    )
    guard @json.parse(joined.process_line(input))
      is {
        "kind": String("footprint_run_window_guarded_frame"),
        "decision": actual_decision,
        "health": actual_health,
        "suppressed_track_ids": actual_suppressed,
        "analysis": {
          "measurement": actual_measurement,
          "windows": actual_windows,
          ..
        },
        ..
      } else {
      fail("missing complete guarded windows")
    }
    assert_eq(actual_decision, decision)
    assert_eq(actual_health, health)
    assert_eq(actual_suppressed, suppressed)
    assert_eq(actual_measurement, measurement)
    assert_eq(actual_windows, expected)
    guard actual_windows is { "runs": actual_runs, .. } else {
      fail("missing runs")
    }
    assert_eq(actual_runs, old_runs)
    guard @json.parse(joined.checkpoint_json())
      is {
        "analysis": { "windows": saved_windows, .. },
        "health": saved_health,
        ..
      } &&
      @json.parse(old.checkpoint_json()) is { "health": old_health, .. } else {
      fail("missing saved layers")
    }
    assert_eq(saved_windows, @json.parse(windows.checkpoint_json()))
    assert_eq(saved_health, old_health)
    ignore(
      @codec.FootprintRunWindowGuardedReplay::open(
        "{\"resume\":" + joined.checkpoint_json() + "}",
      ),
    )
  }
}

///|
test "blocked assignments and first healthy identity failure preserve health measurement and windows" {
  let replay = @codec.FootprintRunWindowGuardedReplay::open(
    guarded_run_window_test_source(),
  )
  let before = replay.checkpoint_json()
  try replay.process_line(guarded_run_test_frame(0L)) catch {
    _ => ()
  } noraise {
    _ => fail("blocked nonempty accepted")
  }
  assert_eq(replay.checkpoint_json(), before)
  ignore(replay.process_line(guarded_run_test_frame(0L, empty=true)))
  let before = replay.checkpoint_json()
  try replay.process_line(guarded_run_test_frame(100000L, segment="9")) catch {
    _ => ()
  } noraise {
    _ => fail("wrong candidate accepted")
  }
  assert_eq(replay.checkpoint_json(), before)
  assert_true(
    @json.parse(replay.process_line(guarded_run_test_frame(100000L)))
    is {
      "decision": String("allowed"),
      "analysis": {
        "measurement": { "tracks": [{ "segment_id": String("1"), .. }], .. },
        "windows": {
          "statistics": {
            "current_window": { "input_frames": String("2"), .. },
            ..
          },
          ..
        },
        ..
      },
      ..
    },
  )
}

///|
test "single guarded window preview is original candidate and whole discovery follows new identities" {
  let source = guarded_run_window_test_source()
  let replay = @codec.FootprintRunWindowGuardedReplay::open(source)
  let before = replay.checkpoint_json()
  let old = @codec.FootprintRunGuardedReplay::open(guarded_run_test_source())
  assert_eq(
    replay.preview_line(guarded_test_frame(0L, 100.0)),
    old.preview_line(guarded_test_frame(0L, 100.0)),
  )
  assert_eq(replay.checkpoint_json(), before)
  let input = [
    guarded_test_frame(0L, 100.0),
    guarded_test_frame(100000L, 100.0),
    guarded_test_frame(200000L, 100.0),
    guarded_test_frame(300000L, 100.0, shift=50.0),
    guarded_test_frame(400000L, 100.0),
    guarded_test_frame(500000L, 100.0),
  ].join("\n")
  let actual = @codec.footprint_run_window_guarded_preview_json(
    Json::object({ "source": Json(source), "frames": Json(input) }).stringify(),
  )
  let expected = @codec.footprint_run_guarded_preview_json(
    Json::object({
      "source": Json(guarded_run_test_source()),
      "frames": Json(input),
    }).stringify(),
  )
  assert_eq(@json.parse(actual), @json.parse(expected))
  assert_true(!actual.contains("\"checkpoint\""))
  assert_true(!actual.contains("\"windows\""))
  assert_eq(replay.checkpoint_json(), before)
}

///|
test "projection barrier closes runs counts one input and preserves original window baseline" {
  let replay = @codec.FootprintRunWindowGuardedReplay::open(
    guarded_run_window_test_source(window="{\"window_us\":\"1000000\"}"),
  )
  for time in [0L, 100000L, 200000L, 300000L, 400000L, 500000L] {
    ignore(replay.process_line(guarded_run_test_frame(time, empty=time == 0L)))
  }
  let before = replay.checkpoint_json()
  try replay.process_line(projection_test_control(500000L)) catch {
    _ => ()
  } noraise {
    _ => fail("same-time barrier accepted")
  }
  assert_eq(replay.checkpoint_json(), before)
  assert_true(
    @json.parse(replay.process_line(projection_test_control(550000L)))
    is {
      "kind": String("footprint_run_window_guarded_projection_replaced"),
      "health": { "status": String("insufficient"), .. },
      "analysis": {
        "measurement": { "closed_segment_ids": [String("1")], .. },
        "windows": {
          "runs": { "active": [], "closed": [_, ..], .. },
          "statistics": {
            "current_window": { "input_frames": String("7"), .. },
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
  assert_true(
    @json.parse(saved)
    is {
      "analysis": {
        "measurement": { "motion": { "next_segment_id": String("2"), .. }, .. },
        "windows": {
          "baseline_timestamp_us": Null,
          "current_window": { "input_frames": String("7"), .. },
          ..
        },
        ..
      },
      ..
    },
  )
  let resumed = @codec.FootprintRunWindowGuardedReplay::open(
    "{\"resume\":" + saved + "}",
  )
  guard @json.parse(projection_test_frame(600000L, 50.0)) is Object(pair) else {
    fail("missing pair")
  }
  pair["assignments"] = Json(guarded_run_test_assignments(600000L, empty=true))
  assert_eq(
    resumed.process_line(Json::object(pair).stringify()),
    replay.process_line(Json::object(pair).stringify()),
  )
  assert_eq(resumed.checkpoint_json(), replay.checkpoint_json())
}

///|
test "started guarded source creates a baseline while complete resume preserves statistics" {
  let old = @codec.FootprintRunGuardedReplay::open(guarded_run_test_source())
  for time in [0L, 100000L, 200000L, 300000L, 400000L, 500000L] {
    ignore(old.process_line(guarded_run_test_frame(time, empty=time == 0L)))
  }
  let replay = @codec.FootprintRunWindowGuardedReplay::open(
    guarded_run_window_test_source(
      guarded="{\"resume\":" + old.checkpoint_json() + "}",
      window="{\"window_us\":\"1000000\"}",
    ),
  )
  assert_true(
    @json.parse(replay.checkpoint_json())
    is {
      "analysis": {
        "windows": {
          "baseline_timestamp_us": String("500000"),
          "current_window": Null,
          ..
        },
        ..
      },
      ..
    },
  )
  assert_true(
    @json.parse(replay.process_line(guarded_run_test_frame(600000L)))
    is {
      "analysis": {
        "windows": {
          "statistics": {
            "closed_window": Null,
            "current_window": {
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
      ..
    },
  )
  let saved = replay.checkpoint_json()
  let resumed = @codec.FootprintRunWindowGuardedReplay::open(
    "{\"resume\":" + saved + "}",
  )
  assert_eq(resumed.checkpoint_json(), saved)
  assert_eq(
    resumed.process_line(guarded_run_test_frame(700000L)),
    replay.process_line(guarded_run_test_frame(700000L)),
  )
}

///|
test "strict guarded window source and original raw tokens never partially commit" {
  for
    options in [
      "{\"window_us\":0}", "{\"window_us\":\"0\"}", "{\"window_us\":\"020\"}", "{\"window_us\":\"20\",\"extra\":1}",
      "{\"window_us\":\"20\",\"window_us\":\"40\"}",
    ] {
    try
      @codec.FootprintRunWindowGuardedReplay::open(
        guarded_run_window_test_source(window=options),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("bad options accepted")
    }
  }
  let replay = @codec.FootprintRunWindowGuardedReplay::open(
    guarded_run_window_test_source(),
  )
  let before = replay.checkpoint_json()
  let good = guarded_run_test_frame(0L, empty=true)
  for
    bad in [
      good.replace(old="track_id\\\":7", new="track_id\\\":7.0000000000000001"),
      good.replace(old="\"assignments\":", new="\"extra\":0,\"assignments\":"),
      good.replace(
        old="\"measurement\":",
        new="\"measurement\":\"{}\",\"measurement\":",
      ),
    ] {
    assert_true(bad != good)
    try replay.process_line(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid original accepted")
    }
    assert_eq(replay.checkpoint_json(), before)
  }
}

///|
test "pure guarded windows empty state and count limit cover discovery and formal output" {
  let source = guarded_run_window_test_source()
  let request = fn(frames) {
    Json::object({ "source": Json(source), "frames": Json(frames) }).stringify()
  }
  assert_true(
    @json.parse(@codec.footprint_run_window_guarded_json(request("")))
    is {
      "frames": [],
      "checkpoint": {
        "format": String("moonground.footprint-run-window-guarded"),
        "analysis": { "windows": { "current_window": Null, .. }, .. },
        ..
      },
      ..
    },
  )
  assert_true(
    @json.parse(@codec.footprint_run_window_guarded_preview_json(request("")))
    is { "frames": [], .. },
  )
  let excessive = request(Array::make(5001, "{}").join("\n"))
  for preview in [false, true] {
    try {
      if preview {
        @codec.footprint_run_window_guarded_preview_json(excessive)
      } else {
        @codec.footprint_run_window_guarded_json(excessive)
      }
    } catch {
      _ => ()
    } noraise {
      _ => fail("count limit ignored")
    }
  }
}
