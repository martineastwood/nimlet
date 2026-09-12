---
title: Configuration
description: Global and project settings, credentials, provider options, and /doctor.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

- `~/.nimlet/config.json` overlaid by `.nimlet/config.json` (project wins,
  recursively merged)
- Top-level keys: `default_provider`, `default_model`, `theme`, `keybindings`
- `keybindings.<action>` accepts one key string or an array; an empty array
  disables the default binding. Editor action IDs include
  `app.editor.external`, `tui.editor.undo`, `tui.editor.deleteWordBackward`,
  `tui.editor.deleteWordForward`, and `tui.editor.yank`.
- `providers.<name>.api_key`: `{env:NAME}`, `{file:path}`, or a literal key;
  relative paths resolve from the defining config file; `~` is supported
- `providers.<name>.last_model` and how `/model` / `/provider` persist it
- `providers.<name>.options`: native API request fields (not nimgent camelCase
  typed fields), sent only for the active provider
- `agent`: `max_tokens`, `request_timeout`, `thinking`, `web_search`,
  `compaction_enabled`, `reserve_tokens`, `keep_recent_tokens`,
  `context_window`, `session_dir`
- `tools.bash.max_output_bytes`
- `NIMLET_THINKING` environment override
- Write target rules: project file if it exists, otherwise global (created)
- `/doctor` and `/doctor test`
- Full annotated example config
