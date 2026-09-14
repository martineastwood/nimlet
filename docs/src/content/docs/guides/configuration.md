---
title: Configuration
description: Global and project settings, credentials, provider options, and /doctor.
---

nimlet reads two optional configuration files and one private credential file:

| File | Applies to |
| --- | --- |
| `~/.nimlet/config.json` | Everything you run |
| `<workspace>/.nimlet/config.json` | One project (only when the project is trusted) |
| `~/.nimlet/auth.json` | Provider credentials for your user |

There is no config command to run first: missing files are normal, and every
setting has a default. Many people never write more than a provider and a model.

## How the two files combine

Settings are merged key by key, and the project wins:

- Nested objects merge. A project that sets
  `providers.anthropic.options.parallel_tool_calls` keeps every other global
  option for that provider.
- Arrays and single values replace. A `keybindings` entry in the project replaces
  the global entry of the same name.

Startup flags are a third layer, for one process only: `--provider`, `--model`,
`--thinking`, `--api-key`, and `--tools` override configuration and credentials
and are never written back.

A minimal global config:

```json title="~/.nimlet/config.json"
{
  "default_provider": "anthropic",
  "default_model": "claude-sonnet-4-6"
}
```

## Credentials

Credentials live in `~/.nimlet/auth.json`, outside project configuration:

```json title="~/.nimlet/auth.json"
{
  "anthropic": { "type": "api_key", "key": "sk-ant-..." },
  "openai": { "type": "api_key", "key": "sk-..." }
}
```

The entry is keyed by provider and uses `type: "api_key"`. If an entry is absent,
the per-provider environment variable is used instead:
`AI_STUDIO_API_KEY`, `ANTHROPIC_API_KEY`, `HYPER_API_KEY`, `MISTRAL_API_KEY`,
`OPENCODE_API_KEY`, `OPENAI_API_KEY`, or `OPENROUTER_API_KEY`. Exporting the
variable is enough; no configuration needed.

`--api-key` is an in-memory override for one process. `/doctor` reports whether
the credential comes from `auth.json` or the environment, never the value.

## Provider settings

Everything under `providers.<name>`, where `<name>` is `anthropic`, `codex`,
`google`, `hyper`, `mistral`, `openai`, `opencode`, `opencodezen`, or `openrouter`:

| Key | Purpose |
| --- | --- |
| `endpoint` | Override the base URL, for a proxy or gateway |
| `site_url`, `site_name` | Attribution headers, for providers that want them |
| `options` | Native API request fields, merged into each request |
| `last_model` | Written by `/model` when you switch models |

`options` are passed through as-is, so they are the provider's own field names,
not nimlet's:

```json title=".nimlet/config.json"
{
  "providers": {
    "openrouter": {
      "options": { "provider": { "sort": "latency", "allow_fallbacks": false } }
    },
    "openai": {
      "options": { "parallel_tool_calls": false, "store": false }
    }
  }
}
```

Only the active provider's options are sent. A missing or `null` value means
nothing extra, and anything else has to be a JSON object — a string or an array
makes the request fail with `options must be a JSON object`.

One interaction worth knowing: if you set `agent.thinking`, it replaces any
`reasoning`, `reasoning_effort`, or `thinking` block and `output_config.effort`
in your provider options, because two sources of truth for reasoning would
conflict. Everything else in `options` is left alone.

## Agent settings

All of these live under `agent`:

