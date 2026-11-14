///|
fn run_window_test_source(
  runs~ : String = run_protocol_source(
    options="{\"confirmation_us\":\"10\",\"min_samples\":\"2\"}",
  ),
  window~ : String = "{\"window_us\":\"10\"}",
) -> String {
  Json::object({ "runs": Json(runs), "window": Json(window) }).stringify()
}

///|
test "visual window output preserves the original complete footprint run frame" {
  let source = run_protocol_source(
    options="{\"confirmation_us\":\"10\",\"min_samples\":\"2\"}",
  )
  let replay = @codec.FootprintRunWindowReplay::open(
    run_window_test_source(runs=source),
  )
  let old = @codec.FootprintRunReplay::open(source)
  for time in [0L, 9L, 10L, 11L, 30L, 31L] {
    let line = run_protocol_line(time, assignments=time != 31L)
    guard @json.parse(replay.process_line(line))
      is { "kind": String("footprint_run_window_frame"), "runs": actual, .. } else {
      fail("missing run frame")
    }
    assert_eq(actual, @json.parse(old.process_line(line)))
    let saved = replay.checkpoint_json()
    guard @json.parse(saved) is { "runs": actual_state, .. } else {
      fail("missing run state")
    }
    assert_eq(actual_state, @json.parse(old.checkpoint_json()))
    ignore(@codec.FootprintRunWindowReplay::open("{\"resume\":" + saved + "}"))
  }
}

///|
test "confirmation belongs to its report bucket and active confirmed runs are not recounted" {
  let replay = @codec.FootprintRunWindowReplay::open(run_window_test_source())
  ignore(replay.process_line(run_protocol_line(0L)))
  ignore(replay.process_line(run_protocol_line(9L)))
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(10L)))
    is {
      "statistics": {
        "closed_window": {
          "start_us": String("0"),
          "input_frames": String("2"),
          "zones": [{ "confirmed_inside": String("0"), .. }],
          ..
        },
        "current_window": {
          "start_us": String("10"),
          "zones": [
            {
              "opening_active": String("1"),
              "opening_confirmed": String("0"),
              "started": String("0"),
              "confirmed_inside": String("1"),
              ..
            },
          ],
          ..
        },
        ..
      },
      ..
    },
  )
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(11L)))
    is {
      "statistics": {
        "current_window": {
          "zones": [{ "confirmed_inside": String("1"), .. }],
          ..
        },
        ..
      },
      ..
    },
  )
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(30L)))
    is {
      "statistics": {
        "unobserved_windows": String("1"),
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
  )
}

///|
test "started confirmed baseline does not backfill but its later ending is counted" {
  let source = run_protocol_source(
    options="{\"confirmation_us\":\"0\",\"min_samples\":\"1\"}",
  )
  let old = @codec.FootprintRunReplay::open(source)
  ignore(old.process_line(run_protocol_line(0L)))
  let baseline = "{\"resume\":" + old.checkpoint_json() + "}"
  let replay = @codec.FootprintRunWindowReplay::open(
    run_window_test_source(runs=baseline),
  )
  assert_true(
    @json.parse(replay.checkpoint_json())
    is { "baseline_timestamp_us": String("0"), "current_window": Null, .. },
  )
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(10L)))
    is {
      "statistics": {
        "closed_window": Null,
        "unobserved_windows": String("0"),
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
  )
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(11L, assignments=false)))
    is {
      "statistics": {
        "current_window": {
          "zones": [
            {
              "endings": [
                _,
                _,
                _,
                _,
                {
                  "reason": String("unavailable_evidence"),
                  "confirmed": String("1"),
                  "unconfirmed": String("0"),
                  ..
                },
                ..,
              ],
              ..
            },
          ],
          ..
        },
        ..
      },
      ..
    },
  )
}

