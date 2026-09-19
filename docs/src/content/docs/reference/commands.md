---
title: Commands and shortcuts
description: Every slash command and keyboard shortcut.
---

Slash commands are typed in the composer and start with `/`. They configure
nimlet, manage sessions, and inspect state - they never become a message to the
model, with two exceptions described under "Dispatch" below.

`/help` prints the same list inside the app, built from the same table this page
follows. If the two ever disagree, `/help` is right. The keyboard shortcuts live
on the [Keyboard shortcuts](/reference/keybindings/) page.

## Getting started

| Command | Description |
| --- | --- |
| `/plan` | Investigate and plan with read-only tools |
| `/act` | Enable implementation tools |
| `/help` | Show this help |
| `/login [flow]` | Sign in to Codex with ChatGPT |
| `/logout` | Sign out of Codex |
| `/auth` | Show Codex authentication status |

`/plan` and `/act` switch modes and print the new one. `Shift+Tab` does the same
thing without touching your draft. Both are covered in
[Plan and act mode](/guides/plan-and-act/).

`/login` starts the Codex browser login flow and prints the URL to open.
`/login device` prints the device verification URL and code. Codex owns the
credential storage and token refresh. `/auth` reads the current Codex account
status, and `/logout` removes the Codex login. After login, `/provider codex`
uses the local Codex App Server; `/models refresh` loads its model list and
`/model <id>` selects a model for later turns.

## Model

| Command | Description |
| --- | --- |
| `/model [name]` | Show or set the model |
| `/models refresh` | Refresh cached model metadata |
| `/thinking <level>` | Show or set reasoning |
| `/provider [name]` | Show or set the provider |
| `/web [on\|off]` | Show or set hosted web search |

- `/model` alone prints the current id. `/model <id>` switches for later turns and
  remembers that choice per provider, so switching back and forth returns you to
  the model you last used. Changing it writes to your config file, and records a
  selection event in the session.
- Typing `/model ` opens alphabetized suggestions from the catalog for the active
  provider, including your current and default model. The catalog is filtered from two characters, up
  to 50 entries, and each suggestion shows the provider and context size.
- `/models refresh` fetches `models.dev` for normal providers. For `codex`, it
  calls the local Codex App Server's model list instead. A stale `models.dev`
  cache is also refreshed automatically at startup.
- `/thinking` with no argument shows the active level, `(provider default)`, or
  `(unsupported by model)` when the model has no reasoning control. Levels are
  `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`; which ones do
  something is up to the model.
- `/provider` alone prints the active provider. `/provider <name>` accepts
  `anthropic`, `codex`, `google`, `hyper`, `mistral`, `openai`, `opencode`,
  `opencodezen`, or `openrouter`, selects that provider's last model, and saves
  the provider, model, and remembered model choices.
- `/web` shows whether hosted search is available. `/web on` enables it for
  providers that support it; it is only offered to the model in act mode.

## Session

| Command | Description |
| --- | --- |
| `/session [rename\|delete\|restore] ...` | Show or manage sessions |
| `/stats` | Show model, context, token usage, and cost |
| `/new` | Start a new persistent session |
| `/resume [query\|ID]` | List this project's sessions, or resume one |
| `/fork [message]` | Fork from a user message and continue in a new session |
| `/copy` | Copy the latest assistant response |
| `/export [file]` | Export the session as standalone HTML |
| `/name [title]` | Show or set the session name |
| `/compact [instructions]` | Summarize older context |

- `/session` prints the id, name, event count, file path, workspace, and thinking
  setting. `/session rename ID TITLE`, `/session delete ID` (with confirmation),
  and `/session restore ID` manage files by id. Full details in
  [Sessions](/guides/sessions/).
- `/stats` reports the provider, model, the latest request's usage, the context
  window percentage, and cost, then the same numbers totalled across the session.
  It prints `Usage: no responses yet` before your first reply.
- `/new`, `/resume`, and `/fork` all switch the active session; `/copy` copies the
  last assistant response to your clipboard (in the TUI only).
