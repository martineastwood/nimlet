---
title: Built-in tools
description: The tools nimlet always ships, their schemas, and their safety rules.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

- The built-in set: `read`, `grep`, `glob`, `edit`, `write`, `bash`,
  `read_skill`, `ask_user`
- Per tool: input schema, result shape, limits, and failure modes
- `read`: line ranges (1-based), numbered output, version hash, image content
  for png/jpeg/gif/webp, truncation for large files
- `grep` / `glob`: regex vs glob semantics, optional glob filter and
  subdirectory scope
- `edit`: unique `old_text` → `new_text`, `replacements` for multiple hunks,
  `expected_version` conflict rejection, no fuzzy matching, `EDIT_FAILED`
  output the model can act on
- `write`: create vs replace, `overwrite = true`, atomic writes
- `bash`: stdout/stderr/exit code/duration, `timeout_seconds`, tail-preserving
  truncation, `max_output_bytes`, cancellation, process-group handling
- `read_skill`: loading a discovered skill by name
- `ask_user`: multiple choice plus free text, and its availability limits
  outside the interactive TUI
- Workspace boundary enforcement for every path-taking tool
- Why the tool list is deliberately small (shell already covers the rest)
