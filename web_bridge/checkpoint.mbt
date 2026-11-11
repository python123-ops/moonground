///|
/// Export a session without consuming a frame or changing its lifecycle state.
pub fn moonground_checkpoint(handle : Int32) -> String {
  let session = match sessions.get(handle) {
    Some(session) => session
    None => return failure("unknown browser session handle")
  }
  session.checkpoint_json() catch {
    error => failure(error.message())
  }
}

///|
/// Validate the complete saved session before allocating a new handle.
/// Existing sessions and the monotonic handle counter survive failed restores.
pub fn moonground_restore(source : String) -> String {
  if sessions.length() >= 64 || next_handle.val == 2147483647 {
    return failure("browser session capacity exceeded")
  }
  let session = @codec.ReplaySession::from_checkpoint_json(source) catch {
    error => return failure(error.message())
  }
  let handle = next_handle.val
  next_handle.val += 1
  sessions[handle] = session
  Json::object({ "handle": Json(handle) }).stringify()
}
