---
title: RPC mode
description: Drive nimlet as a long-running JSONL process.
---

RPC mode keeps nimlet running and lets your program submit prompts, steer an
active turn, inspect state, and shut the process down. It reads one JSON object
per stdin line and writes one JSON object per stdout line. Keep stdout connected
to your protocol parser. Startup failures and project trust notices use stderr.

```sh
nimlet --mode rpc
```

Each command requires a string `id` and string `type`. Every command receives a
correlated response:

```json
{"version":1,"type":"response","id":"1","ok":true,"state":"started"}
```

An invalid command returns `ok: false` with an `error`. Malformed JSON has an
empty response id.

## Commands

### Start and queue prompts

```json
{"id":"1","type":"prompt","message":"Inspect the parser tests"}
```

When idle, `prompt` returns `state: "started"` and begins the turn. When busy,
it must include `streamingBehavior: "steer"` or `"followUp"`:

```json
{"id":"2","type":"prompt","message":"Run the focused test too","streamingBehavior":"steer"}
```

The response then has `state: "queued"`, followed by a `queue` event with
`action: "enqueue"`, the `request_id`, `mode`, and total `depth`.

You can also use explicit queue commands while a turn is active:

```json
{"id":"3","type":"steer","message":"Prioritize the parser error"}
{"id":"4","type":"follow_up","message":"Then summarize the fix"}
```

`steer` and `follow_up` return an error while idle. Use `prompt` to start an
idle agent. A queued steering item is delivered before a later model request;
follow-up items are delivered after the current turn finishes. Steering is
chosen before follow-up when a new queued turn starts.

### Inspect and control the queues

```json
{"id":"5","type":"get_state"}
```

The response includes `session_id`, boolean `busy` and `queued`, counts named
`steering` and `follow_up`, the configured `steering_mode` and
`follow_up_mode`, and the current `mode`, either `act` or `plan`.

Plan and act mode are not RPC commands. `get_state` reports the current mode,
but there is no `set_mode` command. Switch modes from the interactive TUI with
`/plan`, `/act`, or `Shift+Tab`, or start RPC in the mode you need. RPC always
starts in act mode.

Queue delivery modes are independently configurable:

```json
{"id":"6","type":"set_steering_mode","mode":"all"}
{"id":"7","type":"set_follow_up_mode","mode":"one-at-a-time"}
```

Each mode is `all` or `one-at-a-time`. The setting is saved to the active config
as `agent.steering_mode` or `agent.follow_up_mode`.

Clear both queues and receive the removed prompts in the response:

```json
{"id":"8","type":"clear_queue"}
```

The response contains `steering` and `follow_up` arrays. If anything was
removed, a `queue` event with `action: "clear"` and `depth: 0` is also emitted.

### Interrupt and stop

```json
{"id":"9","type":"interrupt"}
```

`interrupt` cancels the active request and keeps queued messages. Its response
state is `interrupting` while a turn is still stopping, or `idle` when nothing
is active.

```json
{"id":"10","type":"shutdown"}
```

Shutdown clears queued messages, interrupts an active turn, and returns
`stopping` or `stopped`. EOF and SIGINT behave like shutdown. The process exits
after the active turn has stopped.

## Events and completion

The response acknowledges command acceptance only. Turn output arrives as the
version 1 event stream described in [JSON mode](/reference/json-mode/), including
`run_start`, streamed messages, tool events, `run_end`, and diagnostics. A
queued command does not receive a second response when its turn completes; use
the `request_id` on queue events and the event stream to correlate work.

RPC starts with `session_start` and ends with `session_end` after shutdown. The
final session record has `success: false` if any run produced an error.

## A small client loop

Send commands as newline-delimited JSON and read each output line independently:

```text
stdin:  {"id":"1","type":"prompt","message":"List the test commands"}
stdout: {"version":1,"type":"response","id":"1","ok":true,"state":"started"}
stdout: {"version":1,"type":"run_start",...}
stdout: {"version":1,"type":"message_delta",...}
stdout: {"version":1,"type":"run_end",...}
```

Do not send a CLI prompt after `--mode rpc`; commands belong on stdin. Use
`--no-session` when the RPC process should not read or write a session file.
