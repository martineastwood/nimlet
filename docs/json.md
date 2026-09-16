# JSON mode

`nimlet --mode json "prompt"` runs one turn and writes one JSON object per line
to stdout. Use it when another program needs streamed assistant text, thinking,
tool activity, and a final result without parsing terminal output.

Piped stdin is placed before the optional command-line prompt:

```console
$ printf 'Explain this code' | nimlet --mode json
{"version":1,"type":"session_start","session_id":"..."}
{"version":1,"type":"run_start","session_id":"...","turn_id":"...","run_id":"...","prompt":"Explain this code"}
...
{"version":1,"type":"session_end","session_id":"...","success":true}
```

Every record has `version: 1` and a `type`. Session and turn identifiers are
included when available. Startup failures and project trust notices go to
stderr. Exit status is 0 for success, 1 for a failed turn, and 2 for invalid
CLI usage.

Event payloads:

| Type | Additional fields |
| --- | --- |
| `session_start` | `session_id` |
| `session_end` | `success` |
| `message` | `role`, `content`, optional `model`, and `final` for assistants |
| `run_start` | `prompt` |
| `run_end` | optional `model` |
| `step_start`, `step_end` | `step`, optional `model`, and optional `duration_ms` |
| `message_delta`, `thinking_delta` | `step`, `delta`, optional `model` |
| `tool_call` | `step`, `tool_id`, `tool_name`, optional `input` |
| `tool_output_delta` | `step`, `tool_id`, `tool_name`, `delta` |
| `tool_result` | `step`, `tool_id`, `tool_name`, `output`, `is_error` |
| `approval_required` | tool-call fields plus `can_remember` |
| `error` | `step`, `message` |
| `diagnostic` | `level`, `message` |
| `queue` | `action`, `depth`, optional `content`, `request_id`, and `mode` |

`run_id` is included on run and step records when available. `session_id` and
`turn_id` are included on run records when available. Assistant `message`
records include a `final` boolean; user message records include `role` and
`content` but not `final`.

Queue records are reserved for runtimes that support queued messages, including
RPC mode. One-shot JSON mode does not create a queue. Queue actions are
`enqueue`, `dequeue`, and `clear`; `mode` is `steer` or `follow_up` when
applicable.

Warnings and errors that are not already represented by an `error` event use a
`diagnostic` record with `level` `warning` or `error`. Keep stdout reserved for
JSONL and send your own logs to stderr.
