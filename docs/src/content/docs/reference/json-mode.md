---
title: JSON mode
description: The version 1 JSONL event contract.
---

:::caution[Placeholder]
This page is a stub. Content is planned but not written yet.
:::

## Planned content

Port of `nimlet/docs/json.md` once the page is written.

- When JSON mode is used (`--mode json`, one turn, piped stdin supported)
- Common record fields: `version`, `type`, `session_id`, `turn_id`, `run_id`
- Lifecycle types: `session_start`, `session_end`, `run_start`, `run_end`,
  `step_start`, `step_end`
- Message types: `message`, `message_delta`, `thinking_delta`
- Tool types: `tool_call`, `tool_output_delta`, `tool_result`,
  `approval_required`
- `error` and `diagnostic` records
- The reserved `queue` record and when it appears
- Payload field table and a full console example
- Exit status after errors
