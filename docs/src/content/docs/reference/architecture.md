---
title: Architecture
description: The constraints nimlet is built around.
---

Nimlet is a local coding agent with a small runtime surface. This matters when
you are deciding how to use it in your development workflow or connect it to
your own software.

## Work happens in response to events

When nimlet is idle, it waits for terminal input, process output, or an operating
system signal. During a turn, model streaming, tool output, queued messages,
and terminal redraws are handled as the corresponding events arrive.

This makes unused features cheap: external tools are not started until called,
and model metadata is refreshed in the background rather than being required
before the first turn.

## A turn is incremental

For each turn, nimlet builds a provider request, streams the response, runs any
tool calls, and builds the next request until the model finishes or the run is
interrupted. Read, grep, glob, and read_skill calls can run in parallel when a
response requests more than one of them. Other calls run with their normal
ordering and permission behavior.

The request keeps stable instructions and tool definitions ahead of changing
conversation content. Sessions and compaction preserve enough structure for a
long conversation to continue without rewriting the original transcript.

## Sessions are append-only

Saved sessions are JSONL files. Each completed message, tool result, compaction,
and extension entry is appended and flushed. A damaged final line can be
recovered on the next append, while an interrupted tool call is recorded as an
unknown error and is never rerun automatically. See
[Sessions](/guides/sessions/) for the file format and recovery behavior.

## Extensions are processes

Persistent extensions are separate programs communicating with nimlet through
JSONL over stdin and stdout. They can register commands, tools, and lifecycle
events, then send status, widget, notification, or session entry updates. An
external `tool.json` tool uses the same process boundary for one call and exits.
See [External tools](/guides/external-tools/) and
[Extensions and hooks](/guides/extensions-and-hooks/) when you want to add
your own integration.

## Scope

The application focuses on streaming model calls, local tools, sessions,
instructions, extensions, and terminal interaction. It does not build a
repository index, LSP, daemon, embedded scripting runtime, or background agent
pool. Use the shell or an external tool when a task needs one of those systems.

## Choose an integration surface

- Use the interactive TUI for hands-on work.
- Use [print mode](/guides/quickstart/) when a script needs only the final text.
- Use [JSON mode](/reference/json-mode/) when your program consumes one streamed
  turn.
- Use [RPC mode](/reference/rpc-mode/) when your program needs a long-running
  process with queues and correlated commands.
- Use [external tools](/guides/external-tools/) for short-lived executables, or
  [extensions](/guides/extensions-and-hooks/) for a process that stays connected.