| Key | Default | Meaning |
| --- | --- | --- |
| `max_tokens` | `4096` | Cap on the answer. With adaptive thinking, thinking counts toward it |
| `request_timeout` | `300` | Seconds to wait for a provider response |
| `thinking` | unset | Reasoning level: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`. Which ones do something depends on the model |
| `web_search` | `false` | Hosted web search, on providers that support it |
| `context_window` | `0` | Override the model's context window. `0` means resolve it from the catalog, then from a per-family estimate |
| `compaction_enabled` | `true` | Automatic compaction |
| `reserve_tokens` | `16384` | Headroom kept when deciding whether to compact |
| `keep_recent_tokens` | `20000` | Recent history kept verbatim when compacting |
| `session_dir` | `~/.nimlet/sessions` | Where sessions are written. `~` expands; a relative path resolves from the directory you started nimlet in |
| `steering_mode` | `one-at-a-time` | How queued steering messages are delivered (`one-at-a-time` or `all`) |
| `follow_up_mode` | `one-at-a-time` | The same for follow-ups |
| `tools.bash.max_output_bytes` | `100000` | Truncation limit for shell output |

Two notes:

- `thinking` and the queue modes are validated, and only accept the values listed.
- `NIMLET_THINKING` overrides `agent.thinking` for a run, which is handy for a
  one-off `NIMLET_THINKING=high ./nimlet …`.

## Theme and keybindings

```json title=".nimlet/config.json"
{
  "theme": "auto",
  "keybindings": {
    "app.editor.external": "ctrl+e",
    "tui.editor.undo": []
  }
}
```

`theme` is a theme name or `auto`, which follows the terminal's background. An
empty array in `keybindings` disables that action's default binding. The action
names and the full default table are in
[Keyboard shortcuts](/reference/keybindings/).

## Value types, and keys nimlet does not know

Values are read leniently:

- numbers may be numbers or numeric strings (`"max_tokens": "8192"` works)
- booleans accept `true`/`false`, `0`/`1`, and the strings `"off"`, `"no"`,
  `"false"` (and their opposites)
- unknown keys are ignored on load, and preserved when nimlet rewrites the file

That last point cuts both ways: nothing is destroyed, but a typo in a key name is
silently a no-op. If a setting seems to have no effect, check the spelling, then
check `/doctor` to confirm which files were read.

## What nimlet writes, and where

Five commands save settings immediately:

| Command | Keys written |
| --- | --- |
| `/model` | `default_model`, and `providers.<active>.last_model` |
| `/provider` | `default_provider` |
| `/thinking` | `agent.thinking` (removed when you clear it) |
| `/web on` / `/web off` | `agent.web_search` (removed when off) |
| `/theme` | `theme` |
| `/settings` → Queue | `agent.steering_mode`, `agent.follow_up_mode` |

The file they patch is the *write target*:

- the project config (`.nimlet/config.json`) when the project is trusted and it
  already has a `.nimlet` directory
- otherwise the global config, created if needed

Saves patch values in place and rewrite the file pretty-printed, so it is a normal
file to edit, diff, or commit afterwards.

## Checking what is in effect

```text
/doctor
```

```text
Provider: anthropic
Model: claude-sonnet-4-6
Endpoint: https://api.anthropic.com/v1/messages
Config sources (later overrides earlier):
  /Users/you/.nimlet/config.json (exists)
  /Users/you/code/project/.nimlet/config.json (absent)
Config write target: /Users/you/.nimlet/config.json
Auth file: /Users/you/.nimlet/auth.json (exists)
anthropic: env ANTHROPIC_API_KEY set
google: env AI_STUDIO_API_KEY missing
hyper: env HYPER_API_KEY missing
openai: env OPENAI_API_KEY missing
opencode: env OPENCODE_API_KEY set
opencodezen: env OPENCODE_API_KEY set
openrouter: env OPENROUTER_API_KEY missing
Use /doctor test for a small API request to the selected provider.
```

The endpoint is printed without credentials or query parameters. `/doctor test`
makes one small request and reports success or failure — useful when a key, an
endpoint, or a model id is the suspect.

## A complete example

```json title="~/.nimlet/config.json"
{
  "default_provider": "openrouter",
  "default_model": "deepseek/deepseek-v4-flash-0731",
  "theme": "auto",
  "providers": {
    "openrouter": {
      "options": { "provider": { "sort": "latency" } }
    }
  },
  "agent": {
    "max_tokens": 8192,
    "request_timeout": 300,
    "thinking": "medium",
    "web_search": false,
    "context_window": 0,
    "compaction_enabled": true,
    "reserve_tokens": 16384,
    "keep_recent_tokens": 20000,
    "steering_mode": "one-at-a-time",
    "follow_up_mode": "one-at-a-time",
    "session_dir": "~/.nimlet/sessions"
  },
  "tools": {
    "bash": { "max_output_bytes": 100000 }
  },
  "keybindings": {
    "app.editor.external": "ctrl+g"
  }
}
```

## Related environment variables

| Variable | Effect |
| --- | --- |
| `AI_STUDIO_API_KEY`, `ANTHROPIC_API_KEY`, `HYPER_API_KEY`, `MISTRAL_API_KEY`, `OPENCODE_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY` | Credentials when no auth entry is present |
| `NIMLET_THINKING` | Overrides `agent.thinking` for this run |
| `NIMLET_SHELL` | Forces the shell used by `bash` and shell shortcuts (`bash`, `pwsh`, `cmd.exe`, or a POSIX-compatible path) |
| `VISUAL`, `EDITOR` | The editor `Ctrl-G` opens the composer in: `VISUAL` first, then `EDITOR`, falling back to `nano` |

## Where to go next

- [Models and providers](/guides/models-and-providers/) for switching, thinking
  levels, and hosted search
- [Keyboard shortcuts](/reference/keybindings/) for the rebindable action names
- [Files and directories](/reference/files-and-directories/) for every file nimlet
  reads and writes
- [Security](/guides/security/) for how trust gates the project config
