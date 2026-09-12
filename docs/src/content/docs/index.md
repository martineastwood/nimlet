---
title: nimlet
description: A minimal native coding agent written in Nim.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

nimlet is a minimal native coding agent and an end-to-end example of the
Niminal stack. It uses nimgent for models and agent behavior, and nimterm for
its terminal interface.

[View nimlet on GitHub](https://github.com/martineastwood/nimlet)

## Planned content

- What nimlet is, and who it is for
- The design constraints that shape it: near-zero idle CPU, event-driven TUI,
  prompt-cache-first request prefix, append-only sessions
- Relationship to the sibling packages (`nimgent`, `nimterm`) and local
  development resolution
- Build and test (`nimble build`, `nimble test`, `nimble idleSmoke`)
- Platform support (macOS/Linux; Windows via WSL)
- Where to go next: quickstart, configuration, interactive use, extending it,
  and the reference contracts
