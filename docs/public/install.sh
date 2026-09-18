#!/bin/sh
# Install the latest macOS nimlet release tarball from GitHub.
set -eu

REPO="${NIMLET_REPO:-martineastwood/nimlet}"
INSTALL_ROOT="${NIMLET_INSTALL_DIR:-$HOME/.local/lib/nimlet}"
BIN_DIR="${NIMLET_BIN_DIR:-$HOME/.local/bin}"

log() { printf ' \033[32m>\033[0m %s\n' "$1"; }
warn() { printf ' \033[33m!\033[0m %s\n' "$1"; }
err() { printf ' \033[31mx\033[0m %s\n' "$1" >&2; exit 1; }

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "requires '$1'"
  fi
}

main() {
  echo ""
  echo "  nimlet installer"
  echo "  https://nimlet.niminal.dev"
  echo ""

  OS="$(uname -s)"
  case "$OS" in
    Darwin) ;;
    *) err "this installer currently supports macOS only (got $OS)" ;;
  esac

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) err "unsupported architecture: $ARCH" ;;
  esac

  asset="nimlet-macos-${arch}.tar.gz"
  log "detected macos/${arch}"

  need curl
  need tar
  need mktemp

  if command -v shasum >/dev/null 2>&1; then
    SHA256_TOOL="shasum"
  elif command -v sha256sum >/dev/null 2>&1; then
    SHA256_TOOL="sha256sum"
  elif command -v openssl >/dev/null 2>&1; then
    SHA256_TOOL="openssl"
  else
    err "SHA-256 verification requires shasum, sha256sum, or openssl"
  fi

  if [ -n "${NIMLET_BASE_URL:-}" ]; then
    base="${NIMLET_BASE_URL%/}"
    log "downloading from ${base}..."
  elif [ -n "${NIMLET_VERSION:-}" ]; then
    version="$NIMLET_VERSION"
    case "$version" in
      v*) ;;
      *) version="v${version}" ;;
    esac
    base="https://github.com/${REPO}/releases/download/${version}"
    log "downloading ${version}..."
  else
    base="https://github.com/${REPO}/releases/latest/download"
    log "downloading latest release..."
  fi

  url="${base}/${asset}"
  sum_url="${base}/${asset}.sha256"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "$url" -o "${tmp}/${asset}"; then
    err "download failed from ${url}
publish a macOS release tarball first, or set NIMLET_VERSION to an existing tag"
  fi
  if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 "$sum_url" -o "${tmp}/${asset}.sha256"; then
    err "checksum download failed from ${sum_url}"
  fi

  expected="$(awk '{ print tolower($1) }' "${tmp}/${asset}.sha256" | head -1)"
  if [ "${#expected}" -ne 64 ]; then
    err "release checksum file is not a valid SHA-256 digest"
  fi
  case "$expected" in
    *[!0-9a-f]*) err "release checksum file is not a valid SHA-256 digest" ;;
  esac

  case "$SHA256_TOOL" in
    shasum) actual="$(shasum -a 256 < "${tmp}/${asset}" | awk '{ print tolower($1) }')" ;;
    sha256sum) actual="$(sha256sum < "${tmp}/${asset}" | awk '{ print tolower($1) }')" ;;
    openssl) actual="$(openssl dgst -sha256 < "${tmp}/${asset}" | awk '{ print tolower($NF) }')" ;;
  esac
  if [ "$actual" != "$expected" ]; then
    err "downloaded checksum did not match"
  fi

  tar -xzf "${tmp}/${asset}" -C "$tmp"
  payload="${tmp}/nimlet-macos-${arch}"
  if [ ! -x "${payload}/nimlet" ]; then
    err "archive did not contain nimlet-macos-${arch}/nimlet"
  fi

  rm -rf "$INSTALL_ROOT"
  mkdir -p "$INSTALL_ROOT" "$BIN_DIR"
  cp -R "${payload}/." "$INSTALL_ROOT/"
  chmod +x "${INSTALL_ROOT}/nimlet"
  if [ -f "${INSTALL_ROOT}/rg" ]; then
    chmod +x "${INSTALL_ROOT}/rg"
  fi

  ln -sfn "${INSTALL_ROOT}/nimlet" "${BIN_DIR}/nimlet"
  if [ -x "${INSTALL_ROOT}/rg" ]; then
    ln -sfn "${INSTALL_ROOT}/rg" "${BIN_DIR}/rg"
  fi

  log "installed nimlet to ${INSTALL_ROOT}"
  log "linked ${BIN_DIR}/nimlet"

  case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *)
      echo ""
      warn "${BIN_DIR} is not in your PATH"
      echo "  add it to your shell config:"
      echo ""
      echo "    export PATH=\"${BIN_DIR}:\$PATH\""
      echo ""
      ;;
  esac

  if command -v nimlet >/dev/null 2>&1; then
    echo ""
    log "ready. run 'nimlet' to get started."
  else
    echo ""
    log "installed. open a new shell (or fix PATH) then run 'nimlet'."
  fi
  echo ""
}

main "$@"
