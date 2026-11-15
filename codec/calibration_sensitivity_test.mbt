///|
fn sensitivity_request() -> Json {
  {
    "calibration": {
      "matrix": [1, 0, 0, 0, 1, 0, 0, 0, 1],
      "roi": [[0, 0], [100, 0], [100, 100], [0, 100]],
      "max_meters_per_pixel": 2,
    },
    "modes": [[0, 0, 0.25, 0, 0, 0.5, 0, 0, 0]],
    "probes": [
      { "probe_id": "shared", "first_pixel": [2, 4], "second_pixel": [3, 8] },
    ],
  }
}

///|
test "shared calibration contributions keep their own strict schema and ordered modes" {
  let raw = sensitivity_request().stringify()
  guard @json.parse(@codec.calibration_sensitivity_json(raw))
    is {
      "schema_version": String("0.1.0"),
      "kind": String("calibration_sensitivity"),
      "evidence_scope": String("first_order_shared_homography_parameters"),
      "mode_count": Number(1, ..),
      "normalized_matrix": [Number(1, ..), ..],
      "probes": [
        {
          "probe_id": String("shared"),
          "first": {
            "position_m": [Number(2, ..), Number(4, ..)],
            "contribution_m2": [
              Number(0.0625, ..),
              Number(0.125, ..),
              Number(0.25, ..),
            ],
            ..
          },
          "cross_contribution_m2": [
            Number(0.0625, ..),
            Number(0.125, ..),
            Number(0.125, ..),
            Number(0.25, ..),
          ],
          "displacement_contribution_m2": [
            Number(0, ..),
            Number(0, ..),
            Number(0, ..),
          ],
          ..
        },
      ],
      ..
    } else {
    fail("shared contribution schema missing")
  }
}

///|
test "calibration sensitivity rejects raw duplicate keys unknown fields and invalid numbers" {
  let raw = sensitivity_request().stringify()
  for
    bad in [
      "{\"modes\":[],\"modes\":[]}",
      raw.replace(old="\"probes\"", new="\"camera\""),
      raw.replace(old="0.25", new="1e400"),
      raw.replace(old="0.25", new="1e-400"),
      raw.replace(old="0.25", new="\"0.25\""),
      raw.replace(old="\"probe_id\"", new="\"track_id\""),
      raw.replace(old="\"first_pixel\"", new="\"point\""),
    ] {
    try @codec.calibration_sensitivity_json(bad) catch {
      @types.InvalidInput(_) => ()
    } noraise {
      _ => fail("invalid sensitivity source accepted")
    }
  }
  assert_eq(
    @codec.calibration_sensitivity_json(raw),
    @codec.calibration_sensitivity_json(raw),
  )
}

///|
test "calibration sensitivity allows no modes no probes and closed ROI pixels" {
  let request = sensitivity_request()
  guard request is Object(fields) else { fail("object") }
  fields["modes"] = Json::array([])
  guard @json.parse(@codec.calibration_sensitivity_json(request.stringify()))
    is {
      "mode_count": Number(0, ..),
      "probes": [
        {
          "first": {
            "mode_responses_m": [],
            "contribution_m2": [Number(0, ..), Number(0, ..), Number(0, ..)],
            ..
          },
          ..
        },
      ],
      ..
    } else {
    fail("empty modes rejected")
  }
  fields["probes"] = Json::array([])
  assert_true(
    @json.parse(@codec.calibration_sensitivity_json(request.stringify()))
    is { "probes": [], .. },
  )
}

///|
test "calibration sensitivity enforces pair identifiers dimensions and probe capacity" {
  let request = sensitivity_request()
  guard request is Object(fields) else { fail("object") }
  let probe : Json = {
    "probe_id": "duplicate",
    "first_pixel": [0, 0],
    "second_pixel": [100, 100],
  }
  let empty : Json = {
    "probe_id": "",
    "first_pixel": [0, 0],
    "second_pixel": [100, 100],
  }
  for
    probes in [
      Json([probe, probe]),
      Json(Array::make(257, probe)),
      Json([empty]),
    ] {
    fields["probes"] = probes
    try @codec.calibration_sensitivity_json(request.stringify()) catch {
      _ => ()
    } noraise {
      _ => fail("invalid probes accepted")
    }
  }
}

///|
test "calibration sensitivity late pair failure exposes no partial pure result" {
  let request = sensitivity_request()
  guard request is Object(fields) else { fail("object") }
  let probes : Array[Json] = [
    { "probe_id": "first", "first_pixel": [0, 0], "second_pixel": [100, 100] },
    { "probe_id": "bad", "first_pixel": [0, 0], "second_pixel": [101, 100] },
  ]
  fields["probes"] = Json(probes)
  try @codec.calibration_sensitivity_json(request.stringify()) catch {
    @types.InvalidInput(_) => ()
  } noraise {
    _ => fail("late invalid pixel was accepted")
  }
  assert_true(
    @json.parse(
      @codec.calibration_sensitivity_json(sensitivity_request().stringify()),
    )
    is { "probes": [_], .. },
  )
}
