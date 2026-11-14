///|
test "assignment emptiness is read only and remains independent of the source array" {
  let entries : Array[@zones.FootprintAssignment] = []
  let empty = @zones.FootprintAssignments::new(0L, entries)
  entries.push(
    @zones.FootprintAssignment::new(
      1,
      "1",
      @zones.Disk(@zones.DiskFootprint::new(0.0)),
    ),
  )
  assert_eq(empty.is_empty(), true)
  let assigned = @zones.FootprintAssignments::new(0L, entries)
  entries.clear()
  assert_eq(assigned.is_empty(), false)
  assert_eq(empty.timestamp_us, 0L)
  assert_eq(assigned.timestamp_us, 0L)
}