- `/export` writes a standalone HTML transcript to
  `nimlet-session-<session-id>.html` in the workspace. Pass a relative or
  absolute path to choose the output file. The export includes messages, tool
  calls, tool results, thinking, and attachments that are stored in the session.
  Review it for sensitive data before sharing.
- `/name` alone prints the title, or `(unnamed)`.
- `/compact` compacts now, and any text you add is passed to the summarizer as an
  instruction. See [Context and compaction](/guides/context-and-compaction/).

## Trust

| Command | Description |
| --- | --- |
| `/yolo [on\|off]` | Auto-approve tools for this process |
| `/trust [on\|off]` | Show or set project-local resource trust |
| `/permissions [clear]` | Show or clear remembered tool grants |

- `/yolo` and `/yolo on` are the same thing; `/yolo off` returns to prompting. The
  state is never written to disk.
- `/trust` says `No project-local resources require trust.` when the project ships
  nothing, and otherwise reports trusted or not trusted. `/trust on` and
  `/trust off` take effect immediately for tools, skills, prompts, extensions,
  and system prompt files. Project config values are loaded at startup, so
  restart to apply a trust change to configuration.
- `/permissions` lists grants, project first. `/permissions clear` removes the
  project ones from `.nimlet/permissions.json`.

Details for all three are in [Security](/guides/security/) and
[Permissions](/guides/permissions/).

## UI

| Command | Description |
| --- | --- |
| `/theme [name]` | Show or set the UI theme |
| `/settings` | Configure message delivery and other settings |

- `/theme` alone prints the current theme, what `auto` resolved to, and every
  available name. `/theme <name>` applies to the interface straight away;
  the transcript keeps its old colours until `/new`, `/resume`, or a restart,
  and nimlet tells you so.
- `/settings` opens a menu. Today it holds one category, `Queue`, which chooses
  how queued messages are delivered: `one-at-a-time` or `all`, separately for
  steering messages and follow-ups. The choice is saved to your config.

## Maintenance

| Command | Description |
| --- | --- |
| `/doctor [test]` | Show configuration and key status; optionally test the connection |
| `/reload` | Rescan tools, hooks, skills, and prompts |
| `/version` | Show the running nimlet version |
| `/quit` | Exit |
| `/exit` | Exit |

- `/doctor` prints the selected provider and model, the endpoint with credentials
  and query parameters stripped, every config file it read (and whether each
  exists), the file it will write to, and the key source plus set/missing state
  for each provider. It never prints a key.
- `/doctor test` sends one small request (before any session history exists) and
  reports `Connection OK: <model>`, or a failure pointing at the key, endpoint,
  model, and account.
- `/reload` re-reads skills, prompts, `AGENTS.md`, external tools, and extensions,
  and keeps the current session.
- `/version` prints the version of the nimlet you are running, such as
  `nimlet 0.1.1`. The same string is available from the command line with
  `nimlet --version`.
- `/quit` and `/exit` leave. `Ctrl+C` on an empty composer does the same.

## Dispatch: which command wins

The first word decides. Built-in names are matched exactly, so type them in
lowercase as shown - `/Model` is not a built-in. If the name is not built in,
nimlet looks in this order:

1. extension commands (case-insensitive)
2. prompt templates, as a bare `/name`
3. skills, but only under `/skill:<name>`

If nothing matches, you get `Unknown command '/foo'; try /help`. Since skills use
their own namespace, `prompts/review.md` and `skills/review/SKILL.md` coexist as
`/review` and `/skill:review`. Extension commands beat prompt templates with the
same name, and both lose to built-ins.

A template or skill command becomes a message to the model: `/review fix the
parser` sends the expanded prompt as your turn. An extension command is sent to
that extension instead, which may display a message, start a turn, or both.

## Usage errors

Argument validation is strict, and the message tells you the shape that works:

```text
/plan extra                  → /plan takes no arguments
/thinking loud               → Invalid thinking level 'loud' (use none|minimal|low|medium|high|xhigh|max)
/web maybe                   → Invalid /web value 'maybe' (use on|off)
/provider gemini             → Unknown provider 'gemini' (use anthropic|codex|google|hyper|mistral|openai|opencode|opencodezen|openrouter)
/model refresh               → Unknown /model option 'refresh'; did you mean /models refresh?
/models                      → Usage: /models refresh
/session delete              → Usage: /session delete ID
/fork zero                   → Usage: /fork [message]
```

