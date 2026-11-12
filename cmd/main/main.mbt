///|
extern "C" fn exit_process(code : Int32) = "exit"

///|
async fn diagnostic(message : String) -> Unit {
  @stdio.stderr.write(message + "\n")
  exit_process(2)
}

///|
fn reframe_line(
  state : Ref[@codec.ReplayReframer?],
  source : String,
) -> String raise @types.GroundError {
  match state.val {
    None => {
      let converter = @codec.ReplayReframer::new(source)
      let header = converter.header_line()
      state.val = Some(converter)
      header
    }
    Some(converter) => converter.process_line(source)
  }
}

///|
async fn main {
  let args = @env.args()
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    @stdio.stdout.write(
      "moonground (--stream | --checkpoint | --reframe) [--max-line-bytes N] | --project | --calibrate\nStream/checkpoint read configuration or {resume: checkpoint}, then frames. --checkpoint writes only the final state at EOF. --reframe reads {source: configuration_or_resume, transform: {...}}, then original frames, and writes transformed NDJSON.\n",
    )
    return
  }
  if args.length() < 2 ||
    (
      args[1] != "--stream" &&
      args[1] != "--checkpoint" &&
      args[1] != "--reframe" &&
      args[1] != "--project" &&
      args[1] != "--calibrate"
    ) {
    diagnostic(
      "usage: moonground (--stream | --checkpoint | --reframe) [--max-line-bytes N] | --project | --calibrate",
    )
    return
  }
  let mut max_bytes = 1048576
  let stream_mode = args[1] == "--stream" ||
    args[1] == "--checkpoint" ||
    args[1] == "--reframe"
  if args.length() == 4 && stream_mode && args[2] == "--max-line-bytes" {
    max_bytes = @string.parse_int(args[3], base=10) catch {
      _ => {
        diagnostic("max-line-bytes must be a positive integer")
        return
      }
    }
    if max_bytes <= 0 || max_bytes > 16777216 {
      diagnostic("max-line-bytes must be in [1,16777216]")
      return
    }
  } else if args.length() != 2 {
    diagnostic(
      "usage: moonground (--stream | --checkpoint | --reframe) [--max-line-bytes N] | --project | --calibrate",
    )
    return
  }
  let chunk = FixedArray::make(4096, b'\x00')
  let pending : Array[Byte] = []
  let mut session : @codec.ReplaySession? = None
  let reframer : Ref[@codec.ReplayReframer?] = Ref(None)
  let mut line_number = 1
  let mut projection_done = false
  while true {
    let count = @stdio.stdin.read(chunk)
    if count == 0 {
      break
    }
    for index in 0..<count {
      let byte = chunk[index]
      if byte == b'\n' {
        let line = @utf8.decode(Bytes::from_array(pending[:])) catch {
          _ => {
            diagnostic("line \{line_number}: invalid UTF-8")
            return
          }
        }
        if args[1] == "--reframe" {
          let output = reframe_line(reframer, line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          @stdio.stdout.write(output + "\n")
        } else if !stream_mode {
          if projection_done {
            diagnostic("stateless mode accepts exactly one line")
            return
          }
          let output = try {
            if args[1] == "--calibrate" {
              @codec.calibrate_json(line)
            } else {
              @codec.project_json(line)
            }
          } catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          @stdio.stdout.write(output + "\n")
          projection_done = true
        } else {
          match session {
            None =>
              session = Some(
                @codec.ReplaySession::open(line) catch {
                  error => {
                    diagnostic("line \{line_number}: " + error.message())
                    return
                  }
                },
              )
            Some(replay) => {
              let output = replay.process_line(line) catch {
                error => {
                  diagnostic("line \{line_number}: " + error.message())
                  return
                }
              }
              if args[1] == "--stream" {
                @stdio.stdout.write(output + "\n")
              }
            }
          }
        }
        line_number += 1
        pending.clear()
      } else {
        if pending.length() >= max_bytes {
          diagnostic("line \{line_number}: line byte limit exceeded")
          return
        }
        pending.push(byte)
      }
    }
  }
  if pending.length() > 0 {
    let line = @utf8.decode(Bytes::from_array(pending[:])) catch {
      _ => {
        diagnostic("line \{line_number}: invalid UTF-8")
        return
      }
    }
    if args[1] == "--reframe" {
      let output = reframe_line(reframer, line) catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      @stdio.stdout.write(output + "\n")
    } else if !stream_mode {
      if projection_done {
        diagnostic("stateless mode accepts exactly one line")
        return
      }
      let output = try {
        if args[1] == "--calibrate" {
          @codec.calibrate_json(line)
        } else {
          @codec.project_json(line)
        }
      } catch {
        error => {
          diagnostic("line \{line_number}: " + error.message())
          return
        }
      }
      @stdio.stdout.write(output + "\n")
      projection_done = true
    } else {
      match session {
        None =>
          session = Some(
            @codec.ReplaySession::open(line) catch {
              error => {
                diagnostic("line \{line_number}: " + error.message())
                return
              }
            },
          )
        Some(replay) => {
          let output = replay.process_line(line) catch {
            error => {
              diagnostic("line \{line_number}: " + error.message())
              return
            }
          }
          if args[1] == "--stream" {
            @stdio.stdout.write(output + "\n")
          }
        }
      }
    }
  }
  if args[1] == "--reframe" {
    if reframer.val is None {
      diagnostic("missing reframing header")
    }
  } else if stream_mode && session is None {
    diagnostic("missing configuration line")
  } else if !stream_mode && !projection_done {
    diagnostic("missing stateless request")
  }
  if args[1] == "--checkpoint" && session is Some(replay) {
    let checkpoint = replay.checkpoint_json() catch {
      error => {
        diagnostic("checkpoint: " + error.message())
        return
      }
    }
    @stdio.stdout.write(checkpoint + "\n")
  }
}
