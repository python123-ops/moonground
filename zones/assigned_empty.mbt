///|
/// Whether this exact-timestamp bundle explicitly assigns no target shapes.
pub fn FootprintAssignments::is_empty(self : FootprintAssignments) -> Bool {
  self.assignments.is_empty()
}
