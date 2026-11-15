///|
fn angle_request() -> Json {
  let request = distance_request()
  guard request is Object(fields) else { abort("fixture must be an object") }
  fields["modes"] = Json([[0.0, -0.125, 0.0, 0.125, 0.0, 0.0, 0.0, 0.0, 0.0]])
  fields["comparisons"] = Json::array([
    {
      "probe_id": "common-rotation",
      "first_segment": [[0, 0], [3, 4]],
      "second_segment": [[0, 0], [0, 8]],
    },
  ])
  request
}

///|
test "angle protocol states its directed convention and preserves shared rotation cancellation" {
  assert_true(
    @json.parse(@codec.calibration_angle_json(angle_request().stringify()))
    is {
      "schema_version": String("0.1.0"),
      "kind": String("calibration_angle_comparison"),
      "evidence_scope": String("first_order_shared_homography_angular_tangents"),
      "angle_convention": String("second_relative_to_first_ccw"),
      "mode_count": Number(1, ..),
      "comparisons": [
        {
          "probe_id": String("common-rotation"),
          "first": {
            "distance_m": Number(5, ..),
            "mode_responses_rad": [Number(0.125, ..)],
            "contribution_rad2": Number(0.015625, ..),
            ..
          },
          "second": { "std_rad": Number(0.125, ..), .. },
          "cross_contribution_rad2": Number(0.015625, ..),
          "mode_responses_rad": [Number(0, ..)],
          "contribution_rad2": Number(0, ..),
          "std_rad": Number(0, ..),
          ..
        },
      ],
      ..
    },
  )
}

///|
test "angle protocol rejects duplicate unknown nonfinite and underflowing raw tokens" {
  let raw = angle_request().stringify()
  for
    bad in [
      "{\"comparisons\":[],\"comparisons\":[]}",
      raw.replace(old="\"comparisons\"", new="\"camera\""),
      raw.replace(old="0.125", new="1e400"),
      raw.replace(old="0.125", new="1e-400"),
      raw.replace(old="0.125", new="\"0.125\""),
      raw.replace(old="\"first_segment\"", new="\"first_pixel\""),
    ] {
    try @codec.calibration_angle_json(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid angle request accepted")
    }
  }
}

///|
test "angle protocol accepts empty modes and comparisons and canonical antiparallel segments" {
  let request = angle_request()
  guard request is Object(fields) else { fail("object") }
  fields["modes"] = Json::array([])
  fields["comparisons"] = Json::array([
    {
      "probe_id": "opposite",
      "first_segment": [[0, 0], [100, 100]],
      "second_segment": [[100, 100], [0, 0]],
    },
  ])
  assert_true(
    @json.parse(@codec.calibration_angle_json(request.stringify()))
    is {
      "mode_count": Number(0, ..),
      "comparisons": [
        {
          "angle_rad": Number(3.141592653589793, ..),
          "mode_responses_rad": [],
          "std_rad": Number(0, ..),
          ..
        },
      ],
      ..
    },
  )
  fields["comparisons"] = Json::array([])
  assert_true(
    @json.parse(@codec.calibration_angle_json(request.stringify()))
    is { "comparisons": [], .. },
  )
}

///|
test "angle comparisons enforce segment cardinality unique identifiers and batch bounds" {
  let request = angle_request()
  guard request is Object(fields) else { fail("object") }
  let probe : Json = {
    "probe_id": "id",
    "first_segment": [[0, 0], [100, 100]],
    "second_segment": [[100, 0], [0, 100]],
  }
  for
    rows in [
      Json([probe, probe]),
      Json(Array::make(257, probe)),
      Json::array([
        {
          "probe_id": "short",
          "first_segment": [[0, 0]],
          "second_segment": [[100, 0], [0, 100]],
        },
      ]),
      Json::array([
        {
          "probe_id": "long",
          "first_segment": [[0, 0], [1, 0], [2, 0]],
          "second_segment": [[100, 0], [0, 100]],
        },
      ]),
      Json::array([
        {
          "probe_id": "",
          "first_segment": [[0, 0], [1, 0]],
          "second_segment": [[100, 0], [0, 100]],
        },
      ]),
    ] {
    fields["comparisons"] = rows
    try @codec.calibration_angle_json(request.stringify()) catch {
      _ => ()
    } noraise {
      _ => fail("invalid angle comparison list accepted")
    }
  }
}

///|
test "late coincident and outside angle segments fail the complete pure request" {
  let request = angle_request()
  guard request is Object(fields) else { fail("object") }
  let valid : Json = {
    "probe_id": "valid",
    "first_segment": [[0, 0], [3, 4]],
    "second_segment": [[0, 0], [0, 8]],
  }
  for endpoint in [[0, 0], [101, 0]] {
    fields["comparisons"] = Json::array([
      valid,
      {
        "probe_id": "bad",
        "first_segment": [[0, 0], [3, 4]],
        "second_segment": [[0, 0], endpoint],
      },
    ])
    try @codec.calibration_angle_json(request.stringify()) catch {
      _ => ()
    } noraise {
      _ => fail("late invalid angle comparison accepted")
    }
  }
}