Commands that take no arguments report `/copy takes no arguments`, and so on.
A trailing space is not an error: `/model ` is treated as still being typed, so
the suggestion menu opens instead of a usage message appearing under your cursor.

## Completion in the composer

Type `/` and the menu lists built-in commands by usage. `Tab`, `Up`, and `Down`
move through it; `Enter` accepts. Commands that take no arguments submit
immediately, while argument-taking commands complete with a trailing space so you
can keep typing. `/skill:<name>` suggestions complete the same way.

Several commands have their own suggestions:

| Typing | Suggests |
| --- | --- |
| `/model ` | Your recent models, then catalog matches with provider and context size |
| `/provider `, `/thinking `, `/web `, `/theme ` | The valid names |
| `/resume ` | Sessions in this workspace, filtered by id, name, or first message |
| `/session rename`, `/delete`, `/restore` | Matching session ids, or ids in the trash |
| `/fork ` | Your messages in this session, numbered |

Extension commands and prompt templates appear in the same menu with their
descriptions, and prompt templates whose names collide with built-ins are not
offered.

## Mentions and shell shortcuts

Two more things the composer understands, neither of which is a command:

- **`@path`** attaches a file or folder to your message. File contents arrive
  wrapped as `<file path="…">…</file>`, folder mentions arrive as a bounded
  listing (200 entries, generated folders like `node_modules`, `dist`, and
  `nimcache` skipped). Typing `@` completes paths from the workspace, up to 50
  results; folder suggestions keep a trailing `/` so you can keep typing. Images
  are attached as images, and pasting an image path does the same.
- **`!command`** runs a shell command in your workspace with the shell the tools
  use, and sends `$ command`, its output, and `(exit 0)` to the model as your next
  message. **`!!command`** runs it and only prints the result in the transcript.
  Neither asks for approval, because you typed it.

While a turn is running, `Enter` queues a steering message and `Alt+Enter` queues
a follow-up. Slash commands and shell shortcuts cannot be queued; the composer
tells you `slash commands cannot be queued` or `shell shortcuts cannot be queued`
instead of silently dropping them.

## CLI flags

These flags apply when you start nimlet from the shell. They override config for
one process only and are never persisted. Run `nimlet --help` for the same list.

| Flag | Purpose |
| --- | --- |
| `--help`, `-h` | Print usage and exit |
| `--version` | Print version and exit |
| `--print`, `-p` | Print only the final response to stdout |
| `--mode json` | One turn, versioned JSONL events on stdout |
| `--mode rpc` | Long-running JSONL command protocol on stdin/stdout |
| `--provider NAME` | Provider for this process |
| `--model ID` | Model for this process |
| `--thinking LEVEL` | Thinking level for this process |
| `--api-key KEY` | In-memory API key override |
| `--tools LIST` | Restrict tools (`read,grep,...` or `none`) |
| `--no-session` | Skip session read/write |
| `--session ID` | Resume a specific session at startup |
| `--resume` | Resume the latest session for this workspace |
| `--yolo` | Auto-approve all tools for this process |
| `--fullscreen` | Use the alternate screen (default) |
| `--no-fullscreen`, `--regular` | Keep normal terminal scrollback |
| `--approve` | Load project customizations without the trust prompt |
| `--no-approve` | Skip project customizations |
| `--interactive`, `-i` | Keep the REPL after a CLI prompt |
| `--` | End of flags; remaining words are the prompt |

A prompt after the flags runs one turn and exits unless `--interactive` is set.
Piped stdin is merged before the CLI prompt and selects print mode when stdout
is not a TTY.

`--no-session` cannot be combined with `--resume` or `--session`. `--approve`
and `--no-approve` cannot be combined.

## Where to go next

- [Keyboard shortcuts](/reference/keybindings/) for every key binding
- [Built-in tools](/reference/tools/) for what the model can call
- [Files and directories](/reference/files-and-directories/) for the config these
  commands read and write
