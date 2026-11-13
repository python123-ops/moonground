name = "python123-ops/moonground"

version = "0.12.0"

readme = "README.mbt.md"

repository = "https://github.com/python123-ops/moonground"

license = "Apache-2.0"

keywords = [ "computer-vision", "ground-plane", "tracking", "measurement" ]

description = "Calibrated ground-plane measurements from timestamped object tracks"

preferred_target = "wasm-gc"

import {
  "python123-ops/moon-cv-geometry@0.2.2",
  "Lyllyl789/moon-kalman@0.2.1",
  "moonbitlang/async@0.21.3",
}
