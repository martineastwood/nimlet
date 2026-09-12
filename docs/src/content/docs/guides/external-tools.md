---
title: External tools
description: Register ephemeral executables as model tools with tool.json.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

- The idea: any executable in any language becomes a tool, with zero cost when
  unused (no process until invoked)
- Directory layout (`tools/<name>/tool.json` + the executable) and discovery
  roots (`~/.nimlet/tools`, `.agent/tools`, `.nimlet/tools`), later roots win
- Manifest fields: `name`, `description`, `command`, `timeout_seconds`,
  `input_schema`
- Calling protocol: JSON arguments on stdin, one JSON result on stdout,
  diagnostics on stderr, exit status
- Working directory and path resolution for `command`
- Timeouts, output truncation, and non-zero exits as tool failures
- Invalid manifests: warnings at startup, never a crash
- Name collisions with built-ins (`ask_user`, `bash`, `edit`, `glob`, `grep`,
  `read`, `read_skill`, `write`)
- `/reload` to rescan after adding or editing a tool
- Plan mode excludes extension tools
- Complete worked example (shell script and compiled binary)
