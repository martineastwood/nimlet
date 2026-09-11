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

`prompt` returns `state` as `started` or `queued`. One prompt may wait behind the
active turn; another is rejected until that slot clears. Queue events include
the prompt's `request_id`. `interrupt` stops the active turn but keeps its queued
successor. `shutdown` clears the queue, interrupts the active turn, and exits
after it stops. Closing stdin has the same effect as shutdown.

`get_state` returns `session_id`, `mode`, `busy`, and `queued`. Command responses
acknowledge acceptance; turn completion is reported by the normal `run_end`,
`error`, and message events rather than a second response.

Agent event records use the same version 1 contract as `--mode json`; see
[json.md](json.md). Diagnostics go to JSON stdout and process-startup messages
go to stderr.
