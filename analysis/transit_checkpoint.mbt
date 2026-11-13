///|
priv struct TransitWitness {
  point : @types.Point2
  covariance : @types.Covariance2?
}

///|
fn add_transit_witness(
  track : @motion.TrackCheckpoint,
  witnesses : Map[Int64, TransitWitness],
  timestamp_us : Int64,
  point : @types.Point2,
  covariance : @types.Covariance2?,
) -> Unit raise @types.GroundError {
  if timestamp_us < track.first_timestamp_us ||
    timestamp_us > track.last_timestamp_us {
    raise @types.InvalidInput(
      "evidence transit witness lies outside its motion segment",
    )
  }
  match witnesses.get(timestamp_us) {
    None => witnesses[timestamp_us] = { point, covariance, }
    Some(previous) => {
      if !same_point(previous.point, point) {
        raise @types.InvalidInput(
          "evidence transit witnesses at one time have different positions",
        )
      }
      match (previous.covariance, covariance) {
        (Some(a), Some(b)) =>
          if !same_evidence_covariance(a, b) {
            raise @types.InvalidInput(
              "evidence transit witnesses at one time have different covariances",
            )
          }
        (None, Some(_)) => witnesses[timestamp_us] = { point, covariance, }
        _ => ()
      }
    }
  }
}

///|
fn validate_transit_pending_pair(
  motion : @motion.MotionCheckpoint,
  transit : @transit.EvidenceTransitCheckpoint,
) -> Unit raise @types.GroundError {
  let tracks : Map[Int32, @motion.TrackCheckpoint] = Map([])
  let witnesses : Map[Int32, Map[Int64, TransitWitness]] = Map([])
  for track in motion.tracks {
    tracks[track.track_id] = track
    let samples : Map[Int64, TransitWitness] = Map([])
    add_transit_witness(
      track,
      samples,
      track.first_timestamp_us,
      track.first_filtered,
      None,
    )
    // Preserve the exact upper position block used in emitted measurements.
    add_transit_witness(
      track,
      samples,
      track.last_timestamp_us,
      track.last_filtered,
      Some({
        xx: track.covariance[0],
        xy: track.covariance[1],
        yy: track.covariance[5],
      }),
    )
    witnesses[track.track_id] = samples
  }
  for accepted in transit.counting.tracks {
    let track = tracks[accepted.track_id]
    for anchor in accepted.anchors {
      if anchor is Some(anchor) {
        add_transit_witness(
          track,
          witnesses[track.track_id],
          anchor.timestamp_us,
          anchor.point_m,
          Some(anchor.covariance),
        )
      }
    }
  }
  for pending in transit.pending {
    let entry = pending.entry
    guard tracks.get(entry.track_id) is Some(track) else {
      raise @types.InvalidInput(
        "pending evidence transit lacks its current motion track",
      )
    }
    if entry.segment_id != track.segment_id.to_string() {
      raise @types.InvalidInput(
        "pending evidence transit references a different motion segment",
      )
    }
    add_transit_witness(
      track,
      witnesses[track.track_id],
      entry.from_timestamp_us,
      entry.from_position_m,
      Some(pending.from_covariance),
    )
    add_transit_witness(
      track,
      witnesses[track.track_id],
      entry.to_timestamp_us,
      entry.to_position_m,
      Some(pending.to_covariance),
    )
  }
  for track in motion.tracks {
    // At most two motion endpoints, sixteen gate anchors and thirty-two
    // pending endpoints are known for a track. They are sparse observations,
    // not a reconstruction of the historical filter or travelled path.
    if witnesses[track.track_id].length() > track.accepted_count {
      raise @types.InvalidInput(
        "evidence transit witness times exceed accepted motion observations",
      )
    }
  }
}

///|
/// Restore each component independently, then check current evidence against
/// motion and pending entry endpoints against that same active segment.
/// Historical covariance witnesses remain self-consistent, not authenticated.
pub fn EvidenceTransitSession::from_checkpoint(
  checkpoint : EvidenceTransitSessionCheckpoint,
) -> EvidenceTransitSession raise @types.GroundError {
  if checkpoint.version != 1 {
    raise @types.InvalidInput(
      "unsupported evidence transit session checkpoint version",
    )
  }
  let transit = @transit.EvidenceTransitCounter::from_checkpoint(
    checkpoint.transit,
  )
  let (measurement, motion) = match checkpoint.measurement {
    Pixel(snapshot) => {
      let restored = @moonground.MeasurementSession::from_checkpoint(snapshot)
      (MeasurementEngine::Pixel(restored), restored.checkpoint().motion)
    }
    Ground(snapshot) => {
      let restored = @motion.MotionEstimator::from_checkpoint(snapshot)
      (MeasurementEngine::Ground(restored), restored.checkpoint())
    }
  }
  let paired = transit.checkpoint()
  validate_evidence_pair(motion, paired.counting)
  validate_transit_pending_pair(motion, paired)
  { measurement, transit, }
}
