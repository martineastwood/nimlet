# nimlet

A native coding agent written in Nim.

## Build and test

```sh
nimble build
nimble test
nimble idleSmoke   # ~60s at prompt; near-zero CPU (see scripts/idle_smoke.sh)
```

Set `NIMTERM_PERF=1` when debugging frame and event-to-render latency.

nimlet depends on the sibling [nimgent](../nimgent) package (LLM client
library) and [nimterm](../nimterm) (terminal UI primitives). Local development
resolves both via `nim.cfg`; with Docker Compose, `../nimgent` is mounted at
`/nimgent`. The `nimgent` package requirement resolves installed or published
versions; `nimterm` is currently developed from this sibling checkout.

Windows is not supported natively. Use [WSL](https://learn.microsoft.com/windows/wsl) and build inside the Linux environment.

Set the provider's API key before starting the agent:
`OPENROUTER_API_KEY` for OpenRouter, `OPENAI_API_KEY` for OpenAI,
`ANTHROPIC_API_KEY` for Anthropic, `HYPER_API_KEY` for Hyper, or
`AI_STUDIO_API_KEY` for Google Gemini.
Optional project configuration is read from `.nimlet/config.json` in the
workspace and overlays `~/.nimlet/config.json`. Global files live in
`~/.nimlet/`:

- `~/.nimlet/config.json` — default provider and model
- `~/.nimlet/AGENTS.md` — personal instructions (all projects)
- `~/.nimlet/skills/` — global skills
- `~/.nimlet/tools/` — global external tools
- `~/.nimlet/hooks/` — global lifecycle hooks
- `~/.nimlet/sessions/` — saved sessions
- `~/.nimlet/models-dev.json` — cached model metadata

To use Anthropic, run `/provider anthropic`. The first switch selects
`claude-sonnet-4-6`; subsequent switches restore your last model for that provider.
Use `/model <id>` to change it. Choices persist in `providers.<name>.last_model`.
The key is read from `ANTHROPIC_API_KEY`; no key belongs in the config file.
Native streaming, tool calls, thinking (`/thinking high`), and hosted search
(`/web on`) are supported. Known modern Claude models use adaptive thinking
and model-supported effort levels; legacy thinking budgets are added once to
the answer token allowance. With adaptive thinking, `agent.max_tokens` caps
the combined thinking and answer. New shells must export the key before launching nimlet.

`/doctor` shows the selected provider/model, endpoint (without credentials or
query parameters), config source paths, write target, and whether each key is
set. `/doctor test` makes a small request to the selected provider (normal API
usage applies), without adding it to session history or changing configuration.

`/model`, `/thinking`, and `/web` write immediately: to the project file if it
exists, otherwise to the global file (created if needed). `/model` sets
`default_provider` and `default_model`; `/thinking` sets `agent.thinking`;
`/web on` sets `agent.web_search` (hosted search on OpenAI, Anthropic, and Google).

Configuration example:

```json
{
  "default_provider": "openrouter",
  "default_model": "deepseek/deepseek-v4-flash-0731",
  "providers": {
    "openrouter": {
      "api_key_env": "OPENROUTER_API_KEY"
    },
    "openai": {
      "api_key_env": "OPENAI_API_KEY"
    },
    "anthropic": {
      "api_key_env": "ANTHROPIC_API_KEY"
    },
    "hyper": {
      "api_key_env": "HYPER_API_KEY"
    },
    "google": {
      "api_key_env": "AI_STUDIO_API_KEY"
    }
  },
  "agent": {
    "max_tokens": 4096,
    "request_timeout": 300,
    "web_search": false
  }
}
```

Provider blocks also accept an `options` object with native API request fields:

```json
{
  "providers": {
    "openrouter": {
      "options": {
        "provider": {"sort": "latency", "allow_fallbacks": false}
      }
    },
    "openai": {
      "options": {"parallel_tool_calls": false, "store": false}
    }
  }
}
```

Only the active provider's options are added to agent turn requests. Project
configuration recursively overlays global configuration; switching providers
selects that provider's options. Missing or `null` options mean no extra settings;
other values must be JSON objects. These are native fields, not the camelCase
fields of nimgent's typed Nim objects.

An explicit `agent.thinking` setting (including `/thinking none`) replaces
configured `reasoning`, `reasoning_effort`, and `thinking` blocks and the
`output_config.effort` field. With no thinking setting, configured reasoning passes
through unchanged. Other settings remain intact. `/thinking` and `/model` saves
preserve provider options. Connection probes and compaction keep their existing
request settings.

Run `./nimlet` from the workspace you want the agent to modify.

While a turn is running, you can type the next message and press Enter to
queue it. The composer stays editable until the current turn finishes; queued
text is not added to the model conversation until that point. Slash commands
cannot be queued. Escape or Ctrl-C interrupts the current turn without
discarding a queued message. Ctrl-U clears the composer and unqueues it.
Pass a prompt on the command line for a one-shot turn that exits when
done: `./nimlet fix the failing parser test`. Add `-i` /
`--interactive` to run that prompt and then keep the REPL open.
The interactive TUI is built with nimterm. Reads, searches, and workspace edits
run without prompts. Shell commands and extension tools ask on first use; press
`Enter` for once, `s` to allow the normalized command for the session, `p` to
save that grant for the project, or `n` to deny. Use `/permissions` to inspect
grants and `/permissions clear` to remove project grants.
Use `/yolo` or start with `--yolo` to auto-approve all tools for the current
process; `/yolo off` disables it. YOLO mode is never persisted.
Use `/session` to print the current session ID and `/resume` to list or
resume sessions. `/resume` lists this workspace (newest 20), with recency
and the first user message; `/resume ID` restores that transcript and
the last provider and requested model used, without changing your saved defaults.
Older sessions without provider metadata retain the currently selected provider.
A session from another project still loads by ID,
with a warning. Sessions without a workspace header are hidden from
workspace-filtered lists. `/model name` switches the model for later turns.
`./nimlet --resume` continues the latest session for this workspace.
A specific session can be selected with `./nimlet --session ID`.

Use `/plan` for read-only investigation and planning, and `/act` to enable
implementation. Shift+Tab toggles the same modes without changing your draft;
during a running turn it queues the switch for the next turn (press again to
cancel the queued switch). The footer shows `[plan]` or `[act]`.

Plan mode exposes only built-in `read`, `grep`, `glob`, and `read_skill` tools.
Edits, shell execution, extension tools, hosted search, and hooks are disabled,
and unadvertised tool calls are rejected at execution time. Session history
still saves, and explicit configuration commands still work. Modes apply to
the current process, including `/new` and `/resume`; restarting starts in act
mode. Planning is optional and does not require a separate plan file.

On resume, missing local tool results are recorded as interrupted with an unknown
execution outcome; completed results are preserved and tools are not automatically
rerun. A damaged JSONL tail is repaired on the next append, with the original file
preserved beside the session as `<session>.jsonl.recovery-<timestamp>`.

### Keyboard shortcuts

`/help` prints both the commands and this list in the TUI.

- `Enter` — submit; while a turn is running, queue the next message
- `Shift+Enter` / `Alt+Enter` — newline in the composer
- `Shift+Tab` — toggle plan / act mode
- `Esc` / `Ctrl-C` — clear the composer; interrupt a running turn
- `Ctrl-U` — clear the composer and unqueue
- `Ctrl-V` — paste text or a clipboard image
- `Tab` / `Up` / `Down` — accept / move through suggestions
- `Left`/`Right`, `Ctrl-B`/`Ctrl-F` — move the cursor by character
- `Alt-B` / `Alt-F` — move the cursor by word
- `Home`/`End`, `Ctrl-A`/`Ctrl-E` — jump to start / end of the line
- `Up`/`Down`, `Ctrl-P`/`Ctrl-N` — history (and composer line up/down)
- `Ctrl-O` — show or hide all tools
- `PgUp` / `PgDn` / mouse wheel — scroll the transcript

Type `/help` at any prompt to see these in the running app.

Project instructions are loaded from `~/.nimlet/AGENTS.md`, then from
`AGENTS.md` files between the repository root and the workspace. Passive
skills can be placed in `.nimlet/skills/<name>/SKILL.md`,
`.agent/skills/<name>/SKILL.md`, or `~/.nimlet/skills/<name>/SKILL.md`;
their metadata is advertised to the model and full bodies are loaded
only through the `read_skill` tool. Type `/<skill>` (optionally followed by
a request) to load a skill into the next turn. Built-in commands win when
names collide.

External tools are discovered the same way under `tools/` instead of
`skills/`: `~/.nimlet/tools/`, `<workspace>/.agent/tools/`, then
`<workspace>/.nimlet/tools/` (later roots override the same name). Each
child directory needs a `tool.json` and an executable; the agent reads
manifests at startup and only spawns the process when the model calls the
tool. Built-in tool names always win over extensions. Tools and hooks are
rescanned on `/reload`, `/new`, and `/resume` (as well as process start).
`/reload` keeps the current session; skills and `AGENTS.md` are already
read from disk on every turn.

Lifecycle hooks use the same discovery layout under `hooks/` with a
`hook.json` per child directory. Supported events: `pre_tool_call`,
`post_tool_call`, `session_start`, `session_end`, `pre_compact`,
`post_compact`, `turn_start`, `turn_end`. Hooks are ephemeral JSON
processes (stdin in, JSON out). Failures are fail-open (warn and
continue); only an explicit `{"allow": false}` from `pre_tool_call` or
`pre_compact` blocks. `pre_tool_call` may return rewritten `arguments`;
`post_tool_call` may return rewritten `output` / `is_error`;
`pre_compact` may return an extra `instruction`. Later roots override
the same hook `name`. Opening nimlet fires `session_start`; `/new` and
`/resume` fire `session_end` then `session_start`; clean exit fires
`session_end`. Each model turn fires `turn_start` / `turn_end`.