///|
test "late unsupported footprint leaves original monitor and window retryable at the same time" {
  let replay = @codec.FootprintRunWindowReplay::open(run_window_test_source())
  ignore(replay.process_line(run_protocol_line(0L)))
  let before = replay.checkpoint_json()
  let good = run_protocol_line(10L)
  let bad = good.replace(old="radius_m\\\":0.125", new="radius_m\\\":1e-30")
  assert_true(bad != good)
  try replay.process_line(bad) catch {
    _ => ()
  } noraise {
    _ => fail("lost physical contribution accepted")
  }
  assert_eq(replay.checkpoint_json(), before)
  ignore(replay.process_line(good))
  ignore(
    @codec.FootprintRunWindowReplay::open(
      "{\"resume\":" + replay.checkpoint_json() + "}",
    ),
  )
}

///|
test "origin and original token failures leave a fresh window unstarted" {
  let replay = @codec.FootprintRunWindowReplay::open(
    run_window_test_source(window="{\"window_us\":\"10\",\"origin_us\":\"10\"}"),
  )
  let before = replay.checkpoint_json()
  for
    line in [
      run_protocol_line(0L),
      run_protocol_line(10L).replace(
        old="track_id\\\":7",
        new="track_id\\\":7.0000000000000001",
      ),
    ] {
    try replay.process_line(line) catch {
      _ => ()
    } noraise {
      _ => fail("invalid original accepted")
    }
    assert_eq(replay.checkpoint_json(), before)
  }
  ignore(replay.process_line(run_protocol_line(10L)))
}

///|
test "window checkpoint rejects correct-looking counts that violate its live run pool" {
  let replay = @codec.FootprintRunWindowReplay::open(run_window_test_source())
  ignore(replay.process_line(run_protocol_line(0L)))
  guard @json.parse(replay.checkpoint_json()) is Object(saved) &&
    saved.get("current_window") is Some(Object(window)) &&
    window.get("zones") is Some(Array(zones)) &&
    zones[0] is Object(zone) else {
    fail("missing counts")
  }
  zone["started"] = Json("0")
  try
    @codec.FootprintRunWindowReplay::open(
      Json::object({ "resume": Json::object(saved) }).stringify(),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("impossible live pool accepted")
  }
}

///|
test "exclusive Int64 max end is followed by a terminal mathematical window" {
  let runs = run_protocol_source(
    options="{\"confirmation_us\":\"0\",\"min_samples\":\"1\"}",
  )
  let replay = @codec.FootprintRunWindowReplay::open(
    run_window_test_source(
      runs~,
      window="{\"window_us\":\"9223372036854775807\"}",
    ),
  )
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(9223372036854775806L)))
    is {
      "statistics": {
        "current_window": {
          "end_exclusive_us": String("9223372036854775807"),
          ..
        },
        ..
      },
      ..
    },
  )
  assert_true(
    @json.parse(replay.process_line(run_protocol_line(9223372036854775807L)))
    is {
      "statistics": {
        "current_window": {
          "start_us": String("9223372036854775807"),
          "end_exclusive_us": Null,
          ..
        },
        ..
      },
      ..
    },
  )
  ignore(
    @codec.FootprintRunWindowReplay::open(
      "{\"resume\":" + replay.checkpoint_json() + "}",
    ),
  )
}

///|
test "strict window source options and batch boundaries preserve complete checkpoint semantics" {
  for
    options in [
      "{\"window_us\":\"0\"}", "{\"window_us\":\"010\"}", "{\"window_us\":10}", "{\"window_us\":\"10\",\"extra\":0}",
      "{\"window_us\":\"10\",\"window_us\":\"20\"}",
    ] {
    try
      @codec.FootprintRunWindowReplay::open(
        run_window_test_source(window=options),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid options accepted")
    }
  }
  let source = run_window_test_source()
  assert_true(
    @json.parse(
      @codec.footprint_run_windows_json(
        Json::object({ "source": Json(source), "frames": Json("") }).stringify(),
      ),
    )
    is {
      "frames": [],
      "checkpoint": {
        "current_window": Null,
        "format": String("moonground.footprint-run-windows"),
        ..
      },
      ..
    },
  )
  let excessive = Json::object({
    "source": Json(source),
    "frames": Json(Array::make(5001, "{}").join("\n")),
  }).stringify()
  try @codec.footprint_run_windows_json(excessive) catch {
    _ => ()
  } noraise {
    _ => fail("frame limit ignored")
  }
}
