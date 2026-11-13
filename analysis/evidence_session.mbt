///|
/// Validate and detach a pixel stream and an evidence counter at one watermark.
pub fn EvidenceAnalysisSession::from_pixel(
  measurement : @moonground.MeasurementSession,
  counting : @events.EvidenceGateCounter,
) -> EvidenceAnalysisSession raise @types.GroundError {
  EvidenceAnalysisSession::from_checkpoint({
    version: 1,
    measurement: Pixel(measurement.checkpoint()),
    counting: counting.checkpoint(),
  })
}

///|
pub fn EvidenceAnalysisSession::from_ground(
  measurement : @motion.MotionEstimator,
  counting : @events.EvidenceGateCounter,
) -> EvidenceAnalysisSession raise @types.GroundError {
  EvidenceAnalysisSession::from_checkpoint({
    version: 1,
    measurement: Ground(measurement.checkpoint()),
    counting: counting.checkpoint(),
  })
}

///|
pub fn EvidenceAnalysisSession::checkpoint(
  self : EvidenceAnalysisSession,
) -> EvidenceAnalysisCheckpoint {
  {
    version: 1,
    measurement: match self.measurement {
      Pixel(session) => Pixel(session.checkpoint())
      Ground(estimator) => Ground(estimator.checkpoint())
    },
    counting: self.counting.checkpoint(),
  }
}

///|
/// Copy mutable containers without exporting or revalidating every frame.
pub fn EvidenceAnalysisSession::fork(
  self : EvidenceAnalysisSession,
) -> EvidenceAnalysisSession {
  {
    measurement: match self.measurement {
      Pixel(session) => Pixel(session.fork())
      Ground(estimator) => Ground(estimator.fork())
    },
    counting: self.counting.fork(),
  }
}

///|
/// An evidence geometry, numerical-domain or count failure also preserves
/// motion state, covariance, paths, segment allocation and frame time.
pub fn EvidenceAnalysisSession::update_pixel(
  self : EvidenceAnalysisSession,
  timestamp_us : Int64,
  observations : Array[@moonground.PixelObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> EvidenceAnalysisFrame raise @types.GroundError {
  guard self.measurement is Pixel(original) else {
    raise @types.InvalidInput(
      "pixel observations require a pixel evidence analysis session",
    )
  }
  let measurement = original.fork()
  let counting = self.counting.fork()
  let frame = measurement.update(timestamp_us, observations, lost~, removed~)
  let events = counting.update(frame.motion)
  self.measurement = Pixel(measurement)
  self.counting = counting
  { measurement: frame, counting: events, }
}

///|
pub fn EvidenceAnalysisSession::update_ground(
  self : EvidenceAnalysisSession,
  timestamp_us : Int64,
  observations : Array[@types.GroundObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> EvidenceAnalysisFrame raise @types.GroundError {
  guard self.measurement is Ground(original) else {
    raise @types.InvalidInput(
      "ground observations require a ground evidence analysis session",
    )
  }
  let measurement = original.fork()
  let counting = self.counting.fork()
  let frame = measurement.update(timestamp_us, observations, lost~, removed~)
  let events = counting.update(frame)
  self.measurement = Ground(measurement)
  self.counting = counting
  {
    measurement: { motion: frame, projection_failures: [], },
    counting: events,
  }
}

///|
/// End all active segments, including tracks not output by the previous frame.
/// Totals and the next segment identity remain; a failed interrupt is atomic.
pub fn EvidenceAnalysisSession::interrupt(
  self : EvidenceAnalysisSession,
  timestamp_us : Int64,
) -> EvidenceAnalysisFrame raise @types.GroundError {
  match self.measurement {
    Pixel(session) => {
      let removed = session.estimator.tracks.keys().collect()
      removed.sort()
      self.update_pixel(timestamp_us, [], removed~)
    }
    Ground(estimator) => {
      let removed = estimator.tracks.keys().collect()
      removed.sort()
      self.update_ground(timestamp_us, [], removed~)
    }
  }
}

///|
/// Re-express only pixel coordinates, preserving all committed metric evidence.
pub fn EvidenceAnalysisSession::reframed(
  self : EvidenceAnalysisSession,
  transform : @types.PixelTransform,
) -> EvidenceAnalysisSession raise @types.GroundError {
  guard self.measurement is Pixel(original) else {
    raise @types.InvalidInput(
      "pixel reframing requires a pixel evidence analysis session",
    )
  }
  {
    measurement: Pixel(original.reframed(transform)),
    counting: self.counting.fork(),
  }
}
