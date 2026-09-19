# Clean Linux image for smoke-testing the curl installer.
# No Nim toolchain: only what a typical user needs to download and run nimlet.

FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

ENV HOME=/tmp/home \
    PATH=/tmp/home/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /tmp

# Install from GitHub Releases via the published installer, then print the version.
# Pin with NIMLET_VERSION=v0.1.1 (or leave unset for latest).
CMD ["bash", "-lc", "curl -fsSL https://nimlet.niminal.dev/install.sh | sh && nimlet --version"]
