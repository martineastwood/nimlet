---
title: Prompt templates
description: File-backed prompts that become slash commands.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

- The filename is the slash command name (`review.md` → `/review`)
- Discovery roots (`~/.agents/prompts`, `~/.nimlet/prompts`, `.agent/prompts`,
  `.agents/prompts`, `.nimlet/prompts`) and later-root override
- Frontmatter `description` for completions; first body line as fallback
- Argument substitution: `$ARGUMENTS` and `$@`
- Non-recursive discovery, `.md` only, size cap
- Built-in command names are reserved ahead of prompts
- Worked example: a `/review` template and how `Argument` text flows through
