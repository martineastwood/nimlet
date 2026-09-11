# JSON mode

`nimlet --mode json "prompt"` runs one turn and writes JSON Lines to stdout.
Piped stdin is supported in the same way as print mode. Diagnostics remain
machine-readable; process exit status is non-zero after an error.

Every record contains:

- `version`: schema version, currently `1`
- `type`: event type
- `session_id`, `turn_id`, and `run_id` when relevant

Event payloads:

| Type | Additional fields |
| --- | --- |
| `session_start` | — |
| `session_end` | `success` |
| `message` | `role`, `content`, optional `model`, and `final` for assistants |
| `run_start` | `prompt` |
| `run_end` | optional `model` |
| `step_start`, `step_end` | `step`, optional `model` |
| `message_delta`, `thinking_delta` | `step`, `delta`, optional `model` |
| `tool_call` | `step`, `tool_id`, `tool_name`, optional `input` |
| `tool_output_delta` | `step`, `tool_id`, `tool_name`, `delta` |
| `tool_result` | `step`, `tool_id`, `tool_name`, `output`, `is_error` |
| `approval_required` | tool-call fields plus `can_remember` |
| `error` | `step`, `message` |
| `diagnostic` | `level`, `message` |
| `queue` | `action`, `depth`, optional `content` |

Queue records are part of version 1 for interactive/RPC producers;
one-shot JSON mode does not create a queue.

Example:

```console
$ printf 'Explain this code' | nimlet --mode json
{"version":1,"type":"session_start","session_id":"..."}
{"version":1,"type":"message","role":"user","content":"Explain this code",...}
...
{"version":1,"type":"session_end","session_id":"...","success":true}
```
