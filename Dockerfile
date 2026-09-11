# Build, test, and run nimlet in a Linux container.
#
# Usually you won't use this image directly: `docker compose up`
# builds it, mounts the repo at /workspace, and keeps the container
# running so you can exec a shell. The compiler, nimble, git and
# python3 (needed by the test suite's fixture servers) live in this
# image; your repo and its edits stay mounted on top of it.

FROM nimlang/nim:2.0.14

# Debian 12 (the image's base). Needed by the test suite, which spawns
# python3 HTTP fixture servers.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*

# The repo (and $HOME) are not baked in: docker compose mounts the repo
# at /workspace. `$HOME` is kept on a throwaway path so project and user
# config/sessions never clash with the mounted repository contents.
WORKDIR /workspace

CMD ["nimble", "build"]
