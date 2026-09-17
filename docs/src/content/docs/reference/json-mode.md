---
title: JSON mode
description: The version 1 JSONL event contract.
---

JSON mode runs one turn and writes a machine-readable JSON object on each stdout
line. Use it when your program needs streaming text, thinking, tool activity,
and the final result without parsing terminal output.

```sh
nimlet --mode json "Find the failing parser test and explain it"
```

Piped stdin is supported. It is placed before the optional command-line prompt:

```sh
git diff | nimlet --mode json "Review these changes"
```

Every record has `"version": 1` and a `type`. Session and turn identifiers are
included when they exist. Startup failures and project trust notices are
written to stderr. The process exits with status 1 when the turn fails and 0 on
success. Invalid CLI usage exits with status 2.

## Useful flags

JSON mode shares the same startup flags as other non-interactive runs. Common
combinations:

```sh
nimlet --mode json --no-session "Summarize this repo"
nimlet --mode json --tools read,grep "Where is the parser defined?"
nimlet --mode json --provider anthropic --model claude-sonnet-4-6 "Hello"
```

There is no approval UI in JSON mode, so tools run without prompting. Use
`--tools` to narrow what is available, and `--no-session` when you do not want
the transcript written to disk. The `approval_required` event is emitted only by
the interactive TUI.

## Record order

A session run normally starts and ends like this:

```jsonl
{"version":1,"type":"session_start","session_id":"..."}
{"version":1,"type":"run_start","session_id":"...","turn_id":"...","run_id":"...","prompt":"..."}
{"version":1,"type":"step_start","session_id":"...","turn_id":"...","run_id":"...","step":0,"model":"..."}
{"version":1,"type":"message_delta","session_id":"...","turn_id":"...","run_id":"...","step":0,"delta":"...","model":"..."}
{"version":1,"type":"step_end","session_id":"...","turn_id":"...","run_id":"...","step":0,"model":"..."}
{"version":1,"type":"run_end","session_id":"...","turn_id":"...","run_id":"...","model":"..."}
{"version":1,"type":"session_end","session_id":"...","success":true}
```

Tool calls and additional steps appear between the lifecycle records. A final
assistant `message` record is emitted after streamed text. A user `message`
record is emitted for the prompt. Runtimes that deliver queued messages can
emit additional user records for those messages.

## Event records

| `type` | Payload |
| --- | --- |
| `session_start` | `session_id` |
| `session_end` | `session_id`, `success` |
| `run_start` | `prompt` when non-empty |
| `step_start`, `step_end` | `step`, optional `model`, and optional `duration_ms` |
| `message_delta`, `thinking_delta` | `step`, `delta`, optional `model` |
| `tool_call` | `step`, `tool_id`, `tool_name`, optional `input` |
| `approval_required` | The tool-call fields plus `can_remember` |
| `tool_output_delta` | `step`, `tool_id`, `tool_name`, `delta` |
| `tool_result` | `step`, `tool_id`, `tool_name`, `output`, `is_error` |
| `run_end` | optional `model` |
| `error` | `step`, `message` |

Run records also include `run_id` when available. Run and step records include
`session_id` and `turn_id` when available. `duration_ms` is omitted when it is
zero. The `message` shape is:

```json
{"version":1,"type":"message","role":"assistant","content":"Done","session_id":"...","turn_id":"...","model":"...","final":true}
```

`role` is `user` or `assistant`. Assistant messages include `final`; a false
value identifies an intermediate streamed commit.

## Diagnostics and queues

Warnings and errors that are not already represented by an `error` event use:

```json
{"version":1,"type":"diagnostic","level":"warning","message":"..."}
```

The `level` is `warning` or `error`. JSON mode itself does not accept commands
or create a queue. The reserved queue record is used by runtimes that support
queued messages, including RPC mode:

```json
{"version":1,"type":"queue","session_id":"...","action":"enqueue","content":"Run the tests","request_id":"...","mode":"steer","depth":1}
```

Queue records can have `action` `enqueue`, `dequeue`, or `clear`. `mode` is
`steer` or `follow_up` when relevant. `content` and `request_id` are omitted
when empty. Use [RPC mode](/reference/rpc-mode/) when your program needs to
submit queued work.

## Handling a stream

Append `message_delta.delta` values for live assistant text and handle
`thinking_delta` separately if you display reasoning. Use `tool_call` to show
the requested operation, `tool_output_delta` for live shell output, and
`tool_result.is_error` to distinguish failed calls. Treat `run_end` as the end
of the turn, then use `session_end.success` and the process exit status for the
overall result.

Do not parse human-readable console banners in JSON mode. Keep stdout reserved
for JSONL and send your own logs to stderr.
