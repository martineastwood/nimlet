---
title: Sessions
description: Session ids, resume, fork, naming, and recovery.
---

Every conversation you have with nimlet is saved as you go. There is nothing to
switch on: when you send your first message, nimlet starts a session, writes each
step to a file, and keeps writing until you quit. This page explains what those
files are, how to come back to one later, and what happens when something goes
wrong.

## What a session is

A session is one conversation, stored as a single append-only JSONL file: one
JSON object per line, each line a user message, an assistant response, a tool
result, or a small bookkeeping entry. Nothing rewrites earlier lines, so an
interrupted run can never damage the history behind it.

By default the files live in `~/.nimlet/sessions`, named after the session id:

```text
~/.nimlet/sessions/1789233281025102.jsonl
```

The id is a microsecond timestamp, which is why it looks like a long number.
Each id is also a valid argument almost anywhere a session is accepted.

The first line records the workspace the session belongs to. A trimmed file
looks roughly like this:

```jsonl
{"type":"session","workspace":"/Users/you/code/nimlet"}
{"type":"user","role":"user","content":[{"type":"text","text":"why is the parser test failing?"}]}
{"type":"assistant","role":"assistant","content":[{"type":"tool_use","id":"call_1","name":"bash","input":{"command":"npm test"}}],"model":"..."}
{"type":"tool_result","id":"call_1","output":"exit_code: 1","is_error":true}
```

Only the conversation itself goes to the model. Session names, extension state,
and the record of which provider and model you were using stay in the file and
are never sent.

If you want a conversation that leaves nothing behind, start with `--no-session`.
The transcript stays in memory for that run only. It cannot be combined with
`--resume` or `--session`.

## Checking and naming

`/session` prints where you are:

```text
Session: 1789233281025102
Name: fix the parser
Events: 24
File: /Users/you/.nimlet/sessions/1789233281025102.jsonl
Workspace: /Users/you/code/nimlet
Thinking: (default)
```

`/new` starts a fresh session and clears the transcript. The old one stays on
disk, so nothing is lost - it will still be there under `/resume`.

`/name fix the parser` gives the current session a title. The name shows up in
session lists, which makes a stack of timestamps much easier to tell apart.
`/name` on its own prints the current name.

`/stats` prints the active provider and model, the latest request's token usage
and cost estimate, the context window percentage, and the same numbers totalled
across the session. `/copy` copies the latest assistant response to your clipboard
in the interactive TUI.

## Resuming

`/resume` on its own opens a session picker inside the composer, listing the
newest 20 sessions for this workspace, most recent first:

```text
Sessions (newest first):
  2m ago   fix the parser        #1789233281025102  (current)
  3h ago   why is bash slow       #1789210000000000
  4d ago   (empty)                #1789100000000000
```

Each line shows how long ago the session was last written, then its name or the
first thing you asked, then the id. Start typing to filter the list - the text
you type is matched against the id, the name, and that first message. The filter
searches every session, not just the newest 20.

Two shortcuts work while the picker is open:

| Key | What it does |
| --- | --- |
| `Ctrl-R` | Fills the composer with `/session rename <id> ` |
| `Ctrl-D` | Fills the composer with `/session delete <id>` and asks you to press `Enter` to confirm |

`/resume 1789233281025102` loads that session directly.

When a session loads, the transcript is redrawn from the file and the provider
and model that session was using are selected again. Your saved defaults are left
alone: resuming an old Anthropic session does not change what the next new
session starts with.

You can also resume straight from the shell:

```sh
nimlet --resume                      # the latest session in this workspace
nimlet --session 1789233281025102    # one specific session
```

Sessions are filtered by the workspace they were started in, so a project's
`/resume` list shows that project's conversations. Loading one by id from
somewhere else still works, with a warning:

```text
This session was started in /Users/you/code/other-project
```

Sessions created before nimlet recorded the workspace have no header, so they are
hidden from workspace lists. They can still be opened by id.

## Forking a conversation

A fork is a new session that starts from part of an old one. Nothing about your
files changes - you branch the conversation, not the code.

`/fork` opens a menu of your messages in the current session, numbered in order.
`/fork 3` forks directly from your third message. The new session contains
everything leading up to that message, that message is placed back in the
composer so you can reword it, and you carry on from there. The original session
is untouched.

Because only the conversation branches, `/fork` warns you when your Git workspace
has uncommitted changes: the new session will be talking about a working tree
that has moved on since those messages were written.

## Recovery

Crashes and interruptions happen, so sessions are written defensively.

**A turn was interrupted mid-tool.** Maybe you pressed `Esc`, maybe the process
died. On resume, nimlet records a result for each tool call that never produced
one, marked as an error with an unknown outcome:

```text
Interrupted before a tool result was saved. Execution outcome is unknown;
inspect current state before retrying any action.
```

Nothing is rerun automatically. That matters for a tool like `bash`, where a
command may have applied half its work before you stopped it. Completed results
from earlier in the turn are kept exactly as they were.

**The file's last line is damaged.** If nimlet is killed between writing a line
and its newline, the file ends mid-object. Bytes like that are ignored on load,
and the next append repairs the file: the original is saved next to it as
`<id>.jsonl.recovery-<timestamp>` and the readable part is put back in place. You
end up with a working session plus the exact bytes that were lost, in case
anything in them is worth reading.

**The file changed underneath you.** If another process has written to the file
since nimlet loaded it, nimlet will not repair or append and says so:

```text
Session changed on disk; reload before recovery.
```

Reload with `/resume <id>` or start with `/new`, then try again.

## Export and sharing

`/export` writes a standalone HTML transcript to
`nimlet-session-<session-id>.html` in the workspace. Pass a path to choose the
output file:

```text
/export review.html
```

The export includes messages, tool calls, tool results, thinking, and
attachments stored in the session. Review it for sensitive data before sharing.

## Renaming, deleting, and restoring

These take a session id, which you can copy from a `/resume` list or from the
picker shortcuts above:

```text
/session rename 1789233281025102 fix the parser
/session delete 1789233281025102
/session restore 1789233281025102
```

Deleting asks for confirmation and moves the file into a trash folder beside the
others (`~/.nimlet/sessions/.trash/`) rather than erasing it, so `/session
restore` can bring it back. The session you are currently in cannot be deleted -
switch to another one with `/new` or `/resume` first.

## Where they are stored

Sessions default to `~/.nimlet/sessions`, and the location is configurable with
`agent.session_dir`:

```json title=".nimlet/config.json"
{
  "agent": {
    "session_dir": "~/nimlet-sessions"
  }
}
```

`~` expands to your home directory, and a relative path is read from the
directory you started nimlet in.

These are ordinary files, so normal tools work on them: `grep` them, copy them to
another machine, or delete a session outside nimlet if you prefer. Just avoid
editing lines by hand - each line has to stay valid JSON for the session to load.

## Where to go next

- [Context and compaction](/guides/context-and-compaction/) for what happens when
  a long session fills the context window
- [Files and directories](/reference/files-and-directories/) for everything
  nimlet writes, and where
- [Security](/guides/security/) for how transcripts relate to secrets
