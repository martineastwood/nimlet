---
title: Extensions and hooks
description: Persistent subprocesses that register tools, commands, and lifecycle hooks.
---

An extension is a program nimlet starts and keeps running while it is open,
talking over JSON lines on stdin and stdout. Any language works. While it runs, an
extension can register tools the model can call, add slash commands you can type,
and react to what happens in the session: tool calls, turns starting and
finishing, compaction, sessions opening and closing.

The difference from a `tool.json` tool: a tool is spawned per call with one JSON
argument and one JSON result, then exits. An extension is a conversation — it
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

| Field | Meaning |
| --- | --- |
| `name` | Required. Used in warnings, and as the namespace for status, widget, and stored entry keys |
| `command` | Required, non-empty array: the program and its arguments. The first element is resolved against the extension's folder when it contains a `/` |
| `response_timeout_seconds` | How long nimlet waits for a reply. Default 30, or `null` for no timeout. Time spent waiting for you to answer a question does not count |

The process starts with your workspace as its working directory, so relative
paths inside the extension see your project.

Tell the extension to run itself rather than naming an interpreter:

```json
{"name": "notes", "command": ["./extension.py"]}
```

Only the first element of `command` is resolved against the extension folder, so
`["python3", "./extension.py"]` would look for the script in your workspace
instead. Make the file executable and give it a shebang, and
`"command": ["./extension.py"]` works everywhere. On Windows, `.sh`, `.ps1`,
`.cmd`, and `.bat` files are launched through the matching interpreter, so the
same manifest can work on every platform.

A manifest that does not parse, or is missing `name` or `command`, is skipped
with a startup warning such as `skipping /path: missing name`. Nothing crashes.

## The handshake

nimlet sends one line:

```json
{"type":"initialize","version":1,"workspace":"/home/you/code/project","session_id":"1789233281025102"}
```

and waits for one line back:

```json
{"type":"register",
 "commands":[{"name":"note","description":"Append a note to NOTES.md"}],
 "tools":[{"name":"save_note","description":"Save a note about the current work.",
   "input_schema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]},
   "capabilities":["read"]}],
 "events":["tool_result"]}
```

Everything is optional except `commands`, which must be an array (empty is fine).
Registered tools need `name`, `description`, and an object `input_schema`;
`capabilities` is optional and decides plan mode and approval, as described below.
`events` lists only the lifecycle events this extension wants to receive.

After registering, nimlet reads the extension's output on a dedicated thread, so a
response wakes the interface immediately. There is no polling and no idle CPU
cost.

## A small extension

A command, a tool, and a status line, in about thirty lines of Python:

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
                           "required": ["text"]}
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
        send({"type": "response", "id": message["id"], "content": "Saved the note.",
              "status": {"key": "notes", "text": "NOTES.md updated"}})

    elif kind == "shutdown":
        break
