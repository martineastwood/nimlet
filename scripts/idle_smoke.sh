#!/usr/bin/env bash
# Idle resource smoke: nimlet at the prompt should use ~0% CPU and not
# wake on a timer. SCOPE §36 — "agent sitting at prompt for 60 seconds".
#
# Usage (repo root):
#   ./scripts/idle_smoke.sh
#   IDLE_SECS=10 ./scripts/idle_smoke.sh          # faster local check
#   docker compose run --rm nimlet ./scripts/idle_smoke.sh
#
# Needs no real API key. Prefers Linux /proc (Docker); macOS reports
# CPU/RSS via ps and skips the wakeup assertion.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDLE_SECS="${IDLE_SECS:-60}"
SETTLE_SECS="${SETTLE_SECS:-2}"
# Allow a little noise; a poll loop at 10–60 Hz blows past these easily.
MAX_CPU_SEC="${MAX_CPU_SEC:-$(awk -v s="$IDLE_SECS" 'BEGIN { printf "%.3f", 0.01 * s + 0.2 }')}"
MAX_VOLUNTARY_DELTA="${MAX_VOLUNTARY_DELTA:-$((IDLE_SECS * 2 + 20))}"
MAX_RSS_KB="${MAX_RSS_KB:-200000}" # 200 MB soft ceiling, not a tight target

echo "==> building nimlet"
nimble build

export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-sk-idle-smoke-dummy}"
export HOME="${IDLE_HOME:-$(mktemp -d "${TMPDIR:-/tmp}/nimlet-idle-home.XXXXXX")}"
mkdir -p "$HOME/.nimlet"
# Non-stale empty catalog so startup does not hit the network.
printf '%s\n' '{}' >"$HOME/.nimlet/models-dev.json"
printf '%s\n' '{
  "default_provider": "openrouter",
  "default_model": "idle/smoke"
}' >"$HOME/.nimlet/config.json"

BIN="$ROOT/nimlet"
if [[ ! -x $BIN ]]; then
  echo "ERROR: missing binary $BIN" >&2
  exit 1
fi

OUT="$(mktemp "${TMPDIR:-/tmp}/nimlet-idle-out.XXXXXX")"
FIFO="$(mktemp -u "${TMPDIR:-/tmp}/nimlet-idle-fifo.XXXXXX")"
mkfifo "$FIFO"
PID=""

cleanup() {
  if [[ -n ${PID:-} ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  exec 3>&- 2>/dev/null || true
  rm -f "$FIFO" "$OUT"
}
trap cleanup EXIT

have_proc() {
  [[ -r /proc/$1/stat && -r /proc/$1/status ]]
}

read_cpu_sec() {
  # utime + stime in seconds
  local ticks hz
  ticks=$(awk '{print $14+$15}' "/proc/$1/stat")
  hz=$(getconf CLK_TCK)
  awk -v t="$ticks" -v h="$hz" 'BEGIN { printf "%.6f", t / h }'
}

read_rss_kb() {
  awk '/^VmRSS:/ { print $2; exit }' "/proc/$1/status"
}

read_voluntary() {
  awk '/^voluntary_ctxt_switches:/ { print $2; exit }' "/proc/$1/status"
}

echo "==> starting nimlet (console, stdin blocked ${IDLE_SECS}s)"
# Reader must open first; then the write end can open without blocking forever.
"$BIN" <"$FIFO" >"$OUT" 2>&1 &
PID=$!
exec 3>"$FIFO"

sleep "$SETTLE_SECS"
if ! kill -0 "$PID" 2>/dev/null; then
  echo "ERROR: nimlet exited during settle" >&2
  cat "$OUT" >&2 || true
  exit 1
fi
if ! grep -q "Type /help" "$OUT" 2>/dev/null; then
  # Give startup a moment more (slow CI disks).
  sleep 2
fi
if ! grep -q "Type /help" "$OUT" 2>/dev/null; then
  echo "ERROR: did not reach prompt" >&2
  cat "$OUT" >&2 || true
  exit 1
fi

if have_proc "$PID"; then
  cpu0=$(read_cpu_sec "$PID")
  rss0=$(read_rss_kb "$PID")
  vol0=$(read_voluntary "$PID")
  echo "    settle: cpu=${cpu0}s rss=${rss0}kB voluntary_wakeups=${vol0}"
  sleep "$IDLE_SECS"
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "ERROR: nimlet died while idle" >&2
    cat "$OUT" >&2 || true
    exit 1
  fi
  cpu1=$(read_cpu_sec "$PID")
  rss1=$(read_rss_kb "$PID")
  vol1=$(read_voluntary "$PID")
  cpu_delta=$(awk -v a="$cpu0" -v b="$cpu1" 'BEGIN { printf "%.6f", b - a }')
  vol_delta=$((vol1 - vol0))
  echo "    after ${IDLE_SECS}s: cpu=${cpu1}s rss=${rss1}kB voluntary_wakeups=${vol1}"
  echo "    delta: cpu=${cpu_delta}s voluntary_wakeups=${vol_delta}"

  fail=0
  awk -v d="$cpu_delta" -v m="$MAX_CPU_SEC" 'BEGIN { exit !(d > m) }' && {
    echo "FAIL: CPU delta ${cpu_delta}s exceeds max ${MAX_CPU_SEC}s (poll loop?)" >&2
    fail=1
  }
  if (( vol_delta > MAX_VOLUNTARY_DELTA )); then
    echo "FAIL: voluntary wakeups delta ${vol_delta} exceeds max ${MAX_VOLUNTARY_DELTA}" >&2
    fail=1
  fi
  if (( rss1 > MAX_RSS_KB )); then
    echo "FAIL: RSS ${rss1}kB exceeds max ${MAX_RSS_KB}kB" >&2
    fail=1
  fi
  if (( fail )); then
    exit 1
  fi
else
  # macOS / no /proc: sample %cpu a few times; expect ~0 while blocked.
  echo "    (no /proc — CPU%%/RSS via ps; wakeup check skipped)"
  sleep "$IDLE_SECS"
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "ERROR: nimlet died while idle" >&2
    cat "$OUT" >&2 || true
    exit 1
  fi
  # shellcheck disable=SC2009
  sample=$(ps -o %cpu=,rss= -p "$PID" | awk '{printf "cpu_pct=%s rss_kb=%s", $1, $2}')
  echo "    sample: $sample"
  cpu_pct=$(ps -o %cpu= -p "$PID" | tr -d ' ')
  rss_kb=$(ps -o rss= -p "$PID" | tr -d ' ')
  # ps %cpu is lifetime average; after a long idle it should be tiny.
  awk -v c="$cpu_pct" 'BEGIN { exit !(c + 0 > 5.0) }' && {
    echo "FAIL: ps %cpu ${cpu_pct} looks like sustained work" >&2
    exit 1
  }
  if (( rss_kb > MAX_RSS_KB )); then
    echo "FAIL: RSS ${rss_kb}kB exceeds max ${MAX_RSS_KB}kB" >&2
    exit 1
  fi
fi

printf '%s\n' '/quit' >&3
wait "$PID" || true
echo "OK: idle smoke passed (${IDLE_SECS}s at prompt)"
