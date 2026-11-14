///|
test "existing unannotated zone decision constructor remains unambiguous" {
  let decision = @zones.Indeterminate
  debug_inspect(decision, content="Indeterminate")
}
