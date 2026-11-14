///|
fn detach_guarded_run_measurement(
  frame : @moonground.MeasurementFrame,
) -> @moonground.MeasurementFrame {
  {
    motion: {
      ..frame.motion,
      tracks: frame.motion.tracks.map(track => {
        ..track,
        filtered_state: track.filtered_state.map(values => values.copy()),
        filtered_covariance: track.filtered_covariance.map(values => {
          values.copy()
        }),
      }),
      closed_segment_ids: frame.motion.closed_segment_ids.copy(),
    },
    projection_failures: frame.projection_failures.copy(),
  }
}

///|
fn detach_guarded_run_analysis(
  frame : @analysis.FootprintRunSessionFrame,
) -> @analysis.FootprintRunSessionFrame {
  {
    measurement: detach_guarded_run_measurement(frame.measurement),
    runs: {
      evidence: {
        ..frame.runs.evidence,
        evidence: frame.runs.evidence.evidence.map(row => {
          ..row,
          evidence: match row.evidence {
            @zones.Disk(band) =>
              @zones.Disk({ ..band, faces: band.faces.copy(), })
            @zones.Convex(band) =>
              @zones.Convex({
                ..band,
                faces: band.faces.copy(),
                vertices_offset_m: band.vertices_offset_m.copy(),
              })
          },
        }),
        unavailable: frame.runs.evidence.unavailable.copy(),
      },
      active: frame.runs.active.copy(),
      confirmed: frame.runs.confirmed.copy(),
      closed: frame.runs.closed.copy(),
    },
  }
}

///|
pub fn FootprintRunGuardedSession::new(
  analysis : @analysis.FootprintRunSession,
  health : @health.CalibrationMonitor,
) -> FootprintRunGuardedSession raise @types.GroundError {
  FootprintRunGuardedSession::from_checkpoint({
    version: 1,
    analysis: analysis.checkpoint(),
    health: health.checkpoint(),
  })
}

///|
pub fn FootprintRunGuardedSession::checkpoint(
  self : FootprintRunGuardedSession,
) -> FootprintRunGuardedCheckpoint {
  {
    version: 1,
    analysis: self.analysis.checkpoint(),
    health: self.health.checkpoint(),
  }
}

///|
pub fn FootprintRunGuardedSession::fork(
  self : FootprintRunGuardedSession,
) -> FootprintRunGuardedSession {
  {
    analysis: self.analysis.fork(),
    health: self.health.fork(),
    max_tracks: self.max_tracks,
    last_timestamp: self.last_timestamp,
  }
}

///|
/// Preserve warm metric state while changing both pixel conventions together.
pub fn FootprintRunGuardedSession::reframed(
  self : FootprintRunGuardedSession,
  transform : @types.PixelTransform,
) -> FootprintRunGuardedSession raise @types.GroundError {
  {
    analysis: self.analysis.reframed(transform),
    health: self.health.reframed(transform),
    max_tracks: self.max_tracks,
    last_timestamp: self.last_timestamp,
  }
}

///|
/// Health and object measurement are only staged. Suppressed raw objects still
/// receive the original structural validation, without projection or support.
pub fn FootprintRunGuardedSession::prepare(
  self : FootprintRunGuardedSession,
  timestamp_us : Int64,
  landmarks : Array[@health.LandmarkObservation],
  observations : Array[@moonground.PixelObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> FootprintRunGuardedPreparation raise @types.GroundError {
  validate_guarded_objects(self.max_tracks, observations, lost, removed)
  let health = self.health.fork()
  let report = health.update(timestamp_us, landmarks)
  let analysis = self.analysis.fork()
  let candidate = if report.status == @health.Healthy {
    FootprintRunGuardedCandidate::Allowed(
      analysis.prepare_pixel(timestamp_us, observations, lost~, removed~),
    )
  } else {
    FootprintRunGuardedCandidate::Blocked(analysis.interrupt(timestamp_us))
  }
  let suppressed = if report.status == @health.Healthy {
    []
  } else {
    let ids = observations.map(observation => observation.track_id)
    ids.sort()
    ids
  }
  {
    owner: self,
    baseline: self.last_timestamp,
    analysis,
    health,
    report,
    candidate,
    suppressed,
    used: false,
  }
}

///|
/// Every array, including diagnostic matrices, is detached from the candidate.
pub fn FootprintRunGuardedPreparation::preview(
  self : FootprintRunGuardedPreparation,
) -> FootprintRunGuardedPreview {
  {
    decision: match self.candidate {
      Allowed(_) => Allowed
      Blocked(_) => Blocked
    },
    health: { ..self.report, landmarks: self.report.landmarks.copy(), },
    measurement: match self.candidate {
      Allowed(prepared) => prepared.measurement()
      Blocked(frame) => detach_guarded_run_measurement(frame.measurement)
    },
    suppressed_track_ids: self.suppressed.copy(),
  }
}

///|
pub fn FootprintRunGuardedPreparation::commit(
  self : FootprintRunGuardedPreparation,
  assignments : @zones.FootprintAssignments,
) -> FootprintRunGuardedFrame raise @types.GroundError {
  if self.used || self.owner.last_timestamp != self.baseline {
    raise @types.InvalidInput(
      "guarded footprint run preparation is used or stale",
    )
  }
  let (decision, analysis) = match self.candidate {
    Allowed(prepared) => (GuardDecision::Allowed, prepared.commit(assignments))
    Blocked(frame) => {
      if assignments.timestamp_us != frame.measurement.motion.timestamp_us ||
        !assignments.is_empty() {
        raise @types.InvalidInput(
          "blocked footprint run preparation requires the exact timestamp and an empty assignment bundle",
        )
      }
      (GuardDecision::Blocked, frame)
    }
  }
  let result : FootprintRunGuardedFrame = {
    decision,
    health: { ..self.report, landmarks: self.report.landmarks.copy(), },
    analysis: detach_guarded_run_analysis(analysis),
    suppressed_track_ids: self.suppressed.copy(),
  }
  // All raising work is complete; no owned stage was exposed to the caller.
  self.owner.analysis = self.analysis
  self.owner.health = self.health
  self.owner.last_timestamp = Some(self.report.timestamp_us)
  self.used = true
  result
}

///|
pub fn FootprintRunGuardedSession::update(
  self : FootprintRunGuardedSession,
  timestamp_us : Int64,
  landmarks : Array[@health.LandmarkObservation],
  observations : Array[@moonground.PixelObservation],
  assignments : @zones.FootprintAssignments,
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> FootprintRunGuardedFrame raise @types.GroundError {
  self
  .prepare(timestamp_us, landmarks, observations, lost~, removed~)
  .commit(assignments)
}
