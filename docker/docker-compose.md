# Smoke-test the curl installer in Docker

`docker-compose.yml` builds a clean Debian Bookworm image with no Nim
toolchain. It only has `curl` and CA certs, then runs the published
installer and prints `nimlet --version`.

Use this to confirm a release tarball installs on a stock Linux host.

## Run

From the `nimlet` repo root:

```sh
docker compose build
docker compose run --rm nimlet
```

Expected output ends with something like `nimlet 0.1.1`.

Pin a release while the “latest” tag is still catching up:

```sh
NIMLET_VERSION=v0.1.1 docker compose run --rm nimlet
```

## Notes

- Provider keys listed in `docker-compose.yml` (`OPENROUTER_API_KEY`,
  `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `HYPER_API_KEY`) are passed through
  from your host environment when set.
- The container uses `$HOME=/tmp/home`, so the install lands under
  `/tmp/home/.local/...` inside the container and is discarded when it exits.
- Rebuild after changing the `Dockerfile`:
  `docker compose build --no-cache`
- For packaging CI’s tarball-in-container check (local artifact, not GitHub),
  use `./scripts/test-linux-install.sh` instead.
