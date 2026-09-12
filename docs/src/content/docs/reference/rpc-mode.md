---
title: RPC mode
description: Drive nimlet as a long-running JSONL process.
---

`nimlet --mode rpc` accepts multiple queued messages in separate steering and
follow-up queues. See `nimlet/docs/rpc.md` in the repository for the full wire
contract.

- `nimlet --mode rpc`: one command per stdin line, JSON only on stdout
- Commands: `prompt`, `steer`, `follow_up`, `clear_queue`, `interrupt`,
  `get_state`, `shutdown`
- Required `id` and `type` fields, and response correlation
- Prompt acceptance (`started` vs `queued`) and explicit delivery modes
- Queue events carrying `request_id`, `mode`, and remaining `depth`
- `interrupt` keeping queued messages; `clear_queue` returning both queues
- EOF behaving like shutdown
- `get_state` payload: `session_id`, `mode`, `busy`, `queued`, `steering`,
  `follow_up`, `steering_mode`, `follow_up_mode`
- Why turn completion arrives as events rather than a second response
- Where diagnostics and startup messages are written
