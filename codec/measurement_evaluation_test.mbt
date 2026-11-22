///|
fn evaluation_line(
  measurement : String,
  time : Int64,
  samples : String,
) -> String {
  "{\"measurement\":" +
  measurement +
  ",\"reference\":{\"timestamp_us\":\"" +
  time.to_string() +
  "\",\"samples\":" +
  samples +
  "}}"
}

///|
fn evaluation_invalid(
  action : () -> Unit raise @types.GroundError,
) -> Unit raise {
  try action() catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("invalid evaluation protocol was accepted")
  }
}

///|
test "evaluation consumes original measurements without inventing ready speed" {
  let producer = @codec.ReplaySession::new(
    "{\"session_id\":\"evaluation\",\"mode\":\"ground\"}",
  )
  let evaluator = @codec.MeasurementEvaluationReplay::open(
    "{\"session_id\":\"evaluation\"}",
  )
  for time in [0L, 200000L, 400000L] {
    let measured = producer.process_line(
      "{\"timestamp_us\":\"" +
      time.to_string() +
      "\",\"observations\":[{\"track_id\":1,\"point\":[0,0]}]}",
    )
    evaluator.process_line(
      evaluation_line(
        measured, time, "[{\"track_id\":1,\"position_m\":[0,0],\"speed_mps\":0}]",
      ),
    )
  }
  assert_true(
    @json.parse(evaluator.report_json())
    is {
      "counts": {
        "frames": String("3"),
        "references": Number(3, ..),
        "initializing": Number(2, ..),
        "ready": Number(1, ..),
        ..
      },
      "position_error_m": {
        "samples": Number(3, ..),
        "root_mean_square_error": Number(0, ..),
        ..
      },
      "speed_error_mps": { "samples": Number(1, ..), .. },
      "speed_coverage": Number(_, ..),
      ..
    },
  )
}

///|
test "evaluation protocol preserves raw numbers and rolls back failed frames" {
  let producer = @codec.ReplaySession::new(
    "{\"session_id\":\"evaluation\",\"mode\":\"ground\"}",
  )
  let measured = producer.process_line(
    "{\"timestamp_us\":\"9007199254740993\",\"observations\":[{\"track_id\":1,\"point\":[0,0]}]}",
  )
  let evaluator = @codec.MeasurementEvaluationReplay::open(
    "{\"session_id\":\"evaluation\"}",
  )
  let before = evaluator.report_json()
  for
    samples in [
      "[{\"track_id\":1,\"position_m\":[0,0]},{\"track_id\":1,\"position_m\":[0,0]}]",
      "[{\"track_id\":1,\"position_m\":[0,0],\"speed_mps\":1e-999}]", "[{\"track_id\":1,\"position_m\":[0,0],\"speed_mps\":0,\"speed_mps\":0}]",
      "[{\"track_id\":1,\"position_m\":[0,0],\"extra\":0}]",
    ] {
    evaluation_invalid(() => {
      evaluator.process_line(
        evaluation_line(measured, 9007199254740993L, samples),
      )
    })
    assert_eq(evaluator.report_json(), before)
  }
  evaluator.process_line(
    evaluation_line(
      measured, 9007199254740993L, "[{\"track_id\":1,\"position_m\":[0,0]}]",
    ),
  )
  assert_true(
    @json.parse(evaluator.report_json())
    is { "last_timestamp_us": String("9007199254740993"), .. },
  )
}

///|
test "projection rejection stays distinct from an absent measurement" {
  let evaluator = @codec.MeasurementEvaluationReplay::open(
    "{\"session_id\":\"evaluation\"}",
  )
  let measured = "{\"schema_version\":\"0.2.0\",\"session_id\":\"evaluation\",\"timestamp_us\":\"0\",\"tracks\":[{\"track_id\":1,\"segment_id\":null,\"status\":\"rejected_projection\",\"reason\":\"outside ROI\",\"position_m\":null,\"position_covariance\":null,\"velocity_mps\":null,\"velocity_covariance\":null,\"position_std_m\":null,\"velocity_std_mps\":null,\"speed_mps\":null}],\"closed_segment_ids\":[],\"uncertainty_scope\":\"conditional_on_fixed_calibration_camera_and_anchor\"}"
  evaluator.process_line(
    evaluation_line(measured, 0L, "[{\"track_id\":1,\"position_m\":[0,0]}]"),
  )
  assert_true(
    @json.parse(evaluator.report_json())
    is {
      "counts": {
        "rejected_projection": Number(1, ..),
        "missing": Number(0, ..),
        ..
      },
      "position_error_m": { "mean_absolute_error": Null, .. },
      "position_coverage": Number(0, ..),
      ..
    },
  )
}

///|
test "pure evaluation batches retain null empty metrics and strict configuration" {
  assert_true(
    @json.parse(
      @codec.measurement_evaluation_json(
        "{\"source\":\"{\\\"session_id\\\":\\\"evaluation\\\"}\",\"frames\":\"\"}",
      ),
    )
    is { "position_coverage": Null, "first_timestamp_us": Null, .. },
  )
  for
    source in [
      "{\"session_id\":\"evaluation\",\"max_tracks\":4097}", "{\"session_id\":\"evaluation\",\"max_samples\":1.00000000000000001}",
      "{\"session_id\":\"evaluation\",\"max_samples\":0}", "{\"session_id\":\"evaluation\",\"unknown\":0}",
    ] {
    evaluation_invalid(() => {
      ignore(@codec.MeasurementEvaluationReplay::open(source))
    })
  }
}
