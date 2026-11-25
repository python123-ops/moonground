///|
fn checkpoint_evaluation_lines() -> Array[String] raise @types.GroundError {
  let producer = @codec.ReplaySession::new(
    "{\"session_id\":\"evaluation\",\"mode\":\"ground\"}",
  )
  [0L, 200000L, 400000L, 600000L, 800000L].map(time => {
    let measured = producer.process_line(
      "{\"timestamp_us\":\"" +
      time.to_string() +
      "\",\"observations\":[{\"track_id\":1,\"point\":[1,0]}]}",
    )
    evaluation_line(
      measured, time, "[{\"track_id\":1,\"position_m\":[0,0],\"speed_mps\":0}]",
    )
  })
}

///|
test "evaluation raw checkpoint resumes every cut with the original summary" {
  let source = "{\"session_id\":\"evaluation\"}"
  let lines = checkpoint_evaluation_lines()
  let baseline = @codec.MeasurementEvaluationReplay::open(source)
  for line in lines {
    baseline.process_line(line)
  }
  for cut in 0..<=5 {
    let first = @codec.MeasurementEvaluationReplay::open(source)
    for i in 0..<cut {
      first.process_line(lines[i])
    }
    let next = @codec.MeasurementEvaluationReplay::open(first.checkpoint_json())
    for i in cut..<5 {
      next.process_line(lines[i])
    }
    assert_eq(next.report_json(), baseline.report_json())
    assert_true(first.checkpoint_json().length() < 4096)
  }
}

///|
test "acceptance can apply new explicit requirements to continued evaluation state" {
  let lines = checkpoint_evaluation_lines()
  let first = @codec.MeasurementEvaluationReplay::open(
    "{\"session_id\":\"evaluation\"}",
  )
  first.process_line(lines[0])
  let header = @json.parse(first.checkpoint_json())
  let fields = match header {
    Object(fields) => fields
    _ => abort("expected object")
  }
  let saved_state = fields.get("resume").unwrap()
  let acceptance = @codec.MeasurementAcceptanceReplay::open(
    "{\"resume\":" +
    saved_state.stringify() +
    ",\"requirements\":{\"position_m\":{\"min_samples\":5,\"min_coverage\":1,\"max_error\":2}}}",
  )
  assert_false(acceptance.accepted())
  for i in 1..<5 {
    acceptance.process_line(lines[i])
  }
  assert_true(acceptance.accepted())
  let baseline = @codec.MeasurementEvaluationReplay::open(
    "{\"session_id\":\"evaluation\"}",
  )
  for line in lines {
    baseline.process_line(line)
  }
  assert_eq(
    @codec.MeasurementEvaluationReplay::open(acceptance.checkpoint_json()).report_json(),
    baseline.report_json(),
  )
}

///|
test "resume rejects extra configuration and preserves the input checkpoint after late errors" {
  let lines = checkpoint_evaluation_lines()
  let first = @codec.MeasurementEvaluationReplay::open(
    "{\"session_id\":\"evaluation\"}",
  )
  first.process_line(lines[0])
  let saved = first.checkpoint_json()
  let fields = match @json.parse(saved) {
    Object(fields) => fields
    _ => abort("expected object")
  }
  let saved_state = fields.get("resume").unwrap().stringify()
  for
    suffix in [
      ",\"session_id\":\"evaluation\"", ",\"max_tracks\":1", ",\"max_samples\":1",
      ",\"extra\":0",
    ] {
    evaluation_invalid(() => {
      ignore(
        @codec.MeasurementEvaluationReplay::open(
          "{\"resume\":" + saved_state + suffix + "}",
        ),
      )
    })
  }
  let next = @codec.MeasurementEvaluationReplay::open(saved)
  let before = next.report_with_checkpoint_json()
  evaluation_invalid(() => next.process_line(lines[0]))
  assert_eq(next.report_with_checkpoint_json(), before)
  next.process_line(lines[1])
  assert_eq(first.checkpoint_json(), saved)
}

///|
test "pure checkpoint batches keep bounded input and return a resumable report" {
  let source = "{\"session_id\":\"evaluation\"}"
  let document = Json::object({ "source": Json(source), "frames": Json("") }).stringify()
  assert_true(
    @json.parse(@codec.measurement_evaluation_checkpoint_json(document))
    is {
      "report": { "kind": String("measurement_evaluation"), .. },
      "resume": {
        "version": Number(1, ..),
        "counts": { "frames": String("0"), .. },
        ..
      },
      ..
    },
  )
}
