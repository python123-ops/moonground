///|
pub fn FootprintRunSession::from_pixel(
  measurement : @moonground.MeasurementSession,
  runs : @zones.FootprintRunMonitor,
) -> FootprintRunSession raise @types.GroundError {
  FootprintRunSession::from_checkpoint({
    version: 1,
    measurement: Pixel(measurement.checkpoint()),
    runs: runs.checkpoint(),
  })
}

///|
pub fn FootprintRunSession::from_ground(
  measurement : @motion.MotionEstimator,
  runs : @zones.FootprintRunMonitor,
) -> FootprintRunSession raise @types.GroundError {
  FootprintRunSession::from_checkpoint({
    version: 1,
    measurement: Ground(measurement.checkpoint()),
    runs: runs.checkpoint(),
  })
}

///|
pub fn FootprintRunSession::checkpoint(
  self : FootprintRunSession,
) -> FootprintRunSessionCheckpoint {
  {
    version: 1,
    measurement: match self.measurement {
      Pixel(session) => Pixel(session.checkpoint())
      Ground(estimator) => Ground(estimator.checkpoint())
    },
    runs: self.runs.checkpoint(),
  }
}

///|
pub fn FootprintRunSession::fork(
  self : FootprintRunSession,
) -> FootprintRunSession {
  {
    measurement: match self.measurement {
      Pixel(session) => Pixel(session.fork())
      Ground(estimator) => Ground(estimator.fork())
    },
    runs: self.runs.fork(),
    last_timestamp: self.last_timestamp,
  }
}

///|
fn detached_footprint_measurement(
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
/// Inspect actual candidate segments without advancing either committed engine.
pub fn FootprintRunSession::prepare_pixel(
  self : FootprintRunSession,
  timestamp_us : Int64,
  observations : Array[@moonground.PixelObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> FootprintRunPreparation raise @types.GroundError {
  guard self.measurement is Pixel(original) else {
    raise @types.InvalidInput(
      "pixel observations require a pixel footprint run session",
    )
  }
  let candidate = original.fork()
  let frame = candidate.update(timestamp_us, observations, lost~, removed~)
  {
    owner: self,
    baseline: self.last_timestamp,
    candidate: Pixel(candidate),
    frame,
    used: false,
  }
}

///|
pub fn FootprintRunSession::prepare_ground(
  self : FootprintRunSession,
  timestamp_us : Int64,
  observations : Array[@types.GroundObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> FootprintRunPreparation raise @types.GroundError {
  guard self.measurement is Ground(original) else {
    raise @types.InvalidInput(
      "ground observations require a metric footprint run session",
    )
  }
  let candidate = original.fork()
  let frame = candidate.update(timestamp_us, observations, lost~, removed~)
  {
    owner: self,
    baseline: self.last_timestamp,
    candidate: Ground(candidate),
    frame: { motion: frame, projection_failures: [], },
    used: false,
  }
}

///|
/// All nested diagnostics and result arrays are detached from the candidate.
pub fn FootprintRunPreparation::measurement(
  self : FootprintRunPreparation,
) -> @moonground.MeasurementFrame {
  detached_footprint_measurement(self.frame)
}

///|
/// Bind the exact current segments, then atomically install both stages.
/// A failed assignment or evidence calculation leaves this candidate retryable.
pub fn FootprintRunPreparation::commit(
  self : FootprintRunPreparation,
  assignments : @zones.FootprintAssignments,
) -> FootprintRunSessionFrame raise @types.GroundError {
  if self.used || self.owner.last_timestamp != self.baseline {
    raise @types.InvalidInput("footprint run preparation is used or stale")
  }
  let measurement = detached_footprint_measurement(self.frame)
  let runs = self.owner.runs.update(self.frame.motion, assignments)
  // Every operation after the monitor's atomic update is non-raising.
  for failure in self.frame.projection_failures {
    runs.evidence.unavailable.push({
      track_id: failure.track_id,
      segment_id: None,
      reason: @zones.Position(@zones.RejectedProjection),
    })
  }
  runs.evidence.unavailable.sort_by((a, b) => a.track_id.compare(b.track_id))
  self.owner.measurement = self.candidate
  self.owner.last_timestamp = Some(self.frame.motion.timestamp_us)
  self.used = true
  { measurement, runs, }
}

///|
pub fn FootprintRunSession::update_pixel(
  self : FootprintRunSession,
  timestamp_us : Int64,
  observations : Array[@moonground.PixelObservation],
  assignments : @zones.FootprintAssignments,
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> FootprintRunSessionFrame raise @types.GroundError {
  self
  .prepare_pixel(timestamp_us, observations, lost~, removed~)
  .commit(assignments)
}

///|
pub fn FootprintRunSession::update_ground(
  self : FootprintRunSession,
  timestamp_us : Int64,
  observations : Array[@types.GroundObservation],
  assignments : @zones.FootprintAssignments,
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> FootprintRunSessionFrame raise @types.GroundError {
  self
  .prepare_ground(timestamp_us, observations, lost~, removed~)
  .commit(assignments)
}

///|
/// End every active segment, including motion hidden in previous output.
pub fn FootprintRunSession::interrupt(
  self : FootprintRunSession,
  timestamp_us : Int64,
) -> FootprintRunSessionFrame raise @types.GroundError {
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
pub fn FootprintRunSession::reframed(
  self : FootprintRunSession,
  transform : @types.PixelTransform,
) -> FootprintRunSession raise @types.GroundError {
  guard self.measurement is Pixel(original) else {
    raise @types.InvalidInput(
      "pixel reframing requires a pixel footprint run session",
    )
  }
  {
    measurement: Pixel(original.reframed(transform)),
    runs: self.runs.fork(),
    last_timestamp: self.last_timestamp,
  }
}
