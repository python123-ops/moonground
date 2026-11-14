///|
/// Detach an existing measurement/run session and start unobserved statistics
/// at its current watermark. Existing confirmations are not counted again.
pub fn FootprintRunWindowSession::new(
  existing : FootprintRunSession,
  window_us~ : Int64,
  origin_us~ : Int64 = 0L,
) -> FootprintRunWindowSession raise @types.GroundError {
  let original = FootprintRunSession::from_checkpoint(existing.checkpoint())
  let windows = @zones.FootprintRunWindowMonitor::new(
    original.runs,
    window_us~,
    origin_us~,
  )
  {
    measurement: original.measurement,
    windows,
    last_timestamp: original.last_timestamp,
  }
}

///|
pub fn FootprintRunWindowSession::checkpoint(
  self : FootprintRunWindowSession,
) -> FootprintRunWindowSessionCheckpoint {
  {
    version: 1,
    measurement: match self.measurement {
      Pixel(session) => Pixel(session.checkpoint())
      Ground(estimator) => Ground(estimator.checkpoint())
    },
    windows: self.windows.checkpoint(),
  }
}

///|
pub fn FootprintRunWindowSession::fork(
  self : FootprintRunWindowSession,
) -> FootprintRunWindowSession {
  {
    measurement: match self.measurement {
      Pixel(session) => Pixel(session.fork())
      Ground(estimator) => Ground(estimator.fork())
    },
    windows: self.windows.fork(),
    last_timestamp: self.last_timestamp,
  }
}

///|
pub fn FootprintRunWindowSession::prepare_pixel(
  self : FootprintRunWindowSession,
  timestamp_us : Int64,
  observations : Array[@moonground.PixelObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> FootprintRunWindowPreparation raise @types.GroundError {
  guard self.measurement is Pixel(original) else {
    raise @types.InvalidInput(
      "pixel observations require a pixel footprint run window session",
    )
  }
  let candidate = original.fork()
  {
    owner: self,
    baseline: self.last_timestamp,
    candidate: Pixel(candidate),
    frame: candidate.update(timestamp_us, observations, lost~, removed~),
    used: false,
  }
}

///|
pub fn FootprintRunWindowSession::prepare_ground(
  self : FootprintRunWindowSession,
  timestamp_us : Int64,
  observations : Array[@types.GroundObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> FootprintRunWindowPreparation raise @types.GroundError {
  guard self.measurement is Ground(original) else {
    raise @types.InvalidInput(
      "ground observations require a metric footprint run window session",
    )
  }
  let candidate = original.fork()
  {
    owner: self,
    baseline: self.last_timestamp,
    candidate: Ground(candidate),
    frame: {
      motion: candidate.update(timestamp_us, observations, lost~, removed~),
      projection_failures: [],
    },
    used: false,
  }
}

///|
/// Inspect actual candidate identities without exposing mutable filter arrays.
pub fn FootprintRunWindowPreparation::measurement(
  self : FootprintRunWindowPreparation,
) -> @moonground.MeasurementFrame {
  detached_footprint_measurement(self.frame)
}

///|
/// Compute assignments, original runs and statistics before installing the
/// measurement candidate. A failed commit remains retryable on this candidate.
pub fn FootprintRunWindowPreparation::commit(
  self : FootprintRunWindowPreparation,
  assignments : @zones.FootprintAssignments,
) -> FootprintRunWindowSessionFrame raise @types.GroundError {
  if self.used || self.owner.last_timestamp != self.baseline {
    raise @types.InvalidInput(
      "footprint run window preparation is used or stale",
    )
  }
  let measurement = detached_footprint_measurement(self.frame)
  let windows = self.owner.windows.update(self.frame.motion, assignments)
  // The original monitor and its statistics are now committed. Everything
  // remaining is non-raising, including projection diagnostics and installation.
  for failure in self.frame.projection_failures {
    windows.runs.evidence.unavailable.push({
      track_id: failure.track_id,
      segment_id: None,
      reason: @zones.Position(@zones.RejectedProjection),
    })
  }
  windows.runs.evidence.unavailable.sort_by((a, b) => {
    a.track_id.compare(b.track_id)
  })
  self.owner.measurement = self.candidate
  self.owner.last_timestamp = Some(self.frame.motion.timestamp_us)
  self.used = true
  { measurement, windows, }
}

///|
pub fn FootprintRunWindowSession::update_pixel(
  self : FootprintRunWindowSession,
  timestamp_us : Int64,
  observations : Array[@moonground.PixelObservation],
  assignments : @zones.FootprintAssignments,
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> FootprintRunWindowSessionFrame raise @types.GroundError {
  self
  .prepare_pixel(timestamp_us, observations, lost~, removed~)
  .commit(assignments)
}

///|
pub fn FootprintRunWindowSession::update_ground(
  self : FootprintRunWindowSession,
  timestamp_us : Int64,
  observations : Array[@types.GroundObservation],
  assignments : @zones.FootprintAssignments,
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> FootprintRunWindowSessionFrame raise @types.GroundError {
  self
  .prepare_ground(timestamp_us, observations, lost~, removed~)
  .commit(assignments)
}

///|
/// Close visible and hidden motion segments through one genuine empty input.
pub fn FootprintRunWindowSession::interrupt(
  self : FootprintRunWindowSession,
  timestamp_us : Int64,
) -> FootprintRunWindowSessionFrame raise @types.GroundError {
  let prepared = match self.measurement {
    Pixel(session) => {
      let removed = session.estimator.tracks.keys().collect()
      removed.sort()
      self.prepare_pixel(timestamp_us, [], removed~)
    }
    Ground(estimator) => {
      let removed = estimator.tracks.keys().collect()
      removed.sort()
      self.prepare_ground(timestamp_us, [], removed~)
    }
  }
  prepared.commit(@zones.FootprintAssignments::new(timestamp_us, []))
}

///|
/// Warm pixel re-expression preserves metric run, window and segment state.
pub fn FootprintRunWindowSession::reframed(
  self : FootprintRunWindowSession,
  transform : @types.PixelTransform,
) -> FootprintRunWindowSession raise @types.GroundError {
  guard self.measurement is Pixel(original) else {
    raise @types.InvalidInput(
      "pixel reframing requires a pixel footprint run window session",
    )
  }
  {
    measurement: Pixel(original.reframed(transform)),
    windows: self.windows.fork(),
    last_timestamp: self.last_timestamp,
  }
}