```

Make it executable (`chmod +x extension.py`), then `/reload`. `/note remember the
cache bug` appends a line to `NOTES.md`, and the model can call `save_note` when it
has an insight worth keeping.

:::caution[Answer every request]
nimlet waits for a reply to each request it sends, and events are requests too. If
an extension stays silent, nimlet waits for `response_timeout_seconds` and then
carries on with a warning. When you have nothing to change, reply with just
`{"type":"response","id":"<id>"}`.
:::

## What nimlet sends

| Request | When | Reply |
| --- | --- | --- |
| `tool` | The model calls one of your tools | `content` (a string), `is_error` |
| `command` | You type the registered slash command | `message` to display, `prompt` to start a turn |
| `event` | A lifecycle event you registered for | `allow`, `reason`, plus the fields below |
| `cancel` | The user interrupted while you were working | None needed |
| `shutdown` | nimlet is exiting or reloading | None needed |

Every request carries an `id` and every reply must echo it. Replies are matched by
id, so an extension can have several requests in flight at once.

Both `message` and `prompt` can appear in a command reply: the message is printed,
and the prompt becomes your next turn. That is how an extension offers something
the model should act on.

## Tools

A registered tool behaves like a built-in one:

- The model sees its name, description, and input schema.
- Calling it raises the usual approval prompt the first time, keyed as
  `tool:<name>`, and `/permissions` lists the grant afterwards.
- The result is saved in the session like any other tool result.

`capabilities` controls two things. A manifest that lists none counts as write +
shell + network, so it is act-only and always asks. `["read"]`, or `["user"]` for
something that only talks to you, keeps the tool available in plan mode as well —
which is also a promise you are making about what the tool does, so declare
`read` only when it truly reads. A tool whose name collides with a built-in is
skipped with a warning at startup.

## Events

These are the events an extension can register for:

| Event | Fires | A reply can |
| --- | --- | --- |
| `tool_call` | Before a tool runs | Deny it, or replace `arguments` |
| `tool_result` | After a tool returns | Replace `output` or `is_error` |
| `turn_start` / `turn_end` | Around each turn | Report only (`turn_end` includes `interrupted` when you stopped the turn) |
| `session_start` / `session_end` | Session loads, switches, or nimlet exits | Report only |
| `session_before_compact` | Before context is summarized | Add an `instruction`, or supply a whole `compaction` |
| `session_compact` | After compaction | Report only |

Denying looks like this:

```json
{"type":"response","id":"9","allow":false,"reason":"Not while tests are running"}
```

The reason reaches the model as the tool result, so it understands why. A
`tool_call` reply can also rewrite the call before it runs:

```json
{"type":"response","id":"9","arguments":{"path":"src/main.nim"}}
```

Failures are fail-open: if an extension crashes, times out, or replies with
something malformed, nimlet reports a warning and the session continues without
its contribution. Register only the events you need — every event you list is a
round trip the turn waits on.

Events do not fire at all in plan mode.

## Pushing updates without being asked

A reply can carry extra fields, and the same shape can be sent at any time as an
`update`:

```json
{"type":"update",
 "status":{"key":"job","text":"researching"},
 "widget":{"key":"agents","lines":["✓ research","… tests"]},
 "notification":{"level":"info","message":"Research complete"},
 "entry":{"completed":["research"]}}
```

| Field | Where it goes |
| --- | --- |
| `status` | A short line in the status footer. Empty `text` removes it |
| `widget` | Extra lines drawn above the footer. Empty `lines` removes it |
| `notification` | A message in the transcript; `level` of `error` or `warning` styles it |
| `entry` | Appended to the session under the extension's name |

Keys are namespaced with the extension name automatically, so two extensions can
both use a key called `state` without colliding.

`entry` data is durable: it is stored in the session file and comes back when the
session is resumed. It is never sent to the model, so it is the right place for
bookkeeping a compiled-in extension needs to reload later — an external process
reads its own state from disk.

## Asking the user

An extension can ask a question and continue afterwards:

```json
{"type":"ui_request","id":"q1","method":"question","prompt":"Which environment?","options":["staging","production"]}
```

Nimlet answers with:

```json
{"type":"ui_response","id":"q1","answer":"staging","cancelled":false}
```

Time spent waiting for that answer does not count against the response timeout. In
a headless run (`-p`, `--mode json`, `--mode rpc`) there is nobody to ask, so the
answer comes back empty with `cancelled` set to true.

## Reloading, timeouts, and shutdown

- `/reload` stops and restarts every extension, which is how you pick up edited
  code. `/new`, `/resume`, and a trust change restart them too, with the new
  session id in `initialize`.
- A request that never arrives in time produces
  `extension response timed out`; the tool call fails with that message and the
  turn continues.
- On clean exit nimlet sends `{"type":"shutdown"}`, waits briefly, and terminates
  the process if it is still running.
- An extension that fails to start is reported as a warning, never as a fatal
  error: `extension 'notes' failed to start: …`.

## Discovery roots compared

| Mechanism | Roots searched, in order | Same name overrides? |
| --- | --- | --- |
| Skills | `~/.agents/skills`, `~/.nimlet/skills`, `.agent/skills`, `.agents/skills`, `.nimlet/skills` | Yes |
| Prompt templates | `~/.agents/prompts`, `~/.nimlet/prompts`, `.agent/prompts`, `.agents/prompts`, `.nimlet/prompts` | Yes |
| `tool.json` tools | `~/.nimlet/tools`, `.agent/tools`, `.nimlet/tools` | Yes |
| Extensions | `~/.agents/extensions`, `~/.nimlet/extensions`, `.agents/extensions`, `.nimlet/extensions` | No, every one starts |

Project roots in every row are skipped until you trust the project.

## Where to go next

- [Skills](/guides/skills/) for procedures that are only Markdown
- [Permissions](/guides/permissions/) for what an extension tool asks before it runs
- [Context and compaction](/guides/context-and-compaction/) for the compaction events