---
title: Skills
description: Passive Markdown capabilities the model loads only when needed.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

- What a skill is: a `SKILL.md` of instructions, never executable
- Directory layout (`skills/<name>/SKILL.md`) and discovery roots
  (`~/.agents/skills`, `~/.nimlet/skills`, `.agent/skills`, `.agents/skills`,
  `.nimlet/skills`), with later roots overriding by name
- Frontmatter: `name`, `description`; first non-heading line as fallback
- Startup cost: only metadata is injected, so unused skills are free
- `read_skill` as the lazy-load path, and how the model decides
- Explicit invocation with `/skill:<name>` and appended arguments
- Size cap and truncation behavior
- Writing a good description
