#!/usr/bin/env bash
# Smoke-test a Linux nimlet tarball inside a clean Debian container.
# Usage: ./scripts/test-linux-install.sh [path-to-tarball]
#
# On Apple Silicon, testing an x86_64 CI artifact needs Docker's amd64 emulation:
#   ./scripts/test-linux-install.sh dist/nimlet-linux-x86_64.tar.gz
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need docker

TARBALL="${1:-}"
if [[ -z "$TARBALL" ]]; then
  shopt -s nullglob
  candidates=(dist/nimlet-linux-*.tar.gz)
  shopt -u nullglob
  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "usage: $0 path/to/nimlet-linux-*.tar.gz" >&2
    exit 1
  fi
  TARBALL="${candidates[0]}"
fi

if [[ ! -f "$TARBALL" ]]; then
  echo "tarball not found: $TARBALL" >&2
  exit 1
fi

TARBALL="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"
base="$(basename "$TARBALL" .tar.gz)"
arch="${base##*-}"
case "$arch" in
  x86_64) platform="linux/amd64" ;;
  aarch64) platform="linux/arm64" ;;
  *)
    echo "could not infer docker platform from $base" >&2
    exit 1
    ;;
esac

echo "==> testing $TARBALL on $platform"
docker run --rm --platform="$platform" \
  -v "$TARBALL:/pkg/${base}.tar.gz:ro" \
  -v "$ROOT/scripts/install.sh:/pkg/install.sh:ro" \
  debian:bookworm-slim \
  bash -c "
    set -euo pipefail
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates curl >/dev/null
    # Serve the tarball + checksum the way GitHub Releases would.
    cd /pkg
    sha256sum '${base}.tar.gz' | awk '{print \$1}' > '${base}.tar.gz.sha256'
    # Busybox-free: use python if present, else a tiny background curl file server via python3 from apt
    apt-get install -y -qq --no-install-recommends python3 >/dev/null
    python3 -m http.server 8765 >/tmp/http.log 2>&1 &
    sleep 0.5
    export HOME=/tmp/home
    mkdir -p \"\$HOME\"
    export NIMLET_BASE_URL=http://127.0.0.1:8765
    export PATH=\"\$HOME/.local/bin:/usr/bin:/bin\"
    sh /pkg/install.sh
    nimlet --version
  "

echo "==> linux install smoke test passed"
