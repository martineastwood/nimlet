# nimlet in Docker

`docker-compose.yml` at the repo root defines one service (`nimlet`) that:

- builds an image (`nimlet:dev`) with Nim, Nimble, git and Python 3 (the
  test suite spawns `python3` fixture servers),
- mounts the repo at `/workspace`, so code changes are picked up by every
  `docker compose run` without rebuilding the image,
- mounts the sibling `../nimgent` package at `/nimgent` and `../nimterm` at
  `/nimterm` so the relative package paths from `/workspace` resolve,
- forwards `OPENROUTER_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `HYPER_API_KEY` from your shell
  environment into the container, and
- stays running (`sleep infinity`) so you can open a shell in it.

## Up

```sh
docker compose up -d        # build if needed, leave the container Up
docker compose exec nimlet bash
```

`docker compose up` (foreground) also stays attached and idle; exec a
shell from another terminal the same way. One-shot commands still work
via `run`, which replaces the idle command:

```sh
docker compose run --rm nimlet nimble build
docker compose run --rm nimlet nimble test
docker compose run --rm -it nimlet ./nimlet
```

`nimble test` compiles and runs `tests/all_tests.nim`, which launches the
`python3` fixture servers from inside the container. Pass `-it` for the
TUI so keybindings work.

## Idle resource smoke

SCOPE wants ~0% CPU while sitting at the prompt. From the repo root:

```sh
./scripts/idle_smoke.sh                 # 60s default
IDLE_SECS=15 ./scripts/idle_smoke.sh    # quicker check
nimble idleSmoke
```

Or in Docker (Linux `/proc` path — preferred for wakeup counts):

```sh
docker compose run --rm nimlet ./scripts/idle_smoke.sh
```

The script builds nimlet, starts it in console mode with a dummy API key
(no provider calls), blocks at the prompt, samples CPU / RSS / voluntary
context switches, then sends `/quit`. It fails if the deltas look like a
poll loop.

## Env vars

Any host environment variable listed in `docker-compose.yml` under
`environment` is passed through to the container. A common invocation:

```sh
OPENROUTER_API_KEY=sk-or-... docker compose run --rm -it nimlet ./nimlet
```

To add another variable, add its name (unchanged) to the `environment`
list in `docker-compose.yml`, e.g.:

```yaml
    environment:
      - OPENROUTER_API_KEY
      - OPENAI_API_KEY
      - ANTHROPIC_API_KEY
      - HYPER_API_KEY
      - ANY_OTHER_VAR
```

Variables that aren't set on the host are omitted. Nimlet also reads
`~/.nimlet/config.json`, `~/.nimlet/AGENTS.md`, `~/.nimlet/skills/`,
`~/.nimlet/sessions/` (via `$HOME`); inside the container `$HOME` points
to a throwaway directory, so per-project config stays in the mounted repo
(`.nimlet/`), and sessions are ephemeral across containers. To persist
them, mount a host directory at `/workspace-volatile`, e.g. add to
`docker-compose.yml`:

```yaml
    volumes:
      - .:/workspace
      - ~/.nimlet:/workspace-volatile
```

## One-shot shell

```sh
docker compose run --rm -it nimlet bash
```
