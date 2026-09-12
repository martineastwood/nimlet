---
title: Context and compaction
description: Keeping long sessions alive without losing recent verbatim history.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

- The problem: long sessions outgrow the model context window
- Auto-compaction trigger: estimated context above `context_window -
  reserve_tokens`
- What is kept verbatim and what becomes a summary
- `/compact` and `/compact <instruction>` for manual compaction
- Structured summary contents (goal, decisions, files touched, commands,
  failures, outstanding work, next steps)
- Raw history is never destroyed — compaction only changes what is sent
- Context window resolution: explicit `context_window`, then model catalog,
  then per-model guess
- Disabling compaction (`compaction_enabled`) and tuning `reserve_tokens` /
  `keep_recent_tokens`
- Overflow recovery: compact, rebuild the request, retry once
- Extension hooks `session_before_compact` / `session_compact`
