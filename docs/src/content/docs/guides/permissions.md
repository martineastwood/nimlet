---
title: Permissions
description: Approval prompts, remembered grants, and YOLO mode.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

- What runs without asking: reads, searches, and workspace edits
- What asks on first use: shell commands and extension tools
- The approval prompt: `Enter` once, `s` for the session, `p` for the project,
  `n` to deny
- Grant keys: normalized command for `bash`, tool name otherwise
- Which commands cannot be remembered (the danger list)
- `/permissions` to inspect grants, `/permissions clear` to remove project grants
- Where project grants are stored (`.nimlet/permissions.json`)
- `/yolo` and `--yolo`: auto-approve everything for this process only, never
  persisted; `/yolo off`; the startup warning banner
- How plan mode and permissions interact
