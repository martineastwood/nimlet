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

## Tab completion

Type `/` and the menu lists built-in commands, extension commands, and prompt
templates. `Tab`, `Up`, and `Down` move through suggestions; `Enter` accepts.
Commands that take arguments complete with a trailing space so you can keep typing.

Several commands have their own suggestions:

| Typing | Suggests |
| --- | --- |
| `/model ` | Recent models, then catalog matches with provider and context size |
| `/provider `, `/thinking `, `/web `, `/theme ` | Valid values |
| `/resume ` | Sessions in this workspace, filtered by id, name, or first message |
| `/session rename`, `/delete`, `/restore` | Matching session ids, or ids in the trash |
| `/fork ` | Your messages in this session, numbered |
| `@` | Workspace files and folders (up to 50 results; folders keep a trailing `/`) |

Prompt templates whose names collide with built-ins are not offered. Skills use
the `/skill:<name>` namespace and appear when you type that prefix.

## Composer and transcript

- Shift+Enter or Alt+J inserts a newline. Enter submits when idle.
- Ctrl+Z undoes. Ctrl+W and Alt+D delete words, and Ctrl+Y restores the last
  deleted text.
- Up and Down browse the last 500 non-slash inputs. The history is stored in
  `~/.nimlet/history`.
- Ctrl+G opens `$VISUAL`, then `$EDITOR`, then `nano`. The editor receives a
  temporary Markdown file and nimlet uses the saved text as the composer.
- PgUp, PgDn, and the mouse scroll the transcript. `Ctrl+O` expands or collapses
  tool output, thinking details, and colored before/after hunks from `edit` and
  `write` calls.
- Ctrl+F searches the transcript. Enter accepts a search, Escape cancels it,
  and Ctrl+P or Ctrl+N moves between matches.
- Select text with the terminal mouse support and copy it with the terminal's
  copy shortcut. `/copy` copies the latest assistant response when available.

## Questions from the model

When the model needs a decision it cannot make on its own, it can call the
`ask_user` tool. The TUI shows the question and a list of options. Pick one to
continue the turn, or dismiss the prompt to cancel. The model receives your
answer as the tool result.

`ask_user` is only available in the interactive TUI. JSON mode, RPC mode, and
the plain console return `question_unavailable` instead.

## Files, images, and shell shortcuts

Type `@` at a whitespace boundary to get workspace file suggestions. A file
mention attaches its contents, and a folder mention attaches a bounded listing.
Text attachments are capped at 100,000 bytes and folder listings at 200
entries. PNG, JPEG, GIF, and WEBP files attached with `@` are sent as image
content.

Pasting a single image file path (for example `/tmp/shot.png` or
`file:///tmp/shot.png`) turns it into an `@` mention. Paths inside the
workspace stay as-is; paths outside are copied into `.nimlet/clips/` first.
Pasting raw image bytes from the clipboard is not supported yet - your terminal
has to deliver a path string.

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
`--no-fullscreen` or `--regular` to keep the normal scrollback.

The footer shows the current mode (`[plan]` or `[act]`), `[yolo]` when active,
context usage (`ctx 42%`, amber at 70%, red at 90%), session cost and token
totals when pricing is known, retry and tool-call counts during a turn, hosted
web search status (`web` or `web:n/a`), and short status lines from extensions.
The right side of the footer shows `provider/model:thinking`.

Extensions can also push multi-line widgets above the footer (for example a
checklist or progress lines). These update live while the extension runs.

Use `/theme auto`, `/theme dark`, or `/theme light`. Custom JSON themes live in
`~/.nimlet/themes/` or `.nimlet/themes/` in a trusted project. See
[Configuration](/guides/configuration/) for the required color tokens and an
example file. Changes to the live chrome appear immediately. Transcript colors
are applied fully when you start or resume a session, or restart nimlet.

`/stats` prints the same usage and cost numbers with full detail.

Customize supported actions with the top-level `keybindings` object in
`config.json`. A value can be one key string or an array. An empty array disables
the default for that action. The complete action list is in
[Keyboard shortcuts](/reference/keybindings/).

## Plain console fallback

When stdout is not a TTY, nimlet falls back to a plain readline-style console
instead of the full TUI. It still runs turns, slash commands, and shell
shortcuts, but several TUI-only features are unavailable:

| Feature | Plain console |
| --- | --- |
| Tool approval prompts | Not shown; tools run without asking |
| `ask_user` questions | Fails with `question_unavailable` |
| Message queues (`Enter` / `Alt+Enter` while busy) | Not available |
| Transcript search, mouse scroll, colored hunks | Not available |
| `/copy` clipboard | Not available |
| `/settings` menu | Not available |

Use `--print` for a script-friendly final response, or [JSON mode](/reference/json-mode/)
for structured streaming output. Pipe input to stdin and nimlet selects print
mode automatically.
