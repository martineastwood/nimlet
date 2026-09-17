---
title: Files and directories
description: Every path nimlet reads or writes.
---

The following paths are relative to your home directory or the workspace where
you start nimlet. Missing optional files are normal.

## Global files

| Path | Use |
| --- | --- |
| `~/.nimlet/config.json` | Global configuration and the fallback write target |
| `~/.nimlet/auth.json` | Private provider credentials |
| `~/.nimlet/trust.json` | Trusted project roots |
| `~/.nimlet/AGENTS.md` | Global always-on instructions |
| `~/.nimlet/SYSTEM.md` | Global replacement system prompt, when applicable |
| `~/.nimlet/APPEND_SYSTEM.md` | Global system prompt additions |
| `~/.nimlet/history` | Up to 500 non-slash interactive inputs, stored as JSON strings |
| `~/.nimlet/models-dev.json` | Cached models.dev metadata |
| `~/.nimlet/sessions/` | Default session directory |
| `~/.nimlet/skills/` | Global skills |
| `~/.nimlet/prompts/` | Global prompt templates |
| `~/.nimlet/tools/` | Global one-call external tools |
| `~/.nimlet/extensions/` | Global persistent extensions |
| `~/.nimlet/themes/` | Global theme JSON files |

The portable roots `~/.agents/skills`, `~/.agents/prompts`, and
`~/.agents/extensions` are also searched. There is no `~/.agents/tools` root.

## Project files

| Path | Use |
| --- | --- |
| `.nimlet/config.json` | Project configuration overlay |
| `.nimlet/permissions.json` | Remembered project tool grants |
| `.nimlet/SYSTEM.md` | Trusted project replacement system prompt |
| `.nimlet/APPEND_SYSTEM.md` | Trusted project system prompt additions |
| `.nimlet/skills/` | Trusted project skills |
| `.agent/skills/`, `.agents/skills/` | Trusted project skills from compatible roots |
| `.nimlet/prompts/`, `.agent/prompts/`, `.agents/prompts/` | Trusted project prompt templates |
| `.nimlet/tools/`, `.agent/tools/` | Trusted project external tools |
| `.nimlet/extensions/`, `.agents/extensions/` | Trusted project persistent extensions |
| `.nimlet/themes/*.json` | Trusted project themes |
| `.nimlet/clips/` | Images copied here when you paste a path outside the workspace |

`AGENTS.override.md`, `AGENTS.md`, and `CLAUDE.md` are discovered from the
global nimlet directory and project directories up to the Git root. Project
instruction files are loaded without the project-resource trust prompt.

## Sessions and recovery files

The default session file is `<session_dir>/<session-id>.jsonl`. If the final
JSONL line is damaged, the next append preserves the original bytes as
`<session-id>.jsonl.recovery-<timestamp>` and repairs the readable prefix.
Deleting through `/session delete` moves the file to `<session_dir>/.trash/` so
`/session restore` can recover it.

## Discovery order

Later roots replace an earlier item with the same name for skills, prompt
templates, and one-call tools. The effective order is:

| Feature | Earlier to later |
| --- | --- |
| Skills | `~/.agents/skills`, `~/.nimlet/skills`, `.agent/skills`, `.agents/skills`, `.nimlet/skills` |
| Prompt templates | `~/.agents/prompts`, `~/.nimlet/prompts`, `.agent/prompts`, `.agents/prompts`, `.nimlet/prompts` |
| External tools | `~/.nimlet/tools`, `.agent/tools`, `.nimlet/tools` |
| Extensions | `~/.agents/extensions`, `~/.nimlet/extensions`, `.agents/extensions`, `.nimlet/extensions` |

All discovered extensions start together, so extension names do not override one
another. Project roots in these tables are considered only after trust is
granted.

## Configuration writes

Global and project config objects are merged recursively, with project values
winning. Arrays and scalar values replace earlier values. Settings changed by
`/model`, `/provider`, `/thinking`, `/web`, `/theme`, and `/settings` are written
to `.nimlet/config.json` when the project is trusted and its `.nimlet` directory
already exists. Otherwise nimlet writes `~/.nimlet/config.json`, creating its
parent directory as needed.

The configured `agent.session_dir` is expanded at startup: `~` means your home
directory, an absolute path is used as given, and a relative path is resolved
from the directory where nimlet was started.
