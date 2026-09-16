# RPC mode

`nimlet --mode rpc` is a long-running JSONL process. Write one command per line
to stdin and read responses and agent events from stdout. Every output record has
`"version": 1`; stdout contains JSON only. Startup failures and project trust
notices go to stderr.

Each command requires string `id` and `type` fields. The response repeats `id`,
so clients can correlate it with the command:

```jsonl
{"id":"1","type":"prompt","message":"Inspect the failing tests"}
{"version":1,"type":"response","id":"1","ok":true,"state":"started"}
```

`prompt` starts an idle turn. While a turn is active it requires
`"streamingBehavior":"steer"` or `"streamingBehavior":"followUp"`; the
message is then queued in the matching queue. The explicit `steer` and
`follow_up` commands queue the same two kinds of message, but return an error
while the agent is idle. Steering is delivered before a later model request;
follow-up messages wait until the current turn finishes.

Supported commands are:

| Type | Behavior |
| --- | --- |
| `prompt` | Start a turn, or queue it with `streamingBehavior` while busy |
| `steer` | Queue a steering message while busy |
| `follow_up` | Queue a follow-up message while busy |
| `get_state` | Return session, mode, active state, queue counts, and queue modes |
| `clear_queue` | Return and remove both queues |
| `set_steering_mode` | Set `all` or `one-at-a-time` and save it |
| `set_follow_up_mode` | Set `all` or `one-at-a-time` and save it |
| `interrupt` | Stop the active turn and keep queued messages |
| `shutdown` | Clear queues, stop the active turn, then exit |

Queue events include `request_id`, `mode`, and the remaining `depth`.
`clear_queue` returns `steering` and `follow_up` arrays. `get_state` returns
`session_id`, `mode`, `busy`, `queued`, `steering`, `follow_up`,
`steering_mode`, and `follow_up_mode`.

`get_state` returns `session_id`, `mode`, `busy`, `queued`, `steering`,
`follow_up`, `steering_mode`, and `follow_up_mode`. Command responses
acknowledge acceptance; turn completion is reported by the normal `run_end`,
`error`, and message events rather than a second response.

Command responses acknowledge acceptance; turn completion is reported by the
normal `run_end`, `error`, and message events rather than a second response.

Closing stdin and SIGINT behave like shutdown. Diagnostics go to JSON stdout.
Agent event records use the same version 1 contract as `--mode json`; see
[json.md](json.md).
