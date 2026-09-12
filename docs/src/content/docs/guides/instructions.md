---
title: Instructions
description: Project and global AGENTS.md guidance for the agent.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

- `AGENTS.md` files as standing guidance in the stable prompt prefix
- Discovery: global `~/.nimlet/AGENTS.md`, then `AGENTS.md` from the repository
  root down to the workspace
- Ordering rule: less-specific files first, more-specific files later
- The walk stops at the git root (`.git` file or directory)
- How files are labeled in the prompt (`global`, or a workspace-relative path)
- Size handling and truncation (`MaxInstructionBytes`)
- Practical guidance: keep instructions short, deterministic, and free of
  volatile data (for prompt-cache reuse)
- Nested monorepo layout example
