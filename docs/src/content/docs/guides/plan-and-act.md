---
title: Plan and act mode
description: Read-only investigation with /plan, then implementation with /act.
---

nimlet runs in one of two modes:

- **Act** — the default. The agent can read, edit, and run commands.
- **Plan** — read-only. The agent reads files, searches the workspace, and checks
  Git history, then tells you what it found and what it would do.

Plan mode exists because the most expensive mistake an agent makes is a confident
edit to code it did not understand. Planning gives you the understanding part
first, at no risk to your working tree, and you decide when to move on.

## Switching between them

| Input | What happens |
| --- | --- |
| `/plan` | Switch to plan mode |
| `/act` | Switch back to act mode |
| `Shift+Tab` | Toggle, without touching what is in the composer |

Either way the change is immediate and confirmed in the transcript:

```text
Mode: plan
```

The footer always shows which mode you are in, as `[plan]` or `[act]`, next to
the model name.

There is no startup flag for this: the mode belongs to the running process. (It
is unrelated to `--mode json` and `--mode rpc`, which choose the output format.)

## While the agent is working

`Shift+Tab` during a running turn does not interrupt it. The switch is queued and
applied when the turn finishes, and pressing `Shift+Tab` again cancels the queued
switch. Until then the footer keeps showing the mode you are still in.

`/plan` and `/act` cannot be queued like messages can. If you type one mid-turn,
the composer declines with `slash commands cannot be queued`. Wait for the turn,
or press `Esc` to interrupt it first.

## What plan mode exposes

These built-in tools are available:

| Tool | What it does |
| --- | --- |
| `read` | Read a file in the workspace |
| `grep` | Search file contents |
| `glob` | Find files by path pattern |
| `git` | Read-only status, log, show, diff, and blame |
| `read_skill` | Load a skill body |
| `ask_user` | Ask you a question with options |

Extension tools are included too, but only when their manifest declares read-only
capabilities — `"capabilities": ["read"]`, or `["user"]` for something that only
talks to you. A manifest without a capabilities list is treated as unsafe, so
those tools stay in act mode.

## What plan mode disables

- `edit` and `write`, so no file changes
- `bash`, so no builds, tests, installs, or commits
- hosted web search: the provider-side `web_search` tool is only offered in act
  mode
- extension tools that are not read-only
- extension hooks — `tool_call`, `tool_result`, `session_start`, `turn_end`, and
  the rest do not fire while you are in plan mode

The model is told the current mode in its instructions for each request, along
with the shorter tool list:

```text
Current mode: PLAN. Investigate and discuss the requested work; do not implement
changes. The request's read-only tool list is authoritative ... Never call an
absent tool, and never use edit, write, bash, hosted tools, or a non-read-only
extension in PLAN.
```

Plan mode restricts tools; it does not erase context. Anything the agent already
read this session stays in the conversation, so switching to plan does not mean
starting over.

## If the model tries anyway

Unadvertised tool calls are rejected when they run, not merely discouraged:

```text
Tool unavailable in plan mode. The user must switch to /act to enable implementation tools.
```

YOLO mode does not change this. Plan mode is checked before the permission layer,
so `/yolo` still leaves edits and shell commands unavailable.

## What still works

Most of nimlet behaves exactly as usual:

- session history saves, so a plan-mode conversation is there under `/resume`
- configuration commands: `/model`, `/provider`, `/thinking`, `/theme`,
  `/settings`, `/name`
- session commands: `/new`, `/resume`, `/session`, `/fork`
- `/compact`, along with automatic compaction, since summarizing is a model call
  rather than a change to your workspace
- prompt templates, skills, and extension commands you invoke yourself
- `ask_user` questions, and `!command` shortcuts you type in the composer

## When to plan, and when to act

- **Unfamiliar repository or subsystem** — plan first. Let the agent read, then
  read its summary of what it found.
- **A bug you can describe but not locate** — plan, then `/act` in the same
  session. Act mode is told to reuse the plan and the tool results already in the
  conversation instead of exploring the repository again.
- **A small change you fully understand** — just act. Planning a one-line fix
  costs a round trip and buys nothing.
- **Something that affects other people** — plan, then agree on the approach
  before any files move.

Planning is optional and there is no plan file to write, review, or commit. The
plan is the conversation, and it is saved in the session like everything else.

## Scope of the mode

- The mode belongs to the process, so `/new` and `/resume` keep whatever mode you
  were in.
- Restarting nimlet starts in act mode. The mode is never written to your config.
- A queued mode switch applies to the turn after the current one finishes, not to
  the turn in flight.

## Where to go next

- [Security](/guides/security/) for what still needs approval in act mode
- [Sessions](/guides/sessions/) for how plans end up on disk
- [Context and compaction](/guides/context-and-compaction/) for what happens when
  the investigation gets long
