version       = "0.1.1"
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
  exec "nim c -r --hints:off --threads:on --mm:orc tests/all_tests.nim"
  exec "nim c -r --hints:off --threads:on --mm:orc tests/trace_metrics_tests.nim"

task release, "Build release binary":
  when defined(windows):
    exec "cmd.exe /c if not exist build mkdir build"
  else:
    exec "mkdir -p build"
  exec "nim c -d:release --threads:on --mm:orc -o:build/nimlet src/nimlet.nim"

task packageMacos, "Build self-contained macOS tarball with bundled OpenSSL and PCRE":
  exec "scripts/package-macos.sh"

task packageLinux, "Build self-contained Linux tarball (run on Linux / CI)":
  exec "scripts/package-linux.sh"

task idleSmoke, "Idle CPU/wakeup smoke (IDLE_SECS=60 by default)":
  exec "scripts/idle_smoke.sh"
