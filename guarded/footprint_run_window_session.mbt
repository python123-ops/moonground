///|
fn detached_guarded_run_window(
  window : @zones.FootprintRunWindow,
) -> @zones.FootprintRunWindow {
  {
    ..window,
    zones: window.zones.map(row => { ..row, endings: row.endings.copy(), }),
  }
}

///|
fn detach_guarded_run_window_analysis(
  frame : @analysis.FootprintRunWindowSessionFrame,
) -> @analysis.FootprintRunWindowSessionFrame {
  let original = detach_guarded_run_analysis({
    measurement: frame.measurement,
    runs: frame.windows.runs,
  })
  {
    measurement: original.measurement,
    windows: {
      runs: original.runs,
      statistics: {
        ..frame.windows.statistics,
        current_window: detached_guarded_run_window(
          frame.windows.statistics.current_window,
        ),
        closed_window: frame.windows.statistics.closed_window.map(window => {
          detached_guarded_run_window(window)
        }),
      },
    },
  }
}

///|
/// Detach already bound health and measurement state. Statistics begin at its
/// current unobserved checkpoint boundary, without past outcome backfill.
pub fn FootprintRunWindowGuardedSession::new(
  existing : FootprintRunGuardedSession,
  window_us~ : Int64,
  origin_us~ : Int64 = 0L,
) -> FootprintRunWindowGuardedSession raise @types.GroundError {
  let original = FootprintRunGuardedSession::from_checkpoint(
    existing.checkpoint(),
  )
  {
    analysis: @analysis.FootprintRunWindowSession::new(
      original.analysis,
      window_us~,
      origin_us~,
    ),
    health: original.health,
    max_tracks: original.max_tracks,
    last_timestamp: original.last_timestamp,
  }
}

///|
pub fn FootprintRunWindowGuardedSession::checkpoint(
  self : FootprintRunWindowGuardedSession,
) -> FootprintRunWindowGuardedCheckpoint {
  {
    version: 1,
    analysis: self.analysis.checkpoint(),
    health: self.health.checkpoint(),
  }
}

///|
pub fn FootprintRunWindowGuardedSession::fork(
  self : FootprintRunWindowGuardedSession,
) -> FootprintRunWindowGuardedSession {
  {
    analysis: self.analysis.fork(),
    health: self.health.fork(),
    max_tracks: self.max_tracks,
    last_timestamp: self.last_timestamp,
  }
}

///|
pub fn FootprintRunWindowGuardedSession::reframed(
  self : FootprintRunWindowGuardedSession,
  transform : @types.PixelTransform,
) -> FootprintRunWindowGuardedSession raise @types.GroundError {
  {
    analysis: self.analysis.reframed(transform),
    health: self.health.reframed(transform),
    max_tracks: self.max_tracks,
    last_timestamp: self.last_timestamp,
  }
}

///|
/// Validate suppressed inputs structurally, then stage health and the single
/// measurement/run/window owner without exposing any committed mutable state.
pub fn FootprintRunWindowGuardedSession::prepare(
  self : FootprintRunWindowGuardedSession,
  timestamp_us : Int64,
  landmarks : Array[@health.LandmarkObservation],
  observations : Array[@moonground.PixelObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> FootprintRunWindowGuardedPreparation raise @types.GroundError {
  validate_guarded_objects(self.max_tracks, observations, lost, removed)
  let health = self.health.fork()
  let report = health.update(timestamp_us, landmarks)
  let analysis = self.analysis.fork()
  let candidate = if report.status == @health.Healthy {
    FootprintRunWindowGuardedCandidate::Allowed(
      analysis.prepare_pixel(timestamp_us, observations, lost~, removed~),
    )
  } else {
    FootprintRunWindowGuardedCandidate::Blocked(
      analysis.interrupt(timestamp_us),
    )
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
pub fn FootprintRunWindowGuardedPreparation::preview(
  self : FootprintRunWindowGuardedPreparation,
) -> FootprintRunGuardedPreview {
  {
    decision: match self.candidate {
      Allowed(_) => Allowed
      Blocked(_) => Blocked
    },
    health: { ..self.report, landmarks: self.report.landmarks.copy(), },
    measurement: match self.candidate {
      Allowed(candidate) => candidate.measurement()
      Blocked(frame) => detach_guarded_run_measurement(frame.measurement)
    },
    suppressed_track_ids: self.suppressed.copy(),
  }
}

///|
pub fn FootprintRunWindowGuardedPreparation::commit(
  self : FootprintRunWindowGuardedPreparation,
  assignments : @zones.FootprintAssignments,
) -> FootprintRunWindowGuardedFrame raise @types.GroundError {
  if self.used || self.owner.last_timestamp != self.baseline {
    raise @types.InvalidInput(
      "guarded footprint window preparation is used or stale",
    )
  }
  let (decision, analysis) = match self.candidate {
    Allowed(candidate) =>
      (GuardDecision::Allowed, candidate.commit(assignments))
    Blocked(frame) => {
      if assignments.timestamp_us != frame.measurement.motion.timestamp_us ||
        !assignments.is_empty() {
        raise @types.InvalidInput(
          "blocked footprint window preparation requires its exact timestamp and empty assignments",
        )
      }
      (GuardDecision::Blocked, frame)
    }
  }
  let result : FootprintRunWindowGuardedFrame = {
    decision,
    health: { ..self.report, landmarks: self.report.landmarks.copy(), },
    analysis: detach_guarded_run_window_analysis(analysis),
    suppressed_track_ids: self.suppressed.copy(),
  }
  // All throwing work is complete, including original geometry and reduction.
  self.owner.analysis = self.analysis
  self.owner.health = self.health
  self.owner.last_timestamp = Some(self.report.timestamp_us)
  self.used = true
  result
}

///|
pub fn FootprintRunWindowGuardedSession::update(
  self : FootprintRunWindowGuardedSession,
  timestamp_us : Int64,
  landmarks : Array[@health.LandmarkObservation],
  observations : Array[@moonground.PixelObservation],
  assignments : @zones.FootprintAssignments,
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> FootprintRunWindowGuardedFrame raise @types.GroundError {
  self
  .prepare(timestamp_us, landmarks, observations, lost~, removed~)
  .commit(assignments)
}
