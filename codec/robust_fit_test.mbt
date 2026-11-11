///|
fn robust_fit_request(options : String) -> String {
  "{\"control_pixels\":[[0,0],[100,0],[100,100],[0,100],[25,50],[70,30],[40,80],[60,10]],\"control_world\":[[0,0],[2,0],[2,2],[0,2],[0.5,1],[1.4,0.6],[1.8,0.6],[0.2,2.2]],\"check_pixels\":[[20,30],[80,70]],\"check_world\":[[0.4,0.6],[1.6,1.4]],\"roi\":[[0,0],[100,0],[100,100],[0,100]],\"max_fit_error_m\":0.000001,\"max_check_error_m\":0.000001,\"robust\":" +
  options +
  "}"
}

///|
fn expect_fit_error(source : String) -> Unit raise {
  try @codec.calibrate_json(source) catch {
    _ => ()
  } noraise {
    _ => fail("invalid calibration request accepted")
  }
}

///|
test "robust wire fits the final consensus and identifies excluded source indices" {
  let response = @json.parse(@codec.calibrate_json(robust_fit_request("{}")))
  assert_true(
    response
    is {
      "report": { "fit_count": Number(6, ..), "check_count": Number(2, ..), .. },
      "robust_report": {
        "control_count": Number(8, ..),
        "inlier_count": Number(6, ..),
        "inlier_mask": [True, True, True, True, True, True, False, False],
        "outlier_indices": [Number(6, ..), Number(7, ..)],
        "control_errors_m": [_, _, _, _, _, _, _, _],
        "trials_run": Number(28, ..),
        "options": {
          "inlier_threshold_m": Number(0.05, ..),
          "min_inlier_ratio": Number(0.6, ..),
          "max_trials": Number(512, ..),
          "seed": Number(1, ..),
          ..
        },
        ..
      },
      ..
    },
  )
  guard @json.parse(robust_fit_request("{}")) is Object(fields) else {
    fail("test fixture is not an object")
  }
  ignore(fields.remove("robust"))
  expect_fit_error(Json::object(fields).stringify())
}

///|
test "robust fitting options reject invalid domains unknown keys and rounded fractional integers" {
  for
    options in [
      "null", "true", "[]", "{\"method\":\"ransac\"}", "{\"inlier_threshold_m\":0}",
      "{\"inlier_threshold_m\":-1}", "{\"min_inlier_ratio\":0}", "{\"min_inlier_ratio\":1.01}",
      "{\"max_trials\":0}", "{\"max_trials\":4097}", "{\"max_trials\":4.0000000000000000001}",
      "{\"max_trials\":1,\"max_trials\":2}", "{\"seed\":0}", "{\"seed\":2147483648}",
      "{\"seed\":1.0000000000000000001}", "{\"min_inlier_ratio\":1}",
    ] {
    expect_fit_error(robust_fit_request(options))
  }
}

///|
test "excluded controls cannot be reused as independent check points" {
  guard @json.parse(robust_fit_request("{}")) is Object(fields) else {
    fail("test fixture is not an object")
  }
  fields["check_pixels"] = Json([[40.0, 80.0], [80.0, 70.0]])
  fields["check_world"] = Json([[0.8, 1.6], [1.6, 1.4]])
  expect_fit_error(Json::object(fields).stringify())
  fields["check_pixels"] = Json([[20.0, 30.0], [80.0, 70.0]])
  fields["check_world"] = Json([[1.0, 1.0], [1.6, 1.4]])
  expect_fit_error(Json::object(fields).stringify())
}

///|
test "robust response calibration can be reused and checkpointed without diagnostic fields" {
  guard @json.parse(@codec.calibrate_json(robust_fit_request("{}")))
    is Object(fields) else {
    fail("missing fitting response")
  }
  guard fields.get("calibration") is Some(calibration) else {
    fail("missing calibration")
  }
  let replay = @codec.ReplaySession::new(
    Json::object({
      "session_id": Json("robust-calibration"),
      "mode": Json("pixel"),
      "diagnostics": Json(true),
      "calibration": calibration,
    }).stringify(),
  )
  ignore(
    replay.process_line(
      "{\"timestamp_us\":\"0\",\"observations\":[{\"track_id\":1,\"point\":[20,30]}]}",
    ),
  )
  let restored = @codec.ReplaySession::from_checkpoint_json(
    replay.checkpoint_json(),
  )
  let next = "{\"timestamp_us\":\"200000\",\"observations\":[{\"track_id\":1,\"point\":[22,30]}]}"
  assert_eq(replay.process_line(next), restored.process_line(next))
}
