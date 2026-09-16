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

Only the first element of `command` is resolved against the extension folder
when it contains `/`, so `["python3", "./extension.py"]` would look for the
script in your workspace instead. On POSIX, make the file executable and give it
a shebang, and `"command": ["./extension.py"]` works. On Windows, use a
`.cmd` wrapper, or pass a workspace-relative script path to an interpreter, for
example `["python", ".nimlet/extensions/notes/extension.py"]`. `.sh`, `.ps1`,
`.cmd`, and `.bat` files are launched through the matching interpreter.

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

Registration is validated hard, because a half-registered extension is worse than
none. A `register` line that is not an object, `commands` or `events` that are not
arrays, a tool without a name, description, or schema, or an unknown capability
name all count as a failed start: nimlet prints a warning, stops the process, and
carries on without it.

After registering, nimlet reads the extension's output on a dedicated thread, so a
response wakes the interface immediately. There is no polling and no idle CPU
cost.

The conversation itself is strictly one JSON object per line in each direction.
Requests arrive on your stdin in the order nimlet sent them, and replies may come
back in any order: each one is matched by its `id`, so several requests can be in
flight at once. A tool call while a question is pending is normal, not a bug.

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

## The same protocol from JavaScript

The protocol is JSON lines over stdin and stdout, so a web developer does not need
a shim, a client library, or a bundle: a single `.mjs` file and Node's standard
library are enough. This extension adds a `/todos` command and a `list_todos` tool
that both scan the repository.

```json title=".nimlet/extensions/todos/extension.json"
{
  "name": "todos",
  "command": ["./extension.mjs"],
  "response_timeout_seconds": 60
}
```

```js title=".nimlet/extensions/todos/extension.mjs"
#!/usr/bin/env node
import { readdirSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import readline from 'node:readline'

const send = (message) => process.stdout.write(JSON.stringify(message) + '\n')
const SKIP = new Set(['node_modules', 'dist', 'build', '.git', '.next', '.turbo'])
const WANTED = /\.(m?[jt]sx?|css|html|vue|svelte|md)$/

function* walk(dir = '.') {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (SKIP.has(entry.name)) continue
    const path = `${dir}/${entry.name}`
    if (entry.isDirectory()) yield* walk(path)
    else if (WANTED.test(entry.name)) yield path
  }
}

async function findTodos() {
  const found = []
  for (const path of walk()) {
    const text = await readFile(path, 'utf8').catch(() => '')
    text.split('\n').forEach((line, index) => {
      if (/\b(TODO|FIXME)\b/.test(line)) {
        found.push(`${path}:${index + 1}  ${line.trim()}`)
      }
    })
  }
  return found
}

async function handle(message) {
  switch (message.type) {
    case 'command': {
      const found = await findTodos()
      send({ type: 'response', id: message.id, message: `${found.length} TODO comments` })
      break
    }
    case 'tool': {
      const found = await findTodos()
      send({
        type: 'response',
        id: message.id,
        content: found.slice(0, 50).join('\n') || 'No TODO or FIXME comments.',
      })
      send({ type: 'update', status: { key: 'todos', text: found.length ? `${found.length} TODOs` : '' } })
      break
    }
    case 'event':
      send({ type: 'response', id: message.id }) // a silent event stalls the turn
      break
    case 'shutdown':
      process.exit(0)
  }
}

send({
  type: 'register',
  commands: [{ name: 'todos', description: 'List TODO and FIXME comments' }],
  tools: [{
    name: 'list_todos',
    description: 'List TODO and FIXME comments as path:line text.',
    input_schema: { type: 'object', properties: {} },
    capabilities: ['read'],
  }],
})

const input = readline.createInterface({ input: process.stdin })
for await (const line of input) {
  if (line.trim()) await handle(JSON.parse(line))
}
```

```sh
chmod +x .nimlet/extensions/todos/extension.mjs
```

then `/reload`, and `/todos` works. A few notes for this style of extension:

- **The loop must await each handler.** Two lines can be read before the first
  reply is written, and then the replies race. Awaiting keeps the ordering
  obvious; replies are still matched by `id`, so sending them out of order is
  allowed, just harder to reason about.
- **`capabilities: ['read']` is what puts `list_todos` in plan mode.** The `/todos`
  command needs no switch, because commands are yours to run, not the model's.
- **Windows cannot launch a `.mjs` directly.** Add a one-line wrapper and point the
  manifest at it - the runtime launches `.cmd` and `.bat` files through `cmd.exe`:

  ```bat title=".nimlet/extensions/todos/extension.cmd"
  @echo off
  node "%~dp0extension.mjs" %*
  ```

- **TypeScript works the same way.** Write it in TS, compile (or let `tsx` run it),
  and point `command` at the compiled entry point. The manifest never knows which
  language answers, which is why the protocol is worth learning once.
- **Your extension runs with the workspace as its current directory**, so
  `child_process` can drive your existing tooling - `execFile('npx', ['tsc',
  '--noEmit'])` inside a tool handler is a perfectly normal extension. Nothing
  prompts for approval there: extensions are programs you installed, which is why
  the project trust question exists.

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

`capabilities` is a promise about what the tool does, and it decides two things:
where the tool is available, and how it is treated. The values are:

