///|
fn run_analysis_test_measurement() -> String {
  (
    #|{"session_id":"evidence-test","mode":"ground","diagnostics":true,"motion":{"min_observations":2,"min_span_us":"0","q":0,"initial_velocity_std":1,"max_tracks":2}}
  )
}

///|
fn run_analysis_test_source() -> String {
  Json::object({
    "measurement": Json(run_analysis_test_measurement()),
    "runs": Json(run_protocol_source(options="{\"confirmation_us\":\"10\"}")),
  }).stringify()
}

///|
fn run_analysis_test_observation(time : Int64) -> String {
  Json::object({
    "timestamp_us": Json(time.to_string()),
    "observations": Json([
      Json::object({
        "track_id": Json(7),
        "point": Json([0.5, 0.5]),
        "covariance": Json([0.01, 0.0, 0.01]),
      }),
    ]),
  }).stringify()
}

///|
fn run_analysis_test_pair(
  time : Int64,
  shape~ : String = "{\"kind\":\"disk\",\"radius_m\":0.125}",
  segment~ : String = "1",
) -> String {
  let assignments = "{\"timestamp_us\":\"" +
    time.to_string() +
    "\",\"footprints\":[{\"track_id\":7,\"segment_id\":\"" +
    segment +
    "\",\"shape\":" +
    shape +
    "}]}"
  assigned_zone_test_line(run_analysis_test_observation(time), assignments)
}

///|
test "raw footprint analysis exactly matches the original motion and run chain" {
  let joined = @codec.FootprintRunAnalysisReplay::open(
    run_analysis_test_source(),
  )
  let motion = @codec.ReplaySession::open(run_analysis_test_measurement())
  let runs = @codec.FootprintRunReplay::open(
    run_protocol_source(options="{\"confirmation_us\":\"10\"}"),
  )
  for t in [0L, 10L, 20L] {
    let measured = motion.process_line(run_analysis_test_observation(t))
    guard @json.parse(run_analysis_test_pair(t))
      is { "assignments": String(assignments), .. } else {
      fail("missing assignments")
    }
    let expected = runs.process_line(
      assigned_zone_test_line(measured, assignments),
    )
    guard @json.parse(joined.process_line(run_analysis_test_pair(t)))
      is {
        "kind": String("footprint_run_analysis_frame"),
        "measurement": actual_measurement,
        "runs": actual_runs,
        ..
      } else {
      fail("missing joint result")
    }
    assert_eq(actual_measurement, @json.parse(measured))
    assert_eq(actual_runs, @json.parse(expected))
  }
  guard @json.parse(joined.checkpoint_json())
    is { "measurement": saved_measurement, "runs": saved_runs, .. } else {
    fail("missing joint state")
  }
  assert_eq(saved_measurement, @json.parse(motion.checkpoint_json()))
  assert_eq(saved_runs, @json.parse(runs.checkpoint_json()))
}

///|
test "footprint preview exposes actual new segment while preserving complete baseline" {
  let replay = @codec.FootprintRunAnalysisReplay::open(
    run_analysis_test_source(),
  )
  let before = replay.checkpoint_json()
  let preview = replay.preview_line(
    run_analysis_test_observation(9007199254740993L),
  )
  assert_true(
    @json.parse(preview)
    is {
      "measurement": {
        "timestamp_us": String("9007199254740993"),
        "tracks": [
          {
            "track_id": Number(7, ..),
            "segment_id": String("1"),
            "status": String("initializing"),
            ..
          },
        ],
        ..
      },
      ..
    },
  )
  assert_eq(
    preview,
    replay.preview_line(run_analysis_test_observation(9007199254740993L)),
  )
  assert_eq(replay.checkpoint_json(), before)
  ignore(replay.process_line(run_analysis_test_pair(9007199254740993L)))
  assert_true(
    @json.parse(replay.checkpoint_json())
    is {
      "measurement": { "motion": { "next_segment_id": String("2"), .. }, .. },
      ..
    },
  )
}

///|
test "wrong exact candidate identity preserves new segment allocation for same-time retry" {
  let replay = @codec.FootprintRunAnalysisReplay::open(
    run_analysis_test_source(),
  )
  let before = replay.checkpoint_json()
  try replay.process_line(run_analysis_test_pair(0L, segment="2")) catch {
    _ => ()
  } noraise {
    _ => fail("wrong segment accepted")
  }
  assert_eq(replay.checkpoint_json(), before)
  assert_true(
    @json.parse(replay.process_line(run_analysis_test_pair(0L)))
    is {
      "measurement": { "tracks": [{ "segment_id": String("1"), .. }], .. },
      ..
    },
  )
}

