///|
let sessions : Map[Int32, @codec.ReplaySession] = Map([])

///|
let next_handle : Ref[Int32] = Ref(1)

///|
fn failure(message : String) -> String {
  Json::object({ "error": Json(message) }).stringify()
}

///|
/// Allocate a bounded browser session. Release the handle when replay finishes.
pub fn moonground_create(source : String) -> String {
  if sessions.length() >= 64 || next_handle.val == 2147483647 {
    return failure("browser session capacity exceeded")
  }
  let session = @codec.ReplaySession::open(source) catch {
    error => return failure(error.message())
  }
  let handle = next_handle.val
  next_handle.val += 1
  sessions[handle] = session
  Json::object({ "handle": Json(handle) }).stringify()
}

///|
/// Return the native replay JSON, preserving session state on rejected frames.
pub fn moonground_update(handle : Int32, source : String) -> String {
  let session = match sessions.get(handle) {
    Some(session) => session
    None => return failure("unknown browser session handle")
  }
  session.process_line(source) catch {
    error => failure(error.message())
  }
}

///|
/// Release a session's identity and motion state.
pub fn moonground_close(handle : Int32) -> Bool {
  let existed = sessions.contains(handle)
  sessions.remove(handle)
  existed
}

///|
/// Project points with the same calibration code as the native command.
pub fn moonground_project(source : String) -> String {
  @codec.project_json(source) catch {
    error => failure(error.message())
  }
}
