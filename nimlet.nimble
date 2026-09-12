version       = "0.1.0"
author        = "martin"
description   = "Minimal native coding agent"
license       = "MIT"
srcDir        = "src"
bin           = @["nimlet"]

requires "nim >= 2.0.0"
requires "nimgent >= 0.1.0"
requires "nimwire >= 0.1.0"
requires "nimterm >= 0.1.0"

task test, "Run the test suite":
  exec "nim c -r --hints:off --threads:on --mm:atomicArc tests/all_tests.nim"

task release, "Build release binary":
  exec "mkdir -p build && nim c -d:release --threads:on --mm:atomicArc -o:build/nimlet src/nimlet.nim"

task idleSmoke, "Idle CPU/wakeup smoke (IDLE_SECS=60 by default)":
  exec "scripts/idle_smoke.sh"