///|
test "late physical numeric failure retains motion covariance path and run clock" {
  let replay = @codec.FootprintRunAnalysisReplay::open(
    run_analysis_test_source(),
  )
  ignore(replay.process_line(run_analysis_test_pair(0L)))
  let before = replay.checkpoint_json()
  try
    replay.process_line(
      run_analysis_test_pair(
        10L,
        shape="{\"kind\":\"disk\",\"radius_m\":1e-30}",
      ),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("unsupported tiny physical expansion accepted")
  }
  assert_eq(replay.checkpoint_json(), before)
  assert_true(
    @json.parse(replay.process_line(run_analysis_test_pair(10L)))
    is { "runs": { "active": [{ "sample_count": String("1"), .. }], .. }, .. },
  )
}

///|
test "joint footprint checkpoint resumes motion and unfinished confirmation together" {
  let replay = @codec.FootprintRunAnalysisReplay::open(
    run_analysis_test_source(),
  )
  for t in [0L, 10L] {
    ignore(replay.process_line(run_analysis_test_pair(t)))
  }
  let restored = @codec.FootprintRunAnalysisReplay::open(
    "{\"resume\":" + replay.checkpoint_json() + "}",
  )
  assert_eq(
    restored.process_line(run_analysis_test_pair(20L)),
    replay.process_line(run_analysis_test_pair(20L)),
  )
  assert_eq(restored.checkpoint_json(), replay.checkpoint_json())
}

///|
test "individually legal run state cannot substitute a different current motion anchor" {
  let replay = @codec.FootprintRunAnalysisReplay::open(
    run_analysis_test_source(),
  )
  for t in [0L, 10L] {
    ignore(replay.process_line(run_analysis_test_pair(t)))
  }
  let checkpoint = @json.parse(replay.checkpoint_json())
  guard checkpoint is { "runs": { "states": [Object(state)], .. }, .. } else {
    fail("missing run anchor")
  }
  state["last_position_m"] = Json([0.6, 0.5])
  try
    @codec.FootprintRunAnalysisReplay::open(
      "{\"resume\":" + checkpoint.stringify() + "}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("mismatched current anchor accepted")
  }
}

///|
test "raw joint wrappers reject unknown fields duplicates and fractional identity tokens" {
  let replay = @codec.FootprintRunAnalysisReplay::open(
    run_analysis_test_source(),
  )
  let before = replay.checkpoint_json()
  for
    raw in [
      "{\"timestamp_us\":\"0\",\"observations\":[{\"track_id\":7.0000000000000001,\"point\":[0.5,0.5]}]}",
      "{\"timestamp_us\":\"0\",\"timestamp_us\":\"1\",\"observations\":[]}", "{\"timestamp_us\":\"0\",\"observations\":[],\"extra\":1}",
    ] {
    try
      replay.process_line(
        assigned_zone_test_line(
          raw,
          assigned_zone_test_document("[]", timestamp="0"),
        ),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("bad original observation accepted")
    }
    assert_eq(replay.checkpoint_json(), before)
  }
}

///|
test "pure joint replay returns complete committed state and pure preview commits nothing" {
  let source = run_analysis_test_source()
  let preview = @codec.footprint_run_preview_json(
    Json::object({
      "source": Json(source),
      "frame": Json(run_analysis_test_observation(0L)),
    }).stringify(),
  )
  assert_true(
    @json.parse(preview)
    is { "measurement": { "timestamp_us": String("0"), .. }, .. },
  )
  let request = fn(frames) {
    Json::object({ "source": Json(source), "frames": Json(frames) }).stringify()
  }
  assert_true(
    @json.parse(@codec.footprint_run_analysis_json(request("")))
    is {
      "frames": [],
      "checkpoint": {
        "measurement": { "motion": { "last_timestamp_us": Null, .. }, .. },
        "runs": { "last_timestamp_us": Null, .. },
        ..
      },
      ..
    },
  )
  let input = run_analysis_test_pair(0L) +
    "\r\n" +
    run_analysis_test_pair(10L) +
    "\n"
  assert_true(
    @json.parse(@codec.footprint_run_analysis_json(request(input)))
    is {
      "frames": [_, _],
      "checkpoint": {
        "measurement": {
          "motion": { "last_timestamp_us": String("10"), .. },
          ..
        },
        "runs": { "last_timestamp_us": String("10"), .. },
        ..
      },
      ..
    },
  )
  try
    @codec.footprint_run_analysis_json(
      request(input + run_analysis_test_pair(10L)),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("failed pure batch exposed a result")
  }
}
