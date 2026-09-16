---
title: Interactive TUI
description: The composer, queued messages, transcript, shortcuts, and themes.
---

The interactive TUI gives you a live transcript, an editable composer, and
status for the current model and session. While a turn is running, the composer
stays editable and Enter or Alt+Enter queues messages instead of submitting
them.

## Message queues

- Enter queues a **steering** message, delivered after the current assistant
  tool batch and before the next model call.
- Alt+Enter queues a **follow-up** message, delivered after the agent finishes.
- Escape / Ctrl-C interrupts and restores queued messages to the composer.
- Alt+Up restores queued messages without interrupting the current turn.
- Slash commands cannot be queued while a turn runs.
- The footer lists pending messages (`Steering:` / `Follow-up:`) and shows
  `queue:N` while anything is queued.

## Queue modes

Steering and follow-up each have their own delivery mode, so you can tune how
much of the queue is released at each hand-off point:

- `one-at-a-time` (default): only the oldest message is delivered at the next
  boundary; the rest stay queued for later boundaries.
- `all`: the whole queue is delivered at the next boundary.

Set them from `/settings` -> `Queue` (Steering: one-at-a-time / all, Follow-up:
one-at-a-time / all). The choice is persisted in the active config as
`agent.steering_mode` and `agent.follow_up_mode` and takes effect immediately.

## Start and stop turns

When nothing is running, Enter submits the composer. Press Escape or Ctrl+C to
interrupt an active turn. Press Ctrl+C again with an empty composer to quit.
`/quit` and `/exit` also leave the application.

## Composer and transcript

- Shift+Enter or Alt+J inserts a newline. Enter submits when idle.
- Ctrl+Z undoes. Ctrl+W and Alt+D delete words, and Ctrl+Y restores the last
  deleted text.
- Up and Down browse the last 500 non-slash inputs. The history is stored in
  `~/.nimlet/history`.
- Ctrl+G opens `$VISUAL`, then `$EDITOR`, then `nano`. The editor receives a
  temporary Markdown file and nimlet uses the saved text as the composer.
- PgUp, PgDn, and the mouse scroll the transcript. Ctrl+O expands or collapses
  tool output and thinking details.
- Ctrl+F searches the transcript. Enter accepts a search, Escape cancels it,
  and Ctrl+P or Ctrl+N moves between matches.
- Select text with the terminal mouse support and copy it with the terminal's
  copy shortcut. `/copy` copies the latest assistant response when available.

## Files, images, and shell shortcuts

Type `@` at a whitespace boundary to get workspace file suggestions. A file
mention attaches its contents, and a folder mention attaches a bounded listing.
Text attachments are capped at 100,000 bytes and folder listings at 200
entries. Pasted PNG, JPEG, GIF, and WEBP images are attached as image content;
workspace clips are stored under `.nimlet/clips/`.

Use shell shortcuts for quick local commands:

```text
!git status --short
!!git diff --stat
```

`!command` shows the command output and sends it to the model. `!!command`
shows the output only in the transcript. These shortcuts are typed by you and
run directly, so they do not use the model tool approval prompt. Set
`NIMLET_SHELL` to choose the shell explicitly.

## Fullscreen, themes, and status

The TUI uses the terminal alternate screen by default. Start with
`--no-fullscreen` or `--regular` to keep the normal scrollback. The footer and
`/stats` report the provider, model, thinking level, context usage, token usage,
cost when pricing is available, tool activity, and hosted web search status.

Use `/theme auto`, `/theme dark`, or `/theme light`. Custom JSON themes can live
in `~/.nimlet/themes` or the trusted project's `.nimlet/themes` directory.
Changes to the live chrome appear immediately. Transcript colors are applied
fully when you start or resume a session, or restart nimlet.

Customize supported actions with the top-level `keybindings` object in
`config.json`. A value can be one key string or an array. An empty array disables
the default for that action. The complete action list is in
[Keyboard shortcuts](/reference/keybindings/).

## Plain console fallback

When terminal output is not interactive, nimlet uses a plain console. It still
can run turns and shell shortcuts, but it does not provide the TUI's questions,
approval controls, transcript search, or queue composer. Use `--print` for a
script-friendly final response, or [JSON mode](/reference/json-mode/) for
structured streaming output.
