///|
test "manual calibration wire returns reusable configuration and scalar report" {
  let input = "{\"control_pixels\":[[0,0],[50,0],[100,0],[0,100],[50,100],[100,100]],\"control_world\":[[0,0],[1,0],[2,0],[0,2],[1,2],[2,2]],\"check_pixels\":[[25,50],[75,50]],\"check_world\":[[0.5,1],[1.5,1]],\"roi\":[[0,0],[100,0],[100,100],[0,100]]}"
  let result = @json.parse(@codec.calibrate_json(input))
  assert_true(
    result
    is {
      "calibration": { "matrix": [_, _, _, _, _, _, _, _, _], .. },
      "report": {
        "fit_count": Number(6.0, ..),
        "check_count": Number(2.0, ..),
        "check_rms_m": Number(_, ..),
        ..
      },
      ..
    },
  )
}
