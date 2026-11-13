///|
/// Validate and detach a pixel measurement stream and an interval counter.
/// Previously completed intervals and pending entries are retained as saved;
/// no earlier entry is reconstructed from historical gate totals.
pub fn EvidenceTransitSession::from_pixel(
  measurement : @moonground.MeasurementSession,
  transit : @transit.EvidenceTransitCounter,
) -> EvidenceTransitSession raise @types.GroundError {
  EvidenceTransitSession::from_checkpoint({
    version: 1,
    measurement: Pixel(measurement.checkpoint()),
    transit: transit.checkpoint(),
  })
}

///|
pub fn EvidenceTransitSession::from_ground(
  measurement : @motion.MotionEstimator,
  transit : @transit.EvidenceTransitCounter,
) -> EvidenceTransitSession raise @types.GroundError {
  EvidenceTransitSession::from_checkpoint({
    version: 1,
    measurement: Ground(measurement.checkpoint()),
    transit: transit.checkpoint(),
  })
}

///|
pub fn EvidenceTransitSession::checkpoint(
  self : EvidenceTransitSession,
) -> EvidenceTransitSessionCheckpoint {
  {
    version: 1,
    measurement: match self.measurement {
      Pixel(session) => Pixel(session.checkpoint())
      Ground(estimator) => Ground(estimator.checkpoint())
    },
    transit: self.transit.checkpoint(),
  }
}

///|
/// Branch mutable containers without exporting or revalidating checkpoints.
pub fn EvidenceTransitSession::fork(
  self : EvidenceTransitSession,
) -> EvidenceTransitSession {
  {
    measurement: match self.measurement {
      Pixel(session) => Pixel(session.fork())
      Ground(estimator) => Ground(estimator.fork())
    },
    transit: self.transit.fork(),
  }
}

///|
/// The downstream counter already stages its complete update atomically.
/// Commit the measurement candidate only after that update succeeds; no second
/// counter or per-frame checkpoint is needed for rollback.
pub fn EvidenceTransitSession::update_pixel(
  self : EvidenceTransitSession,
  timestamp_us : Int64,
  observations : Array[@moonground.PixelObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> EvidenceTransitSessionFrame raise @types.GroundError {
  guard self.measurement is Pixel(original) else {
    raise @types.InvalidInput(
      "pixel observations require a pixel evidence transit session",
    )
  }
  let measurement = original.fork()
  let frame = measurement.update(timestamp_us, observations, lost~, removed~)
  let transit = self.transit.update(frame.motion)
  self.measurement = Pixel(measurement)
  { measurement: frame, transit, }
}

///|
pub fn EvidenceTransitSession::update_ground(
  self : EvidenceTransitSession,
  timestamp_us : Int64,
  observations : Array[@types.GroundObservation],
  lost~ : Array[Int32] = [],
  removed~ : Array[Int32] = [],
) -> EvidenceTransitSessionFrame raise @types.GroundError {
  guard self.measurement is Ground(original) else {
    raise @types.InvalidInput(
      "ground observations require a metric evidence transit session",
    )
  }
  let measurement = original.fork()
  let frame = measurement.update(timestamp_us, observations, lost~, removed~)
  let transit = self.transit.update(frame)
  self.measurement = Ground(measurement)
  { measurement: { motion: frame, projection_failures: [], }, transit, }
}

///|
/// End all active motion segments, including tracks hidden in the preceding
/// output. The same empty frame cancels pending intervals and clears evidence
/// anchors while preserving totals and the next segment identity.
pub fn EvidenceTransitSession::interrupt(
  self : EvidenceTransitSession,
  timestamp_us : Int64,
) -> EvidenceTransitSessionFrame raise @types.GroundError {
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
/// Re-express future pixel input, preserving committed metric motion, evidence
/// covariances, pending entry witnesses and interval totals.
pub fn EvidenceTransitSession::reframed(
  self : EvidenceTransitSession,
  transform : @types.PixelTransform,
) -> EvidenceTransitSession raise @types.GroundError {
  guard self.measurement is Pixel(original) else {
    raise @types.InvalidInput(
      "pixel reframing requires a pixel evidence transit session",
    )
  }
  {
    measurement: Pixel(original.reframed(transform)),
    transit: self.transit.fork(),
  }
}
