#!/usr/bin/env bash
# Build a self-contained Linux nimlet tarball with bundled OpenSSL + PCRE.
# Intended for Linux CI on Ubuntu 22.04 (glibc 2.35 baseline). Test with:
#   ./scripts/test-linux-install.sh dist/nimlet-linux-x86_64.tar.gz
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "package-linux.sh must run on Linux (GitHub Actions ubuntu-22.04)" >&2
  echo "after CI builds the artifact, test it with: ./scripts/test-linux-install.sh" >&2
  exit 1
fi

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  *) echo "unsupported architecture: $ARCH_RAW" >&2; exit 1 ;;
esac

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need nim
need nimble
need tar
need sha256sum
need patchelf
need readelf
need ldd
need strip

MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
LIB_DIRS=(
  "/usr/lib/${MULTIARCH}"
  /usr/lib64
  /usr/lib
  /lib/"${MULTIARCH}"
  /lib64
  /lib
)

find_so() {
  local name="$1" dir candidate
  for dir in "${LIB_DIRS[@]}"; do
    candidate="${dir}/${name}"
    if [[ -f "$candidate" ]]; then
      # Prefer the real file over a linker script.
      if head -c 4 "$candidate" 2>/dev/null | grep -q $'\x7fELF'; then
        echo "$candidate"
        return 0
      fi
      # Some .so files are linker scripts; resolve the first GROUP/INPUT path.
      if grep -q 'GROUP\|INPUT' "$candidate" 2>/dev/null; then
        local resolved
        resolved="$(grep -Eo '/[^ )]+' "$candidate" | head -1 || true)"
        if [[ -n "$resolved" && -f "$resolved" ]]; then
          echo "$resolved"
          return 0
        fi
      fi
    fi
  done
  if command -v ldconfig >/dev/null 2>&1; then
    ldconfig -p 2>/dev/null | awk -v n="$name" '$1 == n { print $NF; exit }'
  fi
}

# Debian/Ubuntu: libssl.so.3, libcrypto.so.3, libpcre.so.3
SSL_SO="$(find_so libssl.so.3 || true)"
CRYPTO_SO="$(find_so libcrypto.so.3 || true)"
PCRE_SO="$(find_so libpcre.so.3 || find_so libpcre.so.1 || true)"

if [[ -z "$SSL_SO" || -z "$CRYPTO_SO" || -z "$PCRE_SO" ]]; then
  echo "missing OpenSSL/PCRE shared libraries" >&2
  echo "  libssl:    ${SSL_SO:-not found}" >&2
  echo "  libcrypto: ${CRYPTO_SO:-not found}" >&2
  echo "  libpcre:   ${PCRE_SO:-not found}" >&2
  echo "install with: apt-get install -y libssl3 libssl-dev libpcre3 libpcre3-dev" >&2
  exit 1
fi

SSL_DIR="$(dirname "$SSL_SO")"
PCRE_DIR="$(dirname "$PCRE_SO")"
SSL_NAME="$(basename "$SSL_SO")"
CRYPTO_NAME="$(basename "$CRYPTO_SO")"
PCRE_NAME="$(basename "$PCRE_SO")"

VERSION="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' nimlet.nimble | head -1)"
if [[ -z "$VERSION" ]]; then
  VERSION="0.0.0"
fi

STAGE="build/package-linux"
DIST_NAME="nimlet-linux-${ARCH}"
STAGE_DIR="$STAGE/$DIST_NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE_DIR" build dist

DEVELOP_BAK=""
if [[ -f nimble.develop ]]; then
  DEVELOP_BAK="$(mktemp)"
  mv nimble.develop "$DEVELOP_BAK"
  restore_develop() {
    if [[ -n "${DEVELOP_BAK}" && -f "${DEVELOP_BAK}" ]]; then
      mv "${DEVELOP_BAK}" nimble.develop
    fi
  }
  trap restore_develop EXIT
fi

export NIMBLE_DIR="${ROOT}/build/package-linux-nimble"
rm -rf "$NIMBLE_DIR"
mkdir -p "$NIMBLE_DIR"

