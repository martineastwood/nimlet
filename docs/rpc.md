# RPC mode

`nimlet --mode rpc` is a long-running JSON Lines process. Write one command per
line to stdin and read responses and agent events from stdout. Every record has
`"version":1`; stdout contains JSON only.

Each command requires string `id` and `type` fields. The response repeats `id`,
so clients can correlate it with the command.

```jsonl
{"id":"1","type":"prompt","message":"Inspect the failing tests"}
{"id":"2","type":"get_state"}
{"id":"3","type":"interrupt"}
{"id":"4","type":"shutdown"}
```

`prompt` starts an idle turn. While a turn is active it requires
`"streamingBehavior":"steer"` or `"streamingBehavior":"followUp"`; the
message is then queued in the matching queue. The explicit `steer` and
`follow_up` commands are equivalent. Steering messages are delivered after the
current assistant tool batch, while follow-up messages wait until the agent
would otherwise stop. Both queues accept multiple messages and default to
one-at-a-time delivery.

`clear_queue` returns and removes both queues. `interrupt` stops the active turn
and leaves queued messages in place. `shutdown` clears the queues, interrupts
the active turn, and exits after it stops. Closing stdin has the same effect as
shutdown. Queue events include `request_id`, `mode`, and the remaining `depth`.

`get_state` returns `session_id`, `mode`, `busy`, `queued`, `steering`,
`follow_up`, `steering_mode`, and `follow_up_mode`. Command responses
acknowledge acceptance; turn completion is reported by the normal `run_end`,
`error`, and message events rather than a second response.

Agent event records use the same version 1 contract as `--mode json`; see
[json.md](json.md). Diagnostics go to JSON stdout and process-startup messages
go to stderr.
