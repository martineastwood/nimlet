---
title: Extensions and hooks
description: Persistent subprocesses that register tools, commands, and lifecycle hooks.
---

An extension is a program nimlet starts and keeps running while it is open,
talking over JSON lines on stdin and stdout. Any language works. While it runs, an
extension can register tools the model can call, slash commands you can type, and
lifecycle hooks that run before or after tool calls, turns, sessions, and
compaction.

The difference from a `tool.json` tool: a tool is spawned per call with one JSON
argument and one JSON result, then exits. An extension is a conversation - it
starts once, gets told about events, and can push updates whenever it likes.

## Layout and discovery

```text
~/.agents/extensions/hello/extension.json     portable, shared with other agents
~/.nimlet/extensions/hello/extension.json     yours
<workspace>/.agents/extensions/hello/extension.json   project (needs trust)
<workspace>/.nimlet/extensions/hello/extension.json
```

Every directory containing an `extension.json` is started. Two differences from
skills and prompt templates are worth remembering:

- Extensions are **not** overridden by name. Two extensions with the same name
  both run; if both register a tool with the same tool name, the last one loaded
  wins silently.
- There is no `.agent/extensions` root. The project roots here are `.agents` and
  `.nimlet`, even though skills and `tool.json` tools also read `.agent`.

The project roots are only searched when you have trusted the project.

## The manifest

