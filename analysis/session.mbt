///|
/// Detach and validate a pixel stream and a counter at the same watermark.
pub fn AnalysisSession::from_pixel(
  measurement : @moonground.MeasurementSession,
  counting : @events.GateCounter,
) -> AnalysisSession raise @types.GroundError {
  AnalysisSession::from_checkpoint({
    version: 1,
    measurement: Pixel(measurement.checkpoint()),
    counting: counting.checkpoint(),
  })
}

///|
/// Detach and validate a metric stream and a counter at the same watermark.
pub fn AnalysisSession::from_ground(
  measurement : @motion.MotionEstimator,
  counting : @events.GateCounter,
) -> AnalysisSession raise @types.GroundError {
  AnalysisSession::from_checkpoint({
    version: 1,
    measurement: Ground(measurement.checkpoint()),
    counting: counting.checkpoint(),
  })
}

///|
/// Export both states after the same committed frame.
pub fn AnalysisSession::checkpoint(
  self : AnalysisSession,
) -> AnalysisCheckpoint {
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
/// Branch both engines without replay, covariance validation or state mutation.
pub fn AnalysisSession::fork(self : AnalysisSession) -> AnalysisSession {
  {
    measurement: match self.measurement {
      Pixel(session) => Pixel(session.fork())
      Ground(estimator) => Ground(estimator.fork())
    },
    counting: self.counting.fork(),
  }
}

///|
pub fn AnalysisSession::update_pixel(
  self : AnalysisSession,
  timestamp_us : Int64,
  observations : Array[@moonground.PixelObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> AnalysisFrame raise @types.GroundError {
  guard self.measurement is Pixel(original) else {
    raise @types.InvalidInput(
      "pixel observations require a pixel analysis session",
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
pub fn AnalysisSession::update_ground(
  self : AnalysisSession,
  timestamp_us : Int64,
  observations : Array[@types.GroundObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> AnalysisFrame raise @types.GroundError {
  guard self.measurement is Ground(original) else {
    raise @types.InvalidInput(
      "ground observations require a ground analysis session",
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
/// Re-express future pixel observations while preserving committed metric
/// motion, gates, anchors and totals. Ground sessions have no pixel coordinates.
pub fn AnalysisSession::reframed(
  self : AnalysisSession,
  transform : @types.PixelTransform,
) -> AnalysisSession raise @types.GroundError {
  guard self.measurement is Pixel(original) else {
    raise @types.InvalidInput(
      "pixel reframing requires a pixel analysis session",
    )
  }
  {
    measurement: Pixel(original.reframed(transform)),
    counting: self.counting.fork(),
  }
}
