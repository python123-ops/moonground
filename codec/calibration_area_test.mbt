///|
fn area_request() -> Json {
  let request = distance_request()
  guard request is Object(fields) else { abort("fixture must be an object") }
  fields["modes"] = Json([[0.125, 0.0, 0.0, 0.0, 0.125, 0.0, 0.0, 0.0, 0.0]])
  fields["comparisons"] = Json::array([
    {
      "probe_id": "common-scale",
      "first_polygon": [[0, 0], [4, 0], [0, 4]],
      "second_polygon": [[0, 0], [8, 0], [0, 8]],
    },
  ])
  request
}

///|
test "area protocol preserves square metre contrasts and shared ratio cancellation" {
  assert_true(
    @json.parse(@codec.calibration_area_json(area_request().stringify()))
    is {
      "schema_version": String("0.1.0"),
      "kind": String("calibration_area_comparison"),
      "evidence_scope": String("first_order_shared_homography_area_contrasts"),
      "mode_count": Number(1, ..),
      "comparisons": [
        {
          "probe_id": String("common-scale"),
          "first": {
            "signed_area_m2": Number(8, ..),
            "area_m2": Number(8, ..),
            "mode_responses_m2": [Number(2, ..)],
            "contribution_m4": Number(4, ..),
            ..
          },
          "second": { "area_m2": Number(32, ..), .. },
          "cross_contribution_m4": Number(16, ..),
          "difference_m2": Number(-24, ..),
          "difference_mode_responses_m2": [Number(-6, ..)],
          "difference_contribution_m4": Number(36, ..),
          "difference_std_m2": Number(6, ..),
          "ratio": Number(0.25, ..),
          "ratio_mode_responses": [Number(0, ..)],
          "ratio_std": Number(0, ..),
          ..
        },
      ],
      ..
    },
  )
}

///|
test "area protocol rejects raw invalid numbers duplicate keys and unknown fields" {
  let raw = area_request().stringify()
  for
    bad in [
      "{\"comparisons\":[],\"comparisons\":[]}",
      raw.replace(old="\"comparisons\"", new="\"camera\""),
      raw.replace(old="0.125", new="1e400"),
      raw.replace(old="0.125", new="1e-400"),
      raw.replace(old="0.125", new="\"0.125\""),
      raw.replace(old="\"first_polygon\"", new="\"first_segment\""),
    ] {
    try @codec.calibration_area_json(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid area request accepted")
    }
  }
}

///|
test "area protocol accepts zero modes empty comparisons and opposite winding" {
  let request = area_request()
  guard request is Object(fields) else { fail("object") }
  fields["modes"] = Json::array([])
  fields["comparisons"] = Json::array([
    {
      "probe_id": "reverse",
      "first_polygon": [[0, 0], [4, 0], [0, 4]],
      "second_polygon": [[0, 4], [4, 0], [0, 0]],
    },
  ])
  assert_true(
    @json.parse(@codec.calibration_area_json(request.stringify()))
    is {
      "mode_count": Number(0, ..),
      "comparisons": [
        {
          "second": { "signed_area_m2": Number(-8, ..), .. },
          "difference_m2": Number(0, ..),
          "difference_mode_responses_m2": [],
          "ratio": Number(1, ..),
          "ratio_std": Number(0, ..),
          ..
        },
      ],
      ..
    },
  )
  fields["comparisons"] = Json::array([])
  assert_true(
    @json.parse(@codec.calibration_area_json(request.stringify()))
    is { "comparisons": [], .. },
  )
}

///|
test "area comparison cardinalities identifiers and strict convexity are bounded" {
  let request = area_request()
  guard request is Object(fields) else { fail("object") }
  let triangle : Json = [[0, 0], [4, 0], [0, 4]]
  let probe : Json = {
    "probe_id": "id",
    "first_polygon": triangle,
    "second_polygon": triangle,
  }
  for rows in [Json([probe, probe]), Json(Array::make(65, probe))] {
    fields["comparisons"] = rows
    try @codec.calibration_area_json(request.stringify()) catch {
      _ => ()
    } noraise {
      _ => fail("invalid area batch accepted")
    }
  }
  for
    polygon in [
      Json::array([]),
      Json::array([[0, 0], [1, 0]]),
      Json(Array::make(65, Json::array([0, 0]))),
      Json::array([[0, 0], [4, 0], [0, 4], [0, 0]]),
      Json::array([[0, 0], [4, 4], [0, 4], [4, 0]]),
      Json::array([[0, 0], [1, 0], [2, 0]]),
    ] {
    fields["comparisons"] = Json::array([
      {
        "probe_id": "shape",
        "first_polygon": polygon,
        "second_polygon": triangle,
      },
    ])
    try @codec.calibration_area_json(request.stringify()) catch {
      _ => ()
    } noraise {
      _ => fail("invalid polygon accepted")
    }
  }
}

///|
test "late invalid area polygon fails the complete pure request and leaves later calls usable" {
  let request = area_request()
  guard request is Object(fields) else { fail("object") }
  guard fields["comparisons"] is Array(valid) else { fail("array") }
  fields["comparisons"] = Json([
    valid[0],
    Json::object({
      "probe_id": Json("bad"),
      "first_polygon": Json::array([[0, 0], [4, 0], [0, 4]]),
      "second_polygon": Json::array([[0, 0], [101, 0], [0, 4]]),
    }),
  ])
  try @codec.calibration_area_json(request.stringify()) catch {
    _ => ()
  } noraise {
    _ => fail("late invalid polygon accepted")
  }
  ignore(@codec.calibration_area_json(area_request().stringify()))
}
