---
title: Sessions
description: Session ids, resume, fork, naming, and recovery.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

- What a session is: append-only JSONL transcript in `~/.nimlet/sessions`
- `/session` to print the id, `/new` to start one
- `/resume` to list this workspace's sessions (newest 20, recency, first user
  message) and `/resume ID` to restore one
- What resume restores: transcript plus the last provider and requested model,
  without changing saved defaults
- `./nimlet --resume` and `./nimlet --session ID`
- `/fork [message|ordinal]` to branch from a user message into a new session
- `/name [title]` and how names appear in lists
- Workspace filtering, cross-project loads with a warning, and sessions without
  a workspace header
- Interrupted tools on resume: recorded as unknown outcome, completed results
  preserved, nothing rerun automatically
- Damaged JSONL tails: repaired on next append, original kept as
  `<session>.jsonl.recovery-<timestamp>`
- `agent.session_dir` to relocate storage
