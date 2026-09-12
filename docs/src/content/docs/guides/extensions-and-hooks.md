---
title: Extensions and hooks
description: Persistent subprocesses that register tools, commands, and lifecycle hooks.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

- How extensions differ from external tools: long-lived, JSONL stdin/stdout,
  bidirectional
- Layout (`extensions/<name>/extension.json`) and discovery roots
  (`~/.agents/extensions`, `~/.nimlet/extensions`, `.agents/extensions`,
  `.nimlet/extensions`)
- Manifest fields: `name`, `command`, `response_timeout_seconds`
- Startup handshake: `initialize` → `register` (commands, tools, events)
- Registering tools: `name`, `description`, `input_schema`
- Registering commands, surfaced as slash commands with descriptions
- Extension-initiated actions: status lines, widgets, notifications, and
  durable session entries
- Hook events and payloads: `tool_call`, `tool_result`, `session_start`,
  `session_end`, `session_before_compact`, `session_compact`, `turn_start`,
  `turn_end`
- Hook outcomes: allow/deny with a reason, warnings, argument mutation, output
  and error overrides, compaction summary override
- Declaring only the events you need in `register`
- `/reload`, shutdown behavior, timeouts, and start-failure warnings
- Plan mode disables extension tools and hooks
- The root asymmetry table (tools vs extensions vs skills vs prompts)
- Minimal extension walkthrough
