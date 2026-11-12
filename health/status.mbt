///|
/// The status at the last committed landmark frame, without consuming a new
/// sample or consulting wall-clock time. An unstarted monitor is insufficient.
pub fn CalibrationMonitor::status(self : CalibrationMonitor) -> HealthStatus {
  match self.last_timestamp {
    None => Insufficient
    Some(timestamp) => current_status(self.streak, timestamp, self.config)
  }
}
