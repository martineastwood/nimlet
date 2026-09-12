---
title: Keyboard shortcuts
description: Every key binding in the interactive TUI, and how to change them.
---

This page lists what each key does in the interactive prompt, and how to change
the ones you do not like. If you are new to nimlet, you can ignore the
customisation half and just skim the tables.

## Composer and editing

| Key | Action |
| --- | --- |
| `Enter` | Submit the prompt (or queue it, if a turn is running) |
| `Shift+Enter` / `Alt+J` | Insert a newline |
| `Tab` | Accept the highlighted completion |
| `Left` / `Right` | Move the cursor one character |
| `Alt+B` / `Alt+F` | Move the cursor one word |
| `Home` / `Ctrl+A` | Move to the start of the line |
| `End` / `Ctrl+E` | Move to the end of the line |
| `Up` / `Down` | Move through your input history (or the completion menu) |
| `Ctrl+P` / `Ctrl+N` | Previous / next input history entry |
| `Backspace` | Delete the character before the cursor |
| `Delete` / `Ctrl+D` | Delete the character after the cursor |
| `Ctrl+W` / `Alt+D` | Delete the word before / after the cursor |
| `Ctrl+U` / `Ctrl+K` | Delete to the start / end of the line |
| `Ctrl+Y` | Yank the last deleted text back |
| `Ctrl+Z` | Undo |
| `Ctrl+G` | Edit the prompt in your external editor |
| Paste (`Cmd+V` / `Ctrl+V`) | Insert pasted text; a single image path becomes an `@` mention |

Pasting is handled by your terminal, so what reaches nimlet is the pasted text.
If that text is the path to an image (`/tmp/shot.png`, `file:///tmp/shot.png`, or
a path inside your workspace), nimlet replaces it with an `@` mention and sends
the image with your next message.

:::tip[Shift+Enter submits instead of making a new line?]
Not every terminal tells nimlet that Shift was held, so `Shift+Enter` can arrive
as a plain Enter. When that happens, use `Alt+J` instead — it always inserts a
newline.
:::

## Messages and queues

While a turn is running, the composer stays editable. `Enter` and `Alt+Enter`
queue messages instead of submitting them, so you can keep typing while the
agent works.

| Key | Action |
| --- | --- |
| `Enter` | Queue a steering message, delivered after the current tool batch |
| `Alt+Enter` | Queue a follow-up message, delivered after the turn finishes |
| `Alt+Up` | Take queued messages back into the composer, without interrupting |
| `Esc` | Interrupt the turn, and return queued messages to the composer |
| `Ctrl+C` | Interrupt the turn |

When nothing is running, `Esc` clears the composer, `Ctrl+C` clears it if it has
text, and `Ctrl+C` again on an empty composer quits nimlet.

## Modes and panels

| Key | Action |
| --- | --- |
| `Shift+Tab` | Switch between plan and act mode |
| `Ctrl+O` | Expand or collapse tool output and thinking details |
| `Ctrl+F` | Search the transcript |
| `PgUp` / `PgDn` | Page the transcript up and down |
| Mouse wheel | Scroll the transcript |

In the transcript search box, `Enter` accepts, `Esc` cancels, and `Ctrl+N` /
`Ctrl+P` jump to the next and previous match. In the `/resume` picker, `Ctrl+R`
renames the highlighted session and `Ctrl+D` stages it for deletion.

## Selecting text

Drag over the transcript to select lines, then release to copy the selection to
your clipboard. `Ctrl+Shift+C` (or `Cmd+C`, where the terminal reports it) does
the same for the current selection.

To copy without selecting, expand the text you want with `Ctrl+O` and use your
terminal's own selection, or run `/copy` to copy the latest assistant response.

## Changing a binding

Bindings live in the top-level `keybindings` object of your config. Add it to
`.nimlet/config.json` in your project, or to `~/.nimlet/config.json` for
everything you run. Each entry maps an action name to one key, or to an array of
keys:

```json title=".nimlet/config.json"
{
  "keybindings": {
    "app.editor.external": "ctrl+e",
    "tui.editor.deleteWordBackward": ["ctrl+w", "ctrl+h"]
  }
}
```

An array replaces the defaults for that action, so list every key you want, not
just the extra ones. Use an empty array to disable a binding entirely:

```json
{
  "keybindings": {
    "app.editor.external": []
  }
}
```

Keys are written lowercase, joined with `+`. Supported names:

- `ctrl+<letter>`, for example `ctrl+g`, `ctrl+z`, `ctrl+p`
- `alt+b`, `alt+d`, `alt+f`, `alt+left`, `alt+right`, `alt+up`,
  `alt+enter`
- `shift+enter`, `alt+j`, `shift+tab`
- `escape` (or `esc`), `enter` (or `return`), `backspace`, `delete`, `left`,
  `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`, `tab`

:::note
Some control codes are not bindable, because the terminal cannot tell them
apart from other keys. `Ctrl+H` arrives as `Backspace`, `Ctrl+I` as `Tab`, and
`Ctrl+M` as `Enter`. `Ctrl+F` always opens transcript search and cannot be
rebound.
:::

## Action names

Actions starting with `app.` are handled by the screen. Actions starting with
`tui.` are handled by the composer. These are the ones you can rebind, with
their defaults:

| Action | Default |
| --- | --- |
| `app.editor.external` | `ctrl+g` |
| `app.interrupt` | `escape` |
| `app.clear` | `ctrl+c` |
| `app.message.followUp` | `alt+enter` |
| `app.message.dequeue` | `alt+up` |
| `app.thinking.cycle` | `shift+tab` |
| `tui.input.submit` | `enter` |
| `tui.input.newLine` | `shift+enter`, `alt+j` |
| `tui.input.tab` | `tab` |
| `tui.editor.undo` | `ctrl+z` |
| `tui.editor.deleteCharBackward` | `backspace` |
| `tui.editor.deleteCharForward` | `delete`, `ctrl+d` |
| `tui.editor.deleteWordBackward` | `ctrl+w` |
| `tui.editor.deleteWordForward` | `alt+d` |
| `tui.editor.deleteToLineStart` | `ctrl+u` |
| `tui.editor.deleteToLineEnd` | `ctrl+k` |
| `tui.editor.yank` | `ctrl+y` |
| `tui.editor.cursorLeft` | `left`, `ctrl+b` |
| `tui.editor.cursorRight` | `right`, `ctrl+f` |
| `tui.editor.cursorWordLeft` | `alt+b` |
| `tui.editor.cursorWordRight` | `alt+f` |
| `tui.editor.cursorLineStart` | `home`, `ctrl+a` |
| `tui.editor.cursorLineEnd` | `end`, `ctrl+e` |
| `tui.editor.cursorUp` | `up` |
| `tui.editor.cursorDown` | `down` |
| `tui.editor.historyPrevious` | `ctrl+p` |
| `tui.editor.historyNext` | `ctrl+n` |

The shortcuts in the other tables on this page are built in and cannot be
remapped.