| Capability | Meaning |
| --- | --- |
| `read` | Reads data, changes nothing |
| `user` | Talks to you rather than the world |
| `write` | Changes files |
| `shell` | Runs commands |
| `network` | Reaches the network |

A tool whose capabilities are only `read` and/or `user` is offered in plan mode as
well as act mode. Anything else, including a manifest that lists no capabilities at
all - that counts as `write`, `shell`, and `network` - stays act-only. Both cases
still ask for approval the first time.

Two constraints sit on top of that. A tool whose name collides with a built-in is
skipped with a warning at startup. And `--tools` filters extension tools exactly
like built-ins, so `--tools read` means an extension tool only survives if its name
is in the allowlist.

## Events

These are the events an extension can register for, the payload you receive, and
what a reply can change:

| Event | Payload | A reply can |
| --- | --- | --- |
| `tool_call` | `tool`, `arguments` | Deny it, or replace `arguments` |
| `tool_result` | `tool`, `arguments`, `output`, `is_error` | Replace `output` or `is_error` |
| `turn_start` | `session_id`, `workspace` | Report or deny |
| `turn_end` | `session_id`, `workspace`, and `interrupted` when you stopped the turn | Report or deny |
| `session_start`, `session_end` | `session_id`, `workspace` | Report or deny |
| `session_before_compact` | `session_id`, `workspace`, `instruction`, `tokens_before`, `entries` (every event in the session) | Add an `instruction`, or supply a whole `compaction` |
| `session_compact` | `session_id`, `workspace`, `did_compact`, `summary`, `first_kept_index`, `tokens_before`, `message` | Report |

A reply can always carry the action fields described below, on any event, whether
or not it changes anything.

Denying looks like this:

```json
{"type":"response","id":"9","allow":false,"reason":"Not while tests are running"}
```

The reason reaches the model as the tool result, so it understands why. A
`tool_call` reply can also rewrite the call before it runs:

```json
{"type":"response","id":"9","arguments":{"path":"src/main.py"}}
```

Failures are fail-open: if an extension crashes, times out, or replies with
something malformed, nimlet reports a warning and the session continues without
its contribution. Register only the events you need - every event you list is a
round trip the turn waits on, so a hook that only matters occasionally still costs
a message per tool call.

Events do not fire at all in plan mode.

### A second example: guarding shell commands

This one registers for two events, denies a category of command, and keeps a
counter in the footer. It also shows the discipline that events need: the handler
answers *every* request, including the ones it does not act on.

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

`turn_end` arrives on every turn and the loop answers it without changing
anything, which is the whole point: an unanswered event is a stall, not a no-op.

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
bookkeeping a compiled-in extension needs to reload later - an external process
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
- `"response_timeout_seconds": null` means no timeout at all. Only use it when the
  extension always answers: otherwise the turn waits forever.
- On clean exit nimlet sends `{"type":"shutdown"}`, waits briefly, and terminates
  the process if it is still running.
- An extension that fails to start is reported as a warning, never as a fatal
  error: `extension 'notes' failed to start: …`.

## When something goes wrong

Everything here is a warning or a failed tool call, never a crash:

| Message | What happened |
| --- | --- |
| `skipping <dir>: missing name` | `extension.json` is not valid JSON or has no `name`/`command` |
| A tool error about JSON parsing | Your tool reply line was not valid JSON |
| `extension 'x' failed to start: expected register response` | The first line was not a `register` object |
| `register commands must be an array` | `commands` was missing or not an array |
| `register events must be strings` | `events` held something other than strings |
| `registered tools require name, description, and input_schema` | A tool entry was incomplete |
| `invalid capabilities for tool 'x': unknown capability: y` | A capability name is not one of the five |
| `extension tool 'bash' collides with a built-in tool` | The tool was skipped |
| `extension response timed out` | No reply within `response_timeout_seconds` |
| `extension 'x' …` plus a timeout on every call | The process died; check that it still runs |

Registration failures stop the process deliberately. Runtime failures do not: the
extension keeps running and the next request gets its own chance.

## Debugging an extension

**stdout belongs to the protocol.** One JSON object per line, nothing else. A stray
`print` in your code corrupts the stream and you will see parse errors, not
warnings. Write logs to a file instead. nimlet does not read your stderr either, so
do not treat it as a log sink that can absorb unlimited output.

**Run it by hand first.** The `register` line is sent before your loop reads
anything, so this alone tells you the manifest and the shebang work:

```sh
./.nimlet/extensions/notes/extension.py </dev/null
```

To exercise a whole conversation, feed it the same lines nimlet would:

```sh
printf '%s\n' \
  '{"type":"initialize","version":1,"workspace":"'"$PWD"'","session_id":"test"}' \
  '{"type":"command","id":"1","name":"note","arguments":"hello"}' \
  '{"type":"shutdown"}' | ./.nimlet/extensions/notes/extension.py
```

**Then `/reload`.** Edited code is only picked up when the extension restarts, and
`/reload` does that without losing the session. If a change seems to have no
effect, check the simpler explanation first: extensions are not overridden by name,
so a global and a project extension with the same name both run, and the one you
edited may not be the one answering.

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
