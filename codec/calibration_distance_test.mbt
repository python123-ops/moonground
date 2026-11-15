///|
fn distance_request() -> Json {
  let request = sensitivity_request()
  guard request is Object(fields) else { abort("fixture must be an object") }
  ignore(fields.remove("probes"))
  fields["modes"] = Json([[0.125, 0.0, 0.0, 0.0, 0.125, 0.0, 0.0, 0.0, 0.0]])
  let probe : Json = {
    "probe_id": "shared",
    "first_segment": [[0, 0], [3, 4]],
    "second_segment": [[0, 0], [10, 0]],
  }
  fields["comparisons"] = Json([probe])
  request
}

///|
test "distance protocol preserves shared cross contributions and dimensionless ratio cancellation" {
  guard @json.parse(
      @codec.calibration_distance_json(distance_request().stringify()),
    )
    is {
      "schema_version": String("0.1.0"),
      "kind": String("calibration_distance_comparison"),
      "evidence_scope": String(
        "first_order_shared_homography_distance_contrasts"
      ),
      "mode_count": Number(1, ..),
      "comparisons": [
        {
          "probe_id": String("shared"),
          "first": {
            "distance_m": Number(5, ..),
            "mode_responses_m": [Number(0.625, ..)],
            ..
          },
          "second": { "distance_m": Number(10, ..), .. },
          "cross_contribution_m2": Number(0.78125, ..),
          "difference_m": Number(-5, ..),
          "difference_contribution_m2": Number(0.390625, ..),
          "ratio": Number(0.5, ..),
          "ratio_mode_responses": [Number(0, ..)],
          "ratio_contribution": Number(0, ..),
          "ratio_std": Number(0, ..),
          ..
        },
      ],
      ..
    } else {
    fail("shared distance schema missing")
  }
}

///|
test "distance protocol rejects raw duplicate unknown nonfinite and underflowing fields" {
  let raw = distance_request().stringify()
  for
    bad in [
      "{\"comparisons\":[],\"comparisons\":[]}",
      raw.replace(old="\"comparisons\"", new="\"camera\""),
      raw.replace(old="0.125", new="1e400"),
      raw.replace(old="0.125", new="1e-400"),
      raw.replace(old="0.125", new="\"0.125\""),
      raw.replace(old="\"first_segment\"", new="\"first_pixel\""),
    ] {
    try @codec.calibration_distance_json(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid distance request accepted")
    }
  }
}

///|
test "distance protocol accepts empty modes empty comparisons and exact closed ROI endpoints" {
  let request = distance_request()
  guard request is Object(fields) else { fail("object") }
  fields["modes"] = Json::array([])
  assert_true(
    @json.parse(@codec.calibration_distance_json(request.stringify()))
    is {
      "mode_count": Number(0, ..),
      "comparisons": [
        {
          "ratio_mode_responses": [],
          "first": { "std_m": Number(0, ..), .. },
          ..
        },
      ],
      ..
    },
  )
  fields["comparisons"] = Json::array([])
  assert_true(
    @json.parse(@codec.calibration_distance_json(request.stringify()))
    is { "comparisons": [], .. },
  )
}

///|
test "distance comparisons enforce two endpoints identifiers and bounded batch capacity" {
  let request = distance_request()
  guard request is Object(fields) else { fail("object") }
  let probe : Json = {
    "probe_id": "id",
    "first_segment": [[0, 0], [100, 100]],
    "second_segment": [[100, 0], [0, 100]],
  }
  let too_short : Json = {
    "probe_id": "short",
    "first_segment": [[0, 0]],
    "second_segment": [[100, 0], [0, 100]],
  }
  let too_long : Json = {
    "probe_id": "long",
    "first_segment": [[0, 0], [1, 0], [2, 0]],
    "second_segment": [[100, 0], [0, 100]],
  }
  for
    rows in [
      Json([probe, probe]),
      Json(Array::make(257, probe)),
      Json([too_short]),
      Json([too_long]),
    ] {
    fields["comparisons"] = rows
    try @codec.calibration_distance_json(request.stringify()) catch {
      _ => ()
    } noraise {
      _ => fail("invalid comparison list accepted")
    }
  }
}

///|
test "late coincident segment or out of ROI point fails the complete pure distance batch" {
  let request = distance_request()
  guard request is Object(fields) else { fail("object") }
  let valid : Json = {
    "probe_id": "valid",
    "first_segment": [[0, 0], [3, 4]],
    "second_segment": [[0, 0], [10, 0]],
  }
  let coincident : Json = {
    "probe_id": "bad",
    "first_segment": [[0, 0], [3, 4]],
    "second_segment": [[0, 0], [0, 0]],
  }
  let outside : Json = {
    "probe_id": "bad",
    "first_segment": [[0, 0], [3, 4]],
    "second_segment": [[0, 0], [101, 0]],
  }
  for bad in [coincident, outside] {
    fields["comparisons"] = Json([valid, bad])
    try @codec.calibration_distance_json(request.stringify()) catch {
      _ => ()
    } noraise {
      _ => fail("late invalid comparison accepted")
    }
  }
  assert_true(
    @json.parse(
      @codec.calibration_distance_json(distance_request().stringify()),
    )
    is { "comparisons": [_], .. },
  )
}
