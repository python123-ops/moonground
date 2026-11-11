///|
fn optional_point(value : @types.Point2?) -> Json {
  match value {
    Some(value) => point_json(value)
    None => Json::null()
  }
}

///|
fn optional_covariance(value : @types.Covariance2?) -> Json {
  match value {
    Some(value) => covariance_json(value)
    None => Json::null()
  }
}

///|
fn optional_number_json(value : Double?) -> Json {
  match value {
    Some(value) => Json(value)
    None => Json::null()
  }
}

///|
fn optional_array_json(value : Array[Double]?) -> Json {
  match value {
    Some(value) => Json(value)
    None => Json::null()
  }
}

///|
fn track_json(track : @motion.TrackEstimate, diagnostics : Bool) -> Json {
  let status = match track.status {
    @motion.Initializing => "initializing"
    @motion.Ready => "ready"
    @motion.RejectedInnovation => "rejected_innovation"
    @motion.NumericalFailure => "numerical_failure"
  }
  let fields : Map[String, Json] = {
    "track_id": Json(track.track_id),
    "segment_id": Json(track.segment_id),
    "status": Json(status),
    "position_m": optional_point(track.position),
    "position_covariance": optional_covariance(track.position_covariance),
    "velocity_mps": optional_point(track.velocity),
    "velocity_covariance": optional_covariance(track.velocity_covariance),
    "speed_mps": optional_number_json(track.speed_mps),
    "observed_path_length_m": Json(track.observed_path_length_m),
    "net_displacement_m": Json(track.net_displacement_m),
    "accepted_count": Json(track.accepted_count),
    "last_accepted_timestamp_us": Json(
      track.last_accepted_timestamp_us.to_string(),
    ),
  }
  if diagnostics {
    fields["filter_state"] = optional_array_json(track.filtered_state)
    fields["filter_covariance"] = optional_array_json(track.filtered_covariance)
  }
  Json::object(fields)
}

///|
fn output_json(
  frame : @motion.FrameResult,
  failures : Array[@moonground.ProjectionFailure],
  diagnostics : Bool,
) -> String {
  let tracks : Array[(Int32, Json)] = []
  for track in frame.tracks {
    tracks.push((track.track_id, track_json(track, diagnostics)))
  }
  for failure in failures {
    tracks.push(
      (
        failure.track_id,
        Json::object({
          "track_id": Json(failure.track_id),
          "segment_id": Json::null(),
          "status": Json("rejected_projection"),
          "reason": Json(failure.reason),
          "position_m": Json::null(),
          "position_covariance": Json::null(),
          "velocity_mps": Json::null(),
          "velocity_covariance": Json::null(),
          "speed_mps": Json::null(),
        }),
      ),
    )
  }
  tracks.sort_by((a, b) => a.0.compare(b.0))
  Json::object({
    "schema_version": Json("0.1.0"),
    "session_id": Json(frame.session_id),
    "timestamp_us": Json(frame.timestamp_us.to_string()),
    "tracks": Json(tracks.map(pair => pair.1)),
    "closed_segment_ids": Json(frame.closed_segment_ids),
    "uncertainty_scope": Json("conditional_on_fixed_calibration_and_anchor"),
  }).stringify()
}

///|
/// Commit one valid frame. A thrown error leaves the previous frame reusable.
pub fn ReplaySession::process_line(
  self : ReplaySession,
  source : String,
) -> String raise @types.GroundError {
  let fields = object(parse_document(source), "frame")
  allowed_fields(
    fields,
    ["timestamp_us", "observations", "lost", "removed"],
    "frame",
  )
  let timestamp_us = timestamp(required(fields, "timestamp_us"), "timestamp_us")
  let values = array(
    required(fields, "observations"),
    "observations",
    self.max_tracks,
  )
  let observations : Array[@types.GroundObservation] = []
  for value in values {
    let fields = object(value, "observation")
    allowed_fields(fields, ["track_id", "point", "covariance"], "observation")
    let track_id = positive_int(required(fields, "track_id"), "track_id")
    let position = point(required(fields, "point"), "point")
    let covariance = match fields.get("covariance") {
      Some(value) => covariance(value)
      None =>
        @types.Covariance2::isotropic(
          if self.pixel is Some(_) {
            2.0
          } else {
            0.05
          },
        )
    }
    observations.push(
      @types.GroundObservation::new(track_id, position, covariance),
    )
  }
  let lost = ids(fields, "lost", self.max_tracks)
  let removed = ids(fields, "removed", self.max_tracks)
  match (self.pixel, self.ground) {
    (Some(session), None) => {
      let pixels = observations.map(observation => @moonground.PixelObservation::{
        track_id: observation.track_id,
        position: observation.position,
        covariance: observation.covariance,
      })
      let frame = session.update(timestamp_us, pixels, lost~, removed~)
      output_json(frame.motion, frame.projection_failures, self.diagnostics)
    }
    (None, Some(estimator)) =>
      output_json(
        estimator.update(timestamp_us, observations, lost~, removed~),
        [],
        self.diagnostics,
      )
    _ => raise invalid("invalid replay session")
  }
}

///|
/// Project a bounded batch independently of motion initialization or filtering.
pub fn project_json(source : String) -> String raise @types.GroundError {
  let fields = object(parse_document(source), "projection request")
  allowed_fields(fields, ["calibration", "points"], "projection request")
  let calibration = calibration(required(fields, "calibration"))
  let output : Array[Json] = []
  for value in array(required(fields, "points"), "points", 1000) {
    let fields = object(value, "projection point")
    allowed_fields(fields, ["point", "covariance"], "projection point")
    let p = point(required(fields, "point"), "point")
    let cov = match fields.get("covariance") {
      Some(value) => covariance(value)
      None => @types.Covariance2::isotropic(2.0)
    }
    let projected = calibration.project(p, cov)
    output.push(
      Json::object({
        "position_m": point_json(projected.position()),
        "covariance": covariance_json(projected.covariance()),
        "jacobian": Json(calibration.jacobian(p)),
      }),
    )
  }
  Json::object({ "points": Json(output) }).stringify()
}
