# Clean Linux image for installing and dogfooding nimlet.
# No Nim toolchain: only curl + CA certs to fetch the release installer.

FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

ENV HOME=/tmp/home \
    PATH=/tmp/home/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /workspace

# Install from GitHub Releases, then drop into an interactive shell.
# Use bash -c (not -lc): a login shell resets PATH and drops ~/.local/bin.
# Pin with NIMLET_VERSION=v0.1.1 (or leave unset for latest).
CMD ["bash", "-c", "curl -fsSL https://nimlet.niminal.dev/install.sh | sh && exec bash"]
