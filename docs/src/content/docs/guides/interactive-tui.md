---
title: Interactive TUI
description: The composer, queued messages, transcript, shortcuts, and themes.
---

While a turn is running the composer stays editable and Enter/Alt+Enter queue
messages instead of submitting them. Nimlet keeps two independent queues:
steering and follow-up.

## Message queues

- Enter queues a **steering** message, delivered after the current assistant
  tool batch and before the next model call.
- Alt+Enter queues a **follow-up** message, delivered after the agent finishes.
- Escape / Ctrl-C interrupts and restores queued messages to the composer.
- Alt+Up restores queued messages without interrupting the current turn.
- Slash commands cannot be queued while a turn runs.
- The footer lists pending messages (`Steering:` / `Follow-up:`) and shows
  `queue:N` in the status line while anything is queued.

## Queue modes

Steering and follow-up each have their own delivery mode, so you can tune how
much of the queue is released at each hand-off point:

- `one-at-a-time` (default) — only the oldest message is delivered at the next
  boundary; the rest stay queued for later boundaries.
- `all` — the whole queue is delivered at the next boundary.

Set them from `/settings` → `Queue` (Steering: one-at-a-time / all, Follow-up:
one-at-a-time / all). The choice is persisted in the active config as
`agent.steering_mode` and `agent.follow_up_mode` and takes effect immediately.

## Other controls

- External editor: Ctrl-G opens `$VISUAL`, then `$EDITOR`, then `nano`.
- Composer editing: Ctrl-Z undoes, Ctrl-W/Alt-D delete words, and Ctrl-Y yanks
  the last deleted text.
- Shell shortcuts: `!command` runs and sends output to the model;
  `!!command` runs without sending output to the model.
- The event-driven TUI and what "near-zero idle CPU" means in practice
  (`NIMTERM_PERF=1` for frame/latency diagnostics)
- Composer editing: Enter, Shift+Enter, cursor movement, Home/End, history
- Keybindings can be overridden in the top-level `keybindings` object in
  `config.json`; values are key strings or arrays of key strings.
- Transcript: scrolling (PgUp/PgDn, wheel), selecting and copying text,
  Ctrl-O to toggle tool output and thinking details, `/copy`
- Footer and `/stats`: model, context, token usage, cost
- Themes: `/theme`, built-ins (`auto`, `dark`, `light`), user themes in
  `.nimlet/themes` and `~/.nimlet/themes`
- Pasting text or clipboard images with Ctrl-V, and `@path` file/folder
  mentions in the composer
- Full keyboard shortcut table
