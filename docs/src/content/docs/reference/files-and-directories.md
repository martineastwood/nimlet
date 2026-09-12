---
title: Files and directories
description: Every path nimlet reads or writes.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

One table, generated from config/plugin-root code so it cannot drift.

- Global: `~/.nimlet/config.json`, `AGENTS.md`, `skills/`, `prompts/`,
  `tools/`, `extensions/`, `themes/`, `sessions/`, `models-dev.json`, `clips/`
- Portable/global agent roots: `~/.agents/skills`, `~/.agents/prompts`,
  `~/.agents/extensions`
- Project: `.nimlet/config.json`, `AGENTS.md`, `permissions.json`, `skills/`,
  `prompts/`, `tools/`, `extensions/`, `themes/`, and `.agent/` equivalents
- Session files: `<session>.jsonl` and `.recovery-<timestamp>` sidecars
- Extension entry storage inside the session transcript
- Discovery precedence for each plugin kind, including the asymmetry between
  roots (`tools` vs `extensions` vs `skills` vs `prompts`)
- Config merge and write-target rules
- Which paths are created on demand, and which require the directory to exist