DEP_TAG="${NIMLET_DEP_TAG:-head}"
echo "==> resolving Nimble dependencies (@#${DEP_TAG})"
dep_tmp="$(mktemp -d)"
(
  cd "$dep_tmp"
  nimble install "nimterm@#${DEP_TAG}" -y
  nimble install "nimgent@#${DEP_TAG}" -y
  nimble install "nimwire@#${DEP_TAG}" -y
)
rm -rf "$dep_tmp"
nimble setup -y

echo "==> compiling nimlet (OpenSSL + PCRE linked, rpath \$ORIGIN)"
nim c -d:release --threads:on --mm:orc --hints:off \
  --dynlibOverride:ssl \
  --dynlibOverride:crypto \
  --dynlibOverride:pcre \
  --passL:"-L${SSL_DIR}" \
  --passL:"-lssl" \
  --passL:"-lcrypto" \
  --passL:"-L${PCRE_DIR}" \
  --passL:"-lpcre" \
  --passL:"-Wl,-rpath,\$ORIGIN" \
  -o:build/nimlet \
  src/nimlet.nim

cp -f build/nimlet "$STAGE_DIR/nimlet"
cp -f "$SSL_SO" "$STAGE_DIR/$SSL_NAME"
cp -f "$CRYPTO_SO" "$STAGE_DIR/$CRYPTO_NAME"
cp -f "$PCRE_SO" "$STAGE_DIR/$PCRE_NAME"
chmod +x "$STAGE_DIR/nimlet"
strip --strip-unneeded "$STAGE_DIR/nimlet"

# Keep SONAME filenames; ensure the binary looks next to itself.
patchelf --set-rpath '$ORIGIN' "$STAGE_DIR/nimlet"
patchelf --set-rpath '$ORIGIN' "$STAGE_DIR/$SSL_NAME" || true
patchelf --set-rpath '$ORIGIN' "$STAGE_DIR/$CRYPTO_NAME" || true
patchelf --set-rpath '$ORIGIN' "$STAGE_DIR/$PCRE_NAME" || true

if command -v rg >/dev/null 2>&1; then
  RG_BIN="$(command -v rg)"
  if file "$RG_BIN" | grep -qi "ELF"; then
    cp -f "$RG_BIN" "$STAGE_DIR/rg"
    chmod +x "$STAGE_DIR/rg"
    echo "==> bundled rg from $RG_BIN"
  fi
fi

cat > "$STAGE_DIR/THIRD_PARTY.txt" <<EOF
This archive bundles third-party libraries next to the nimlet binary.

OpenSSL 3 - Apache-2.0
  https://www.openssl.org/

PCRE - BSD-3-Clause
  https://www.pcre.org/

ripgrep (optional) - Unlicense / MIT
  https://github.com/BurntSushi/ripgrep
EOF

echo "==> verifying bundled linkage"
ldd "$STAGE_DIR/nimlet" | tee "$STAGE/ldd-nimlet.txt"
if ! readelf -d "$STAGE_DIR/nimlet" | grep -Eq 'RPATH|RUNPATH'; then
  echo "error: nimlet is missing RPATH/RUNPATH" >&2
  exit 1
fi
if [[ ! -f "$STAGE_DIR/$SSL_NAME" || ! -f "$STAGE_DIR/$CRYPTO_NAME" || ! -f "$STAGE_DIR/$PCRE_NAME" ]]; then
  echo "error: staged shared libraries are incomplete" >&2
  exit 1
fi
if ldd "$STAGE_DIR/nimlet" | grep -E 'libssl|libcrypto|libpcre' | grep -q 'not found'; then
  echo "error: nimlet cannot resolve bundled OpenSSL/PCRE" >&2
  ldd "$STAGE_DIR/nimlet" >&2
  exit 1
fi

# Smoke-test with only the staged libs visible for our deps.
echo "==> smoke test"
(
  cd "$STAGE_DIR"
  ./nimlet --version
)

TARBALL="dist/${DIST_NAME}.tar.gz"
CHECKSUM="dist/${DIST_NAME}.tar.gz.sha256"
tar -C "$STAGE" -czf "$TARBALL" "$DIST_NAME"
sha256sum "$TARBALL" | awk '{print $1}' > "$CHECKSUM"

echo ""
echo "packed ${TARBALL}"
echo "version ${VERSION}"
echo "sha256 $(cat "$CHECKSUM")"
echo "arch ${ARCH}"
echo "libs ${SSL_NAME} ${CRYPTO_NAME} ${PCRE_NAME}"
