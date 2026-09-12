---
title: Architecture
description: The constraints nimlet is built around.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

Distilled from `SCOPE.md`, the design document behind the project.

- The guiding rule: nothing happens unless the user, model, subprocess, or OS
  generates an event
- Idle is blocking I/O; active is proportional to real work — no polling, no
  timers, no fixed-frequency render loops, no background threads
- Lazy cost: features not in use consume effectively zero CPU and no processes
- Prompt-cache design: stable prefix ordering (system, tools, instructions,
  skill metadata, compaction summary, history, latest content), deterministic
  tool ordering, no volatile data early
- Agent loop shape: read input, append, build request, stream, run tools,
  repeat — no hidden scheduler
- Append-only JSONL sessions and why they were chosen
- Unix-style extension boundary (subprocess, JSON on stdin/stdout)
- Explicit non-goals: repository indexing, LSP, MCP, subagents, watchers,
  embedded scripting runtimes, daemons
- Resource regression stance: performance regressions are bugs
  (`nimble idleSmoke`, `NIMTERM_PERF=1`)
- How to measure it yourself
