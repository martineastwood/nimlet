# Install and dogfood nimlet in Docker

`docker-compose.yml` builds a clean Debian Bookworm image with no Nim
toolchain. On start it runs the published installer, then drops you into a
Linux shell with `nimlet` on `PATH`.

Your Mac’s arch is used as-is: Apple Silicon pulls `nimlet-linux-aarch64`,
Intel pulls `nimlet-linux-x86_64`.

## Run

From the `nimlet` repo root:

```sh
docker compose build
docker compose run --rm nimlet
```

That installs the latest release (or `NIMLET_VERSION` if set), then leaves
you at a bash prompt. The repo is mounted at `/workspace`.

```sh
nimlet --version
nimlet
```

Pin a release:

```sh
NIMLET_VERSION=v0.1.1 docker compose run --rm nimlet
```

Pass provider keys from your host environment (they are listed in
`docker-compose.yml`):

```sh
OPENROUTER_API_KEY=sk-or-... docker compose run --rm nimlet
```

## Notes

- `$HOME` inside the container is `/tmp/home`, so the install lands under
  `/tmp/home/.local/...` and is discarded when the container exits.
- Project config and sessions under `/workspace/.nimlet` persist on the host
  via the bind mount.
- Rebuild after changing the `Dockerfile`:
  `docker compose build --no-cache`
- For packaging CI’s tarball-in-container check (local artifact, not GitHub),
  use `./scripts/test-linux-install.sh` instead.
