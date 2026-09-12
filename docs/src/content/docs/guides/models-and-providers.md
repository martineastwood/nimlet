---
title: Models and providers
description: Switching provider and model, thinking levels, and hosted web search.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

- Wired providers: openrouter, openai, anthropic, hyper, google
- `/provider [name]` and per-provider last-model memory
- `/model [name]` with completion from the cached catalog (recents first)
- `/models refresh` and the cached `~/.nimlet/models-dev.json` metadata, plus
  the startup refresh note
- Where choices persist, and why (project config if present, else global)
- `/thinking <level>`: the ladder (`none` … `max`), model-specific snapping,
  per-model menus, and what an explicit setting replaces
- `/web on|off` for hosted search, and which providers support it
- Anthropic specifics: adaptive thinking, effort levels, legacy budgets, and
  `max_tokens` as the combined cap
- No thinking setting means configured reasoning passes through unchanged
- `/doctor` for endpoint and key status
