///|
fn acceptance_source(requirements : String) -> String {
  "{\"session_id\":\"evaluation\",\"requirements\":" + requirements + "}"
}

///|
fn position_acceptance() -> String {
  acceptance_source(
    "{\"position_m\":{\"min_samples\":1,\"min_coverage\":1,\"max_error\":0}}",
  )
}

///|
test "acceptance source alone gives an explicit failed empty report" {
  let replay = @codec.MeasurementAcceptanceReplay::open(position_acceptance())
  assert_false(replay.accepted())
  assert_true(
    @json.parse(replay.report_json())
    is {
      "kind": String("measurement_acceptance"),
      "accepted": False,
      "checks": [
        { "actual": Number(0, ..), "passed": False, .. },
        { "actual": Null, "passed": False, .. },
        { "actual": Null, "passed": False, .. },
      ],
      "evaluation": { "kind": String("measurement_evaluation"), .. },
      ..
    },
  )
}

///|
test "wire requirements reject missing empty unknown and null selections" {
  for
    source in [
      "{\"session_id\":\"evaluation\"}",
      acceptance_source("{}"),
      acceptance_source("null"),
      acceptance_source("[]"),
      acceptance_source("{\"position\":{}}"),
      acceptance_source("{\"position_m\":null}"),
      acceptance_source(
        "{\"position_m\":{\"min_samples\":1,\"min_coverage\":1}}",
      ),
      position_acceptance().replace(
        old="\"session_id\":",
        new="\"unknown\":1,\"session_id\":",
      ),
      position_acceptance().replace(
        old="\"requirements\":",
        new="\"requirements\":{},\"requirements\":",
      ),
    ] {
    evaluation_invalid(() => {
      ignore(@codec.MeasurementAcceptanceReplay::open(source))
    })
  }
}

///|
test "wire bounds keep strict numeric tokens and enforce capacities" {
  for
    fields in [
      "\"min_samples\":0,\"min_coverage\":1,\"max_error\":0", "\"min_samples\":1.00000000000000000001,\"min_coverage\":1,\"max_error\":0",
      "\"min_samples\":1,\"min_coverage\":1.01,\"max_error\":0", "\"min_samples\":1,\"min_coverage\":false,\"max_error\":0",
      "\"min_samples\":1,\"min_coverage\":1,\"max_error\":-1", "\"min_samples\":1,\"min_coverage\":1,\"max_error\":1e-1000",
      "\"min_samples\":1,\"min_coverage\":1,\"max_error\":1e1000", "\"min_samples\":1,\"min_coverage\":1,\"max_error\":null",
      "\"min_samples\":1,\"min_coverage\":1,\"max_error\":0,\"extra\":0", "\"min_samples\":1,\"min_coverage\":1,\"max_error\":0,\"max_error\":1",
    ] {
    evaluation_invalid(() => {
      ignore(
        @codec.MeasurementAcceptanceReplay::open(
          acceptance_source("{\"position_m\":{" + fields + "}}"),
        ),
      )
    })
  }
  evaluation_invalid(() => {
    ignore(
      @codec.MeasurementAcceptanceReplay::open(
        position_acceptance().replace(
          old="\"requirements\":",
          new="\"max_tracks\":4097,\"requirements\":",
        ),
      ),
    )
  })
}

///|
test "acceptance preserves the original evaluator summary and both quantity units" {
  let source = acceptance_source(
    "{\"position_m\":{\"min_samples\":3,\"min_coverage\":1,\"max_error\":0},\"speed_mps\":{\"min_samples\":1,\"min_coverage\":0.3,\"max_mae\":0}}",
  )
  let replay = @codec.MeasurementAcceptanceReplay::open(source)
  let evaluator = @codec.MeasurementEvaluationReplay::open(
    "{\"session_id\":\"evaluation\"}",
  )
  let producer = @codec.ReplaySession::new(
    "{\"session_id\":\"evaluation\",\"mode\":\"ground\"}",
  )
  let lines : Array[String] = []
  for time in [0L, 200000L, 400000L] {
    let measured = producer.process_line(
      "{\"timestamp_us\":\"" +
      time.to_string() +
      "\",\"observations\":[{\"track_id\":1,\"point\":[0,0]}]}",
    )
    let line = evaluation_line(
      measured, time, "[{\"track_id\":1,\"position_m\":[0,0],\"speed_mps\":0}]",
    )
    replay.process_line(line)
    evaluator.process_line(line)
    lines.push(line)
  }
  assert_true(replay.accepted())
  let output = @json.parse(replay.report_json())
  let summary = match output {
    Object(fields) => fields.get("evaluation")
    _ => None
  }
  assert_eq(summary, Some(@json.parse(evaluator.report_json())))
  assert_true(
    output
    is {
      "requirements": { "position_m": _, "speed_mps": _, .. },
      "checks": [
        _,
        _,
        {
          "comparison": String("at_most"),
          "metric": String("position_error_m.maximum_absolute_error"),
          ..
        },
        _,
        _,
        _,
      ],
      ..
    },
  )
  let request = Json::object({
    "source": Json(source),
    "frames": Json(lines.join("\n") + "\n"),
  }).stringify()
  assert_eq(@codec.measurement_acceptance_json(request), replay.report_json())
}

///|
test "failed acceptance frame preserves checks and accepts a corrected retry" {
  let replay = @codec.MeasurementAcceptanceReplay::open(position_acceptance())
  let producer = @codec.ReplaySession::new(
    "{\"session_id\":\"evaluation\",\"mode\":\"ground\"}",
  )
  let measured = producer.process_line(
    "{\"timestamp_us\":\"0\",\"observations\":[{\"track_id\":1,\"point\":[0,0]}]}",
  )
  let before = replay.report_json()
  evaluation_invalid(() => {
    replay.process_line(
      evaluation_line(measured, 1L, "[{\"track_id\":1,\"position_m\":[0,0]}]"),
    )
  })
  assert_eq(replay.report_json(), before)
  replay.process_line(
    evaluation_line(measured, 0L, "[{\"track_id\":1,\"position_m\":[0,0]}]"),
  )
  assert_true(replay.accepted())
  let after = replay.report_json()
  evaluation_invalid(() => {
    replay.process_line(evaluation_line(measured, 0L, "[]"))
  })
  assert_eq(replay.report_json(), after)
}

///|
test "acceptance batch errors have no successful prefix and enforce limits" {
  for
    request in [
      Json::object({
        "source": Json(position_acceptance()),
        "frames": Json("{\n"),
      }).stringify(),
      Json::object({
        "source": Json(position_acceptance()),
        "frames": Json("\n"),
      }).stringify(),
      Json::object({
        "source": Json(position_acceptance()),
        "frames": Json(Array::make(5001, "{}").join("\n")),
      }).stringify(),
      Json::object({
        "source": Json(position_acceptance()),
        "frames": Json(" ".repeat(8388609)),
      }).stringify(),
    ] {
    evaluation_invalid(() => ignore(@codec.measurement_acceptance_json(request)))
  }
}
