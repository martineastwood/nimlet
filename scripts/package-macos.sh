#!/usr/bin/env bash
# Build a self-contained macOS nimlet tarball with bundled OpenSSL + PCRE.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  arm64|aarch64) ARCH="aarch64" ;;
  x86_64|amd64) ARCH="x86_64" ;;
  *) echo "unsupported architecture: $ARCH_RAW" >&2; exit 1 ;;
esac

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need brew
need nim
need nimble
need otool
need install_name_tool
need tar
need shasum
need codesign

OPENSSL_PREFIX="$(brew --prefix openssl@3)"
PCRE_PREFIX="$(brew --prefix pcre)"
for lib in \
  "$OPENSSL_PREFIX/lib/libssl.3.dylib" \
  "$OPENSSL_PREFIX/lib/libcrypto.3.dylib" \
  "$PCRE_PREFIX/lib/libpcre.1.dylib"
do
  if [[ ! -f "$lib" ]]; then
    echo "missing library: $lib" >&2
    echo "install with: brew install openssl@3 pcre" >&2
    exit 1
  fi
done

VERSION="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' nimlet.nimble | head -1)"
if [[ -z "$VERSION" ]]; then
  VERSION="0.0.0"
fi

STAGE="build/package-macos"
DIST_NAME="nimlet-macos-${ARCH}"
STAGE_DIR="$STAGE/$DIST_NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE_DIR" build dist

# Prefer published Nimble packages for the release artifact, even in a monorepo
# checkout. Restore develop links afterwards.
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

# Isolate deps under the build tree so packaging does not touch ~/.nimble.
export NIMBLE_DIR="${ROOT}/build/package-macos-nimble"
rm -rf "$NIMBLE_DIR"
mkdir -p "$NIMBLE_DIR"

# Pin dependency git refs. Default to #head so packaging tracks current package
# APIs; override with NIMLET_DEP_TAG=v0.1.0 for a tagged release once tags are
# cut to match nimlet.
DEP_TAG="${NIMLET_DEP_TAG:-head}"
echo "==> resolving Nimble dependencies (@#${DEP_TAG})"
nimble install "nimgent@#${DEP_TAG}" -y
nimble install "nimterm@#${DEP_TAG}" -y
nimble install "nimwire@#${DEP_TAG}" -y
nimble setup -y
echo "==> compiling nimlet (OpenSSL + PCRE linked)"
export PKG_CONFIG_PATH="${OPENSSL_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
nim c -d:release --threads:on --mm:orc --hints:off \
  --dynlibOverride:pcre \
  --passL:"-L${OPENSSL_PREFIX}/lib" \
  --passL:"-lssl" \
  --passL:"-lcrypto" \
  --passL:"-L${PCRE_PREFIX}/lib" \
  --passL:"-lpcre" \
  -o:build/nimlet \
  src/nimlet.nim

cp -f build/nimlet "$STAGE_DIR/nimlet"
cp -f "$OPENSSL_PREFIX/lib/libssl.3.dylib" "$STAGE_DIR/"
cp -f "$OPENSSL_PREFIX/lib/libcrypto.3.dylib" "$STAGE_DIR/"
cp -f "$PCRE_PREFIX/lib/libpcre.1.dylib" "$STAGE_DIR/"
chmod +x "$STAGE_DIR/nimlet"

# Optional: include Homebrew ripgrep when available (skip IDE-bundled copies).
RG_BIN=""
if [[ -x "$(brew --prefix ripgrep 2>/dev/null)/bin/rg" ]]; then
  RG_BIN="$(brew --prefix ripgrep)/bin/rg"
elif command -v rg >/dev/null 2>&1; then
  candidate="$(command -v rg)"
  case "$candidate" in
    *"/Cursor.app/"*|*"/Visual Studio Code.app/"*|*"/Code.app/"*) ;;
    *) RG_BIN="$candidate" ;;
  esac
fi
if [[ -n "$RG_BIN" && -f "$RG_BIN" ]] && file "$RG_BIN" | grep -q "Mach-O"; then
  cp -f "$RG_BIN" "$STAGE_DIR/rg"
  chmod +x "$STAGE_DIR/rg"
  echo "==> bundled rg from $RG_BIN"
fi

cat > "$STAGE_DIR/THIRD_PARTY.txt" <<EOF
This archive bundles third-party libraries next to the nimlet binary.

OpenSSL 3 - Apache-2.0
  https://www.openssl.org/

PCRE 8 - BSD-3-Clause
  https://www.pcre.org/

ripgrep (optional) - Unlicense / MIT
  https://github.com/BurntSushi/ripgrep
EOF

rewrite_deps() {
  local target="$1"
  local dep old new
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    case "$dep" in
      *libssl.3.dylib)
        old="$dep"
        new="@executable_path/libssl.3.dylib"
        ;;
      *libcrypto.3.dylib)
        old="$dep"
        new="@executable_path/libcrypto.3.dylib"
        ;;
      *libpcre.1.dylib|*libpcre.dylib)
        old="$dep"
        new="@executable_path/libpcre.1.dylib"
        ;;
      *)
        continue
        ;;
    esac
    if [[ "$old" != "$new" ]]; then
      install_name_tool -change "$old" "$new" "$target"
    fi
  done < <(otool -L "$target" | awk 'NR>1 {print $1}')
}

echo "==> rewriting dylib install names to @executable_path"
for lib in libssl.3.dylib libcrypto.3.dylib libpcre.1.dylib; do
  install_name_tool -id "@executable_path/$lib" "$STAGE_DIR/$lib"
  rewrite_deps "$STAGE_DIR/$lib"
done
rewrite_deps "$STAGE_DIR/nimlet"

# Changing load commands invalidates the ad-hoc signature on Apple Silicon.
codesign --force -s - "$STAGE_DIR/libssl.3.dylib"
codesign --force -s - "$STAGE_DIR/libcrypto.3.dylib"
codesign --force -s - "$STAGE_DIR/libpcre.1.dylib"
codesign --force -s - "$STAGE_DIR/nimlet"
if [[ -f "$STAGE_DIR/rg" ]]; then
  codesign --force -s - "$STAGE_DIR/rg" || true
fi

echo "==> verifying bundled linkage"
otool -L "$STAGE_DIR/nimlet" | tee "$STAGE/otool-nimlet.txt"
if otool -L "$STAGE_DIR/nimlet" | grep -E '/opt/homebrew|/usr/local/opt|Cellar/' >/dev/null; then
  echo "error: nimlet still references Homebrew absolute paths" >&2
  exit 1
fi
if ! otool -L "$STAGE_DIR/nimlet" | grep -q '@executable_path/libssl.3.dylib'; then
  echo "error: nimlet is not linked to bundled libssl" >&2
  exit 1
fi
if ! otool -L "$STAGE_DIR/nimlet" | grep -q '@executable_path/libpcre.1.dylib'; then
  echo "error: nimlet is not linked to bundled libpcre" >&2
  exit 1
fi

echo "==> smoke test"
"$STAGE_DIR/nimlet" --version

TARBALL="dist/${DIST_NAME}.tar.gz"
CHECKSUM="dist/${DIST_NAME}.tar.gz.sha256"
tar -C "$STAGE" -czf "$TARBALL" "$DIST_NAME"
shasum -a 256 "$TARBALL" | awk '{print $1}' > "$CHECKSUM"

echo ""
echo "packed ${TARBALL}"
echo "version ${VERSION}"
echo "sha256 $(cat "$CHECKSUM")"
echo "arch ${ARCH}"