```json title=".nimlet/extensions/notes/extension.json"
{
  "name": "notes",
  "command": ["./extension.py"],
  "response_timeout_seconds": 30
}
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `name` | string | yes | Used in warnings and as the namespace for status, widget, and entry keys |
| `command` | string array | yes | Program and arguments. Non-empty. The first element is resolved against the extension folder when it contains `/` |
| `response_timeout_seconds` | integer or `null` | no | Seconds nimlet waits for a reply. Default `30`. `null` means no timeout. Time spent waiting for a user question does not count |

The process starts with your workspace as its working directory.

On POSIX, make scripts executable with a shebang and use `"command": ["./extension.py"]`.
On Windows, `.sh`, `.ps1`, `.cmd`, `.bat`, and `.py` files are launched through the
matching interpreter (`py` or `python` for `.py`), so the same manifest works on both
platforms.

A manifest that does not parse, or is missing `name` or `command`, is skipped
with a startup warning such as `skipping /path: missing name`. Nothing crashes.

## Transport and handshake

**Rules:**

- One JSON object per line on stdin and stdout. No other stdout output.
- Nimlet writes requests to your stdin. You write replies to stdout.
- Every request has an `id` string. Every `response` must echo the same `id`.
- Replies may arrive in any order; ids are how nimlet matches them.
- Several requests can be in flight at once.
- Stderr is not read. Write logs to a file.

**Startup sequence:**

1. Nimlet starts your process with the workspace as the working directory.
2. Nimlet writes `initialize` to your stdin (no reply expected).
3. You write `register` to stdout. Nimlet waits for this line before continuing.
4. Nimlet may send `tool`, `command`, `event`, `cancel`, or `shutdown` requests.
5. You may send `response`, `update`, or `ui_request` lines at any time.

Most extensions print `register` immediately at startup, then enter a read loop.

### `initialize` (nimlet → extension)

Sent once when the extension starts. No reply.

```json
{
  "type": "initialize",
  "version": 1,
  "workspace": "/home/you/code/project",
  "session_id": "1789233281025102"
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `type` | `"initialize"` | |
| `version` | `1` | Protocol version |
| `workspace` | string | Absolute path to the workspace |
| `session_id` | string | Current session id |

On `/reload`, `/new`, `/resume`, or a trust change, extensions restart and you
receive a fresh `initialize` with the current session id.

### `register` (extension → nimlet)

Your first stdout line. Nimlet blocks until it arrives or times out.

```json
{
  "type": "register",
  "commands": [
    {"name": "note", "description": "Append a note to NOTES.md"}
  ],
  "tools": [
    {
      "name": "save_note",
      "description": "Save a note about the current work.",
      "input_schema": {
        "type": "object",
        "properties": {"text": {"type": "string"}},
        "required": ["text"]
      },
      "capabilities": ["read"]
    }
  ],
  "events": ["tool_call", "tool_result"]
}
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `type` | `"register"` | yes | |
| `commands` | array | yes | May be empty. Slash commands you expose |
| `tools` | array | no | Model-callable tools. Omit when you have none |
| `events` | array of strings | no | Lifecycle hook names to subscribe to. Omit when you have none |

**`commands[]` entries:**

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `name` | string | yes | Becomes `/name` in the composer (case-insensitive) |
| `description` | string | no | Shown in tab completion |

**`tools[]` entries:**

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `name` | string | yes | Tool name the model sees. Must not collide with a built-in |
| `description` | string | yes | |
| `input_schema` | object | yes | JSON Schema object for the tool arguments |
| `capabilities` | string array | no | See [Tool capabilities](#tool-capabilities). Omitting means `write`, `shell`, and `network` |

**`events[]` values:** one of the nine hook names in [Lifecycle events](#lifecycle-events).

Registration is validated strictly. Invalid `register` lines fail startup with a
warning and the process is stopped.

## Messages from nimlet

### `tool`

The model called one of your registered tools.

```json
{
  "type": "tool",
  "id": "7",
  "name": "save_note",
  "arguments": {"text": "remember the cache bug"}
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `type` | `"tool"` | |
| `id` | string | Reply id |
| `name` | string | Tool name from your `register` |
| `arguments` | object | Tool arguments from the model. `{}` when empty |

Reply with a `content` array and optional `is_error` (boolean, default `false`).
Content parts are `{"type":"text","text":"..."}` or images with `mimeType`
and either `path` or `data`. String content is not accepted.

While the tool runs, send progress into the active tool display:

```json
{"type":"tool_update","id":"7","content":"Downloaded 40 of 100 files"}
```

### `command`

You typed a registered slash command.

```json
{
  "type": "command",
  "id": "3",
  "name": "note",
  "arguments": "remember the cache bug",
  "context": {
    "mode": "tui",
    "workspace": "/home/you/code/project",
    "session_id": "1789233281025102",
    "provider": "anthropic",
    "model": "claude-sonnet-4-6",
    "messages": []
  }
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `type` | `"command"` | |
| `id` | string | Reply id |
| `name` | string | Command name from your `register` |
| `arguments` | string | Plain text after the command. Empty string when you typed `/note` alone |
| `context` | object | Current workspace, session, model selection, and effective model messages |

`context.messages` contains the conversation nimlet would send to the model. If
the session was compacted, it starts with the latest summary and includes the
kept messages after it.

Reply fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `message` | string | Printed in the transcript |
| `prompt` | string | If set, becomes the next user message and starts a turn |
| `session` | object | Runs a session action after your command returns |
| `reload` | boolean | Reloads project resources after your command returns |

`message` and `prompt` can appear together: nimlet prints the message, then runs
the prompt.

Session actions run after nimlet receives your response, so the extension can
finish its command before a switch restarts extension processes:

```json
{
  "type": "response",
  "id": "3",
  "session": {
    "action": "new",
    "editor_text": "Review this handoff, then submit it."
  }
}
```

Supported actions are `new`, `fork`, `switch`, and `compact`. `fork` takes a
one-based `message` number, `switch` takes a session `id`, and `compact` accepts
an optional `instruction`. `editor_text` applies after `new`, `fork`, or
`switch` without submitting the text.

### `event`

A lifecycle hook you subscribed to in `register.events`.

```json
{
  "type": "event",
  "id": "9",
  "event": "tool_call",
  "payload": {
    "tool": "bash",
    "arguments": {"command": "npm test"}
  }
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `type` | `"event"` | |
| `id` | string | Reply id |
| `event` | string | Hook name |
| `payload` | object | Event-specific fields. See [Lifecycle events](#lifecycle-events) |

You must reply to every `event`, even when you have nothing to change. An empty
acknowledgement is enough:

```json
{"type": "response", "id": "9"}
```

### `cancel`

Sent when the user interrupts while nimlet is waiting for your reply to another
request. No reply needed.

```json
{"type": "cancel", "id": "7"}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `type` | `"cancel"` | |
| `id` | string | The `id` of the request being cancelled |

### `shutdown`

Nimlet is exiting or reloading. No reply needed. Stop your loop after this.

```json
{"type": "shutdown"}
```

## Messages from your extension

### `response`

Reply to a `tool`, `command`, or `event` request. Always echo the request `id`.

```json
{"type":"response","id":"7","content":[{"type":"text","text":"Saved."}],"is_error":false}
```

Fields nimlet reads depend on what you are replying to:

| Field | Type | Used for | Meaning |
| --- | --- | --- | --- |
| `type` | `"response"` | all | |
| `id` | string | all | Must match the request |
| `content` | array | `tool` | Typed text and image result parts |
| `is_error` | boolean | `tool` | Whether the tool failed |
| `message` | string | `command` | Text printed to the user |
| `prompt` | string | `command` | Starts a new turn with this text |
| `session` | object | `command` | Runs `new`, `fork`, `switch`, or `compact` after the response |
| `reload` | boolean | `command` | Reloads project resources after the response |
| `allow` | boolean | `tool_call`, `session_before_compact` | `false` blocks the action |
| `reason` | string | `tool_call`, `session_before_compact` | Shown to the model or user when blocked |
| `arguments` | object | `tool_call` | Replaces the tool arguments before execution |
| `output` | string | `tool_result` | Replaces tool output |
| `is_error` | boolean | `tool_result` | Replaces the error flag |
| `instruction` | string | `session_before_compact` | Extra instruction for the summarizer |
| `compaction` | object | `session_before_compact` | Full custom compaction. See below |
| `status` | object | any | Footer status line |
| `widget` | object | any | Lines above the footer |
| `notification` | object | any | Transcript message |
| `entry` | any JSON | any | Durable session data |
| `user_message` | object | any | Queue `content` as `now`, `steer`, or `follow_up` |

**`compaction` object** (on `session_before_compact` replies):

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `summary` | string | yes | Markdown summary written to the session |
| `first_kept_index` | integer | yes | How many session events to keep verbatim after the summary |
| `details` | any JSON | no | Stored in the session compaction record |

### `update`

Unsolicited side effects. No `id` required. Same side-effect fields as `response`:

```json
{
  "type": "update",
  "status": {"key": "job", "text": "researching"},
  "widget": {"key": "agents", "lines": ["✓ research", "… tests"]},
  "notification": {"level": "info", "message": "Research complete"},
  "entry": {"completed": ["research"]},
  "user_message": {"content": "Tests finished", "deliver_as": "follow_up"}
}
```

You can send `update` while a request is in flight, including from another thread,
as long as each line is valid JSON.

`user_message.deliver_as` is `now`, `steer`, or `follow_up`. `now` starts a turn
when nimlet is idle and otherwise waits for the current turn. `steer` enters at
the next tool boundary. `follow_up` waits until the current turn finishes.

### `ui_request` and `ui_response`

Ask the user a multiple-choice question from inside a `tool` or `command` handler:

```json
{
  "type": "ui_request",
  "id": "q1",
  "method": "question",
  "prompt": "Which environment?",
  "options": ["staging", "production"]
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `type` | `"ui_request"` | |
| `id` | string | Matched on the response |
| `method` | string | `question`, `confirm`, `input`, or `password` |
| `prompt` | string | Question text |
| `options` | string array | Choices shown to the user |

Nimlet replies on stdin:

```json
{"type": "ui_response", "id": "q1", "answer": "staging", "cancelled": false}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `type` | `"ui_response"` | |
| `id` | string | Matches your `ui_request` |
| `answer` | string | Selected option. Empty when dismissed |
| `confirmed` | boolean | Confirmation result for `confirm` |
| `cancelled` | boolean | `true` when there is no TUI to ask, or the user dismissed the prompt |

Time waiting for `ui_response` does not count against `response_timeout_seconds`.
`password` uses a masked input and is not written to the transcript or session.

### `host_request` and `host_response`

Use a host request inside a tool or command handler when you need an isolated
model completion, the user's external text editor, or current session details. Host requests do not enter the
session history, and time spent waiting does not count against
`response_timeout_seconds`.

Generate text with the active provider and model:

```json
{
  "type": "host_request",
  "id": "generate-1",
  "method": "model.complete",
  "system_prompt": "Write a concise handoff prompt.",
  "prompt": "Conversation and next task...",
  "max_tokens": 4096
}
```

Nimlet replies:

```json
{
  "type": "host_response",
  "id": "generate-1",
  "result": {
    "text": "## Context\n...",
    "model": "claude-sonnet-4-6",
    "finish_reason": "frEndTurn"
  }
}
```

`prompt` is required. `system_prompt` is optional. `max_tokens` defaults to the
configured output limit. This call has no tools and does not append either
message to the current session.

Open text in `$VISUAL`, then `$EDITOR`, falling back to `nano`:

```json
{
  "type": "host_request",
  "id": "editor-1",
  "method": "ui.editor",
  "title": "Edit handoff prompt",
  "text": "## Context\n..."
}
```

A successful response contains `result.text`. When an editor is unavailable or
the operation cannot complete, `result.cancelled` is `true` and `result.error`
describes why. Other host request failures return a top-level `error`.

The remaining host methods expose small pieces of current-session state:

| Method | Input | Result |
| --- | --- | --- |
| `session.info` | none | `id`, `name`, `path`, `workspace`, and `event_count` |
| `session.name` | optional `name` | Gets the name, or sets and returns it |
| `context.usage` | none | Estimated `tokens`, context `limit`, and `percent` |

## Lifecycle events

These are the only hook names you can list in `register.events`. Unknown names
are accepted at registration but never fire.

| Event | When it fires |
| --- | --- |
| `tool_call` | Before a tool executes |
| `tool_result` | After a tool returns, before the result is saved |
| `turn_start` | At the start of each agent turn |
| `turn_end` | When a turn finishes or is interrupted |
| `context` | Before every model request, after compaction and queued-message delivery |
| `session_start` | When nimlet starts, and after `/new`, `/resume`, or `/fork` |
| `session_end` | Before switching sessions, and when nimlet exits |
| `session_before_compact` | Before compaction runs (auto or manual `/compact`) |
| `session_compact` | After compaction finishes |

**When hooks do not run:**

- **Plan mode** - only `context` is dispatched. Other hooks require act mode.
- **`ask_user`** - the built-in question tool does not trigger `tool_call` or
  `tool_result` hooks.

**Which tools trigger `tool_call` / `tool_result`:**

- All built-in tools except `ask_user`
- All extension tools you register
- `read`, `grep`, `glob`, and `read_skill` can run in parallel when the model
  requests several in one step; each still gets its own hook round trip

**Multiple extensions:** if several extensions subscribe to the same event,
nimlet asks each one in startup order. For `tool_call` and
`session_before_compact`, any `allow: false` blocks the action; reasons are joined
with `; `. On other events, `allow: false` is ignored but you must still reply.

### `tool_call`

**Payload:**

| Field | Type | Meaning |
| --- | --- | --- |
| `tool` | string | Tool name (`bash`, `read`, your extension tool name, etc.) |
| `arguments` | object | Arguments the model sent. `{}` when empty |

**Reply fields that change behavior:**

| Field | Effect |
| --- | --- |
| `allow: false` | Blocks the tool. The model receives `approval_denied` with `reason` |
| `arguments` | Replaces the arguments object before execution |

```json
{"type": "response", "id": "9", "allow": false, "reason": "Not while tests are running"}
```

```json
{"type": "response", "id": "9", "arguments": {"path": "src/main.py"}}
```

### `tool_result`

**Payload:**

| Field | Type | Meaning |
| --- | --- | --- |
| `tool` | string | Tool name |
| `arguments` | object | Arguments that were used (after any `tool_call` rewrite) |
| `output` | string | Tool output text |
| `is_error` | boolean | Whether the tool failed |

**Reply fields that change behavior:**

| Field | Effect |
| --- | --- |
| `output` | Replaces the output string saved to the session |
| `is_error` | Replaces the error flag |

`allow: false` has no effect on this event.

### `turn_start`

**Payload:**

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | string | |
| `workspace` | string | Absolute workspace path |

Fires once per user message that starts an agent turn. Reply to acknowledge.
`allow: false` has no effect. Use side-effect fields if you want to update the
footer or store session data.

### `turn_end`

**Payload:**

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | string | |
| `workspace` | string | |
| `interrupted` | boolean | Present and `true` when the user stopped the turn with Esc or Ctrl+C |

Reply to acknowledge. `allow: false` has no effect.

### `context`

The payload contains the final `system` string array and typed `messages` array
for the next model request. Add context without replacing existing content:

```json
{
  "type": "response",
  "id": "9",
  "system": ["Current deployment target: staging"],
  "messages": [
    {"type":"user","role":"user","content":[{"type":"text","text":"CI is passing"}]}
  ]
}
```

Added system instructions and messages apply to that model request only. They
are not appended to the saved session.

### `session_start`

**Payload:**

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | string | |
| `workspace` | string | |

Fires at nimlet startup and after `/new`, `/resume`, or `/fork`. Reply to
acknowledge. `allow: false` has no effect.

### `session_end`

**Payload:** same as `session_start`.

Fires before switching to another session and when nimlet exits. Reply to
acknowledge. `allow: false` has no effect.

### `session_before_compact`

**Payload:**

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | string | |
| `workspace` | string | |
| `instruction` | string | Manual `/compact` instruction, or empty for auto-compaction |
| `tokens_before` | integer | Estimated context tokens before compaction |
| `entries` | array | Full session as JSON. See [Session entries](#session-entries) |

**Reply fields that change behavior:**

| Field | Effect |
| --- | --- |
| `allow: false` | Skips compaction. `reason` is shown to the user |
| `instruction` | Appended to the summarizer instruction (after any existing instruction, separated by a newline) |
| `compaction` | Skips the built-in summarizer and uses your summary instead |

```json
{
  "type": "response",
  "id": "9",
  "compaction": {
    "summary": "## Goal\n…",
    "first_kept_index": 96,
    "details": {"source": "my-extension"}
  }
}
```

### `session_compact`

**Payload:**

| Field | Type | Meaning |
| --- | --- | --- |
| `session_id` | string | |
| `workspace` | string | |
| `did_compact` | boolean | Whether compaction actually ran |
| `summary` | string | Summary text, or empty when nothing was compacted |
| `first_kept_index` | integer | Events kept verbatim. `0` when nothing was compacted |
| `tokens_before` | integer | Estimated tokens before compaction |
| `message` | string | Status message (`Auto-compacted context`, `Nothing to compact`, etc.) |

Fires after compaction completes. Reply to acknowledge. `allow: false` has no
effect.

## Session entries

The `entries` field on `session_before_compact` is a JSON array of every event in
the current session, in order. Each object has a `type` field:

| `type` | Fields | Meaning |
| --- | --- | --- |
| `user` | `role`, `content` | User message |
| `assistant` | `role`, `content`, optional `model`, `provider`, `requested_model`, `usage` | Assistant message |
| `tool_result` | `id`, `output`, `is_error`, optional `images` | Standalone tool result event |
| `compaction` | `summary`, `first_kept_index`, `tokens_before`, optional `details` | Prior compaction |
| `extension` | `extension`, `data` | Extension bookkeeping from `entry` replies |
| `name` | `name` | Session title from `/name` |
| `selection` | `provider`, `model` | Provider/model selection event |

**`content` arrays** inside `user` and `assistant` messages contain typed parts:

| Part `type` | Fields |
| --- | --- |
| `text` | `text` |
| `tool_use` | `id`, `name`, `input`, optional `parse_error`, `hosted`, `thought_signature` |
| `thinking` | `thinking`, `signature` |
| `tool_result` | `tool_use_id`, `content`, `is_error`, optional `images` |
| `image` | `mimeType`, `path` or `data` |
| `file` | `mimeType`, `path` or `data`, optional `filename` |
| `source` | `url`, `title`, optional `id`, `cited_text`, `raw` |

The workspace path is not in `entries`. It is only on the session file header line.

## Side effects

These fields can appear on any `response` or unsolicited `update` line.

### `status`

```json
{"key": "job", "text": "researching"}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `key` | string | Short identifier. Namespaced as `<extension-name>:<key>` |
| `text` | string | Shown in the footer. Empty string removes this status |

### `widget`

```json
{"key": "agents", "lines": ["✓ research", "… tests"], "placement": ""}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `key` | string | Namespaced like status |
| `lines` | string array | Lines drawn above the footer. Empty array removes the widget |
| `placement` | string | Accepted but not used by the TUI today |

### `notification`

```json
{"level": "info", "message": "Research complete"}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `level` | string | `error` and `warning` are styled. Anything else (including `info`) is plain text |
| `message` | string | Printed in the transcript |

### `entry`

Arbitrary JSON stored in the session under your extension name:

```json
{"count": 1, "phase": "research"}
```

Written as a session event:

```json
{"type": "extension", "extension": "lifecycle", "data": {"count": 1}}
```

`entry` data is never sent to the model. It persists across `/resume` and is the
right place for extension state you need when the process restarts.

## Tool capabilities

| Capability | Meaning |
| --- | --- |
| `read` | Reads data, changes nothing |
| `user` | Talks to the user rather than the world |
| `write` | Changes files |
| `shell` | Runs commands |
| `network` | Reaches the network |

A tool whose capabilities are only `read` and/or `user` is offered in plan mode as
well as act mode. Omitting `capabilities` counts as `write`, `shell`, and
`network`, so the tool stays act-only.

Built-in names you cannot register: `ask_user`, `bash`, `edit`, `git`, `glob`,
`grep`, `read`, `read_skill`, `write`.

Extension tools use the normal permission prompt the first time, keyed as
`tool:<name>`. `--tools` filters extension tools the same way as built-ins.

:::caution[Answer every request]
Nimlet waits for a reply to each `tool`, `command`, and `event` request. If you
stay silent, nimlet waits for `response_timeout_seconds` and continues with a
warning. When you have nothing to change, reply with
`{"type":"response","id":"<id>"}`.
:::

Failures are fail-open: if an extension crashes, times out, or returns malformed
JSON, nimlet reports a warning and the session continues without that extension's
contribution.

## Examples

### A small Python extension

```python title=".nimlet/extensions/notes/extension.py"
#!/usr/bin/env python3
import json, sys

def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()

send({"type": "register",
      "commands": [{"name": "note", "description": "Append a note to NOTES.md"}],
      "tools": [{
          "name": "save_note",
          "description": "Save a note about the current work.",
          "input_schema": {"type": "object",
                           "properties": {"text": {"type": "string"}},
                           "required": ["text"]},
          "capabilities": ["read"]
      }]})

for line in sys.stdin:
    message = json.loads(line)
    kind = message.get("type")

    if kind == "command":
        with open("NOTES.md", "a") as handle:
            handle.write(message["arguments"] + "\n")
        send({"type": "response", "id": message["id"], "message": "Noted."})

    elif kind == "tool":
        with open("NOTES.md", "a") as handle:
            handle.write(message["arguments"]["text"] + "\n")
        send({"type": "response", "id": message["id"],
              "content": [{"type": "text", "text": "Saved the note."}],
              "status": {"key": "notes", "text": "NOTES.md updated"}})

    elif kind == "shutdown":
        break
```

Make it executable (`chmod +x extension.py`), then `/reload`. `/note remember the
cache bug` appends a line to `NOTES.md`, and the model can call `save_note`.

### Guarding shell commands

Registers for `tool_call` and `turn_end`. Denies blocked commands and counts them
in a footer widget. Answers every event, including ones it does not act on:

```python title=".nimlet/extensions/guard/extension.py"
#!/usr/bin/env python3
import json, sys

BLOCKED = ("curl ", "wget ", "nc ", "ssh ")

def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()

send({"type": "register", "commands": [], "events": ["tool_call", "turn_end"]})

blocked = 0
for line in sys.stdin:
    message = json.loads(line)
    kind = message.get("type")
    if kind == "shutdown":
        break

    reply = {"type": "response", "id": message.get("id", "")}
    if kind == "event" and message["event"] == "tool_call":
        arguments = message["payload"].get("arguments") or {}
        command = str(arguments.get("command", ""))
        if any(word in command for word in BLOCKED):
            blocked += 1
            reply.update({
                "allow": False,
                "reason": "network commands are blocked in this project",
                "widget": {"key": "guard", "lines": [f"blocked {blocked}"]},
            })
    send(reply)
```

### JavaScript

The protocol is JSON lines over stdin and stdout. A single `.mjs` file and Node's
standard library are enough:

```js title=".nimlet/extensions/todos/extension.mjs"
#!/usr/bin/env node
import { readdirSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import readline from 'node:readline'

const send = (message) => process.stdout.write(JSON.stringify(message) + '\n')

send({
  type: 'register',
  commands: [{ name: 'todos', description: 'List TODO and FIXME comments' }],
  tools: [{
    name: 'list_todos',
    description: 'List TODO and FIXME comments as path:line text.',
    input_schema: { type: 'object', properties: {} },
    capabilities: ['read'],
  }],
  events: ['turn_end'],
})

async function handle(message) {
  switch (message.type) {
    case 'event':
      send({ type: 'response', id: message.id })
      break
    case 'shutdown':
      process.exit(0)
  }
}

const input = readline.createInterface({ input: process.stdin })
for await (const line of input) {
  if (line.trim()) await handle(JSON.parse(line))
}
```

On Windows, wrap `.mjs` files in a `.cmd` that calls `node "%~dp0extension.mjs" %*`.

## Reloading, timeouts, and errors

| Situation | What happens |
| --- | --- |
| `/reload`, `/new`, `/resume`, trust change | Extensions restart with a new `initialize` |
| Request timeout | `extension response timed out`. The tool call fails; the turn continues |
| `response_timeout_seconds: null` | No timeout. Use only when the extension always answers |
| `shutdown` | Sent on clean exit. Process is terminated if still running after a brief wait |
| Invalid `register` | Warning at startup. Extension is not loaded |
| Runtime parse error | Warning. Extension keeps running |
| Built-in tool name collision | Tool skipped with a warning |

**Debugging:**

```sh
./.nimlet/extensions/notes/extension.py </dev/null
```

```sh
printf '%s\n' \
  '{"type":"initialize","version":1,"workspace":"'"$PWD"'","session_id":"test"}' \
  '{"type":"command","id":"1","name":"note","arguments":"hello"}' \
  '{"type":"shutdown"}' | ./.nimlet/extensions/notes/extension.py
```

Stdout is the protocol. Write logs to a file, not stderr.

## Discovery roots compared

| Mechanism | Roots searched, in order | Same name overrides? |
| --- | --- | --- |
| Skills | `~/.agents/skills`, `~/.nimlet/skills`, `.agent/skills`, `.agents/skills`, `.nimlet/skills` | Yes |
| Prompt templates | `~/.agents/prompts`, `~/.nimlet/prompts`, `.agent/prompts`, `.agents/prompts`, `.nimlet/prompts` | Yes |
| `tool.json` tools | `~/.nimlet/tools`, `.agent/tools`, `.nimlet/tools` | Yes |
| Extensions | `~/.agents/extensions`, `~/.nimlet/extensions`, `.agents/extensions`, `.nimlet/extensions` | No, every one starts |

Project roots are skipped until you trust the project.

## Where to go next

- [Permissions](/guides/permissions/) for extension tool approval prompts
- [Context and compaction](/guides/context-and-compaction/) for what compaction does
- [External tools](/guides/external-tools/) for one-shot executables instead of persistent processes
